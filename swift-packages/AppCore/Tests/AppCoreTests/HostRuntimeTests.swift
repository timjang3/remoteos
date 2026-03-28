import Foundation
import Testing
@testable import AppCore

private actor RequestCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor MockURLProtocolState {
    static let shared = MockURLProtocolState()

    private var handlers: [String: @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)] = [:]

    func setHandler(
        forHost host: String,
        _ handler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?
    ) {
        if let handler {
            handlers[host] = handler
        } else {
            handlers.removeValue(forKey: host)
        }
    }

    func currentHandler(
        forHost host: String?
    ) -> (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))? {
        guard let host else {
            return nil
        }
        return handlers[host]
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Task {
            do {
                guard let handler = await MockURLProtocolState.shared.currentHandler(forHost: request.url?.host) else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
                let (response, data) = try await handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}

private func makeDeviceSecretStore(
    keychain: KeychainTokenStore,
    defaults: UserDefaults,
    legacyKeychain: KeychainTokenStore? = nil
) -> DeviceSecretStore {
    DeviceSecretStore(
        keychainTokenStore: keychain,
        legacyKeychainTokenStore: legacyKeychain ?? KeychainTokenStore(service: "HostRuntimeLegacyIsolated-\(UUID().uuidString)"),
        defaults: defaults,
        mode: .keychainOnly
    )
}

@MainActor
@Test func previewFrameDefaultsMatchTheLiveStreamBudget() async throws {
    #expect(HostRuntime.previewFrameMaxPixelSize == WindowStreamService.maxStreamLongEdgePixels)
    #expect(HostRuntime.previewFrameCompressionQuality == 0.72)
}

@MainActor
@Test func ensureDeviceRegistrationReusesInFlightRequest() async throws {
    let suiteName = "HostRuntimeTests-\(UUID().uuidString)"
    let keychainService = "HostRuntimeInFlight-\(UUID().uuidString)"
    let host = "example-inflight.test"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated defaults suite")
        return
    }
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set("http://\(host)", forKey: "controlPlaneBaseURL")
    defaults.set("Test Mac", forKey: "deviceName")

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let urlSession = URLSession(configuration: configuration)
    let requestCounter = RequestCounter()

    await MockURLProtocolState.shared.setHandler(forHost: host) { request in
        switch request.url?.path {
        case "/health":
            let payload: [String: Any] = [
                "ok": true,
                "now": "2026-03-19T00:00:00Z",
                "authMode": "none",
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try #require(
                HTTPURLResponse(
                    url: request.url ?? URL(string: "http://example.test/health")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, data)
        case "/devices/register":
            await requestCounter.increment()
            try await Task.sleep(for: .milliseconds(50))

            let payload: [String: Any] = [
                "device": [
                    "id": "device_1",
                    "name": "Test Mac",
                    "mode": "hosted",
                    "online": false,
                    "registeredAt": "2026-03-19T00:00:00Z",
                    "lastSeenAt": NSNull()
                ],
                "deviceSecret": "secret_1",
                "wsUrl": "ws://example.test/ws/host?deviceId=device_1&deviceSecret=secret_1"
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try #require(
                HTTPURLResponse(
                    url: request.url ?? URL(string: "http://example.test/devices/register")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, data)
        default:
            Issue.record("Unexpected request path \(request.url?.path ?? "nil")")
            throw URLError(.unsupportedURL)
        }
    }
    defer {
        Task {
            await MockURLProtocolState.shared.setHandler(forHost: host, nil)
        }
    }

    let keychain = KeychainTokenStore(service: keychainService)
    keychain.save(nil, for: .deviceSecret)

    let runtime = try HostRuntime(
        configurationStore: ConfigurationStore(defaults: defaults),
        deviceSecretStore: makeDeviceSecretStore(keychain: keychain, defaults: defaults),
        brokerClient: BrokerClient(urlSession: urlSession),
        urlSession: urlSession
    )

    async let first = runtime.ensureDeviceRegistration()
    async let second = runtime.ensureDeviceRegistration()
    let firstRegistration = try await first
    let secondRegistration = try await second

    #expect(firstRegistration.device?.id == "device_1")
    #expect(secondRegistration.device?.id == "device_1")
    #expect(runtime.configuration.deviceID == "device_1")
    #expect(runtime.configuration.deviceSecret == "secret_1")
    #expect(await requestCounter.value() == 1)
}

@MainActor
@Test func ensureDeviceRegistrationReturnsPendingEnrollmentForHostedApproval() async throws {
    let suiteName = "HostRuntimeEnrollmentTests-\(UUID().uuidString)"
    let keychainService = "HostRuntimeEnrollment-\(UUID().uuidString)"
    let host = "example-enrollment.test"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated defaults suite")
        return
    }
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set("http://\(host)", forKey: "controlPlaneBaseURL")
    defaults.set("Test Mac", forKey: "deviceName")

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let urlSession = URLSession(configuration: configuration)

    await MockURLProtocolState.shared.setHandler(forHost: host) { request in
        switch request.url?.path {
        case "/devices/register":
            let payload: [String: Any] = [
                "approvalRequired": true,
                "deviceId": "device_1",
                "deviceSecret": "secret_1",
                "enrollmentUrl": "http://localhost:5173/?enroll=enrollment_1",
                "enrollmentToken": "enrollment_1",
                "expiresAt": "2026-03-19T00:15:00Z"
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try #require(
                HTTPURLResponse(
                    url: request.url ?? URL(string: "http://example.test/devices/register")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, data)
        default:
            Issue.record("Unexpected request path \(request.url?.path ?? "nil")")
            throw URLError(.unsupportedURL)
        }
    }
    defer {
        Task {
            await MockURLProtocolState.shared.setHandler(forHost: host, nil)
        }
    }

    let keychain = KeychainTokenStore(service: keychainService)
    keychain.save(nil, for: .deviceSecret)

    let runtime = try HostRuntime(
        configurationStore: ConfigurationStore(defaults: defaults),
        deviceSecretStore: makeDeviceSecretStore(keychain: keychain, defaults: defaults),
        brokerClient: BrokerClient(urlSession: urlSession),
        urlSession: urlSession
    )

    let registration = try await runtime.ensureDeviceRegistration()

    #expect(registration.isApprovalRequired == true)
    #expect(registration.device == nil)
    #expect(registration.deviceId == "device_1")
    #expect(registration.enrollmentToken == "enrollment_1")
    #expect(runtime.configuration.deviceID == "device_1")
    #expect(runtime.configuration.deviceSecret == "secret_1")
}

@MainActor
@Test func ensureDeviceRegistrationSurfacesRateLimitRetryAfter() async throws {
    let suiteName = "HostRuntimeRateLimitTests-\(UUID().uuidString)"
    let keychainService = "HostRuntimeRateLimit-\(UUID().uuidString)"
    let host = "example-rate-limit.test"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated defaults suite")
        return
    }
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set("https://\(host)", forKey: "controlPlaneBaseURL")
    defaults.set("Test Mac", forKey: "deviceName")

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let urlSession = URLSession(configuration: configuration)

    await MockURLProtocolState.shared.setHandler(forHost: host) { request in
        switch request.url?.path {
        case "/devices/register":
            let data = try JSONSerialization.data(withJSONObject: [
                "error": "Too many requests"
            ])
            let response = try #require(
                HTTPURLResponse(
                    url: request.url ?? URL(string: "https://\(host)/devices/register")!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json",
                        "Retry-After": "7"
                    ]
                )
            )
            return (response, data)
        default:
            Issue.record("Unexpected request path \(request.url?.path ?? "nil")")
            throw URLError(.unsupportedURL)
        }
    }
    defer {
        Task {
            await MockURLProtocolState.shared.setHandler(forHost: host, nil)
        }
    }

    let runtime = try HostRuntime(
        configurationStore: ConfigurationStore(defaults: defaults),
        deviceSecretStore: makeDeviceSecretStore(
            keychain: KeychainTokenStore(service: keychainService),
            defaults: defaults
        ),
        brokerClient: BrokerClient(urlSession: urlSession),
        urlSession: urlSession
    )

    do {
        _ = try await runtime.ensureDeviceRegistration()
        Issue.record("Expected ensureDeviceRegistration() to throw")
    } catch let AppCoreError.rateLimited(message, retryAfter) {
        #expect(message == "Too many requests. Retrying in about 7s.")
        #expect(retryAfter == .seconds(7))
        #expect(HostRuntime.reconnectDelay(for: AppCoreError.rateLimited(message, retryAfter: retryAfter)) == .seconds(7))
        #expect(runtime.configuration.deviceID == nil)
        #expect(runtime.configuration.deviceSecret == nil)
    }
}

@MainActor
@Test func hostRuntimeClearsOrphanedDeviceSecretWithoutDeviceID() throws {
    let suiteName = "HostRuntimeOrphanedSecretTests-\(UUID().uuidString)"
    let keychainService = "HostRuntimeOrphanedSecret-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated defaults suite")
        return
    }
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set("Test Mac", forKey: "deviceName")

    let keychain = KeychainTokenStore(service: keychainService)
    keychain.save("secret_orphaned", for: .deviceSecret)
    defer {
        keychain.save(nil, for: .deviceSecret)
    }

    let runtime = try HostRuntime(
        configurationStore: ConfigurationStore(defaults: defaults),
        deviceSecretStore: makeDeviceSecretStore(keychain: keychain, defaults: defaults)
    )

    #expect(runtime.configuration.deviceID == nil)
    #expect(runtime.configuration.deviceSecret == nil)
    #expect(keychain.load(.deviceSecret) == nil)
}

@MainActor
@Test func hostRuntimeMigratesLegacyDeviceSecretWhenDeviceIDExists() throws {
    let suiteName = "HostRuntimeLegacySecretMigrationTests-\(UUID().uuidString)"
    let keychainService = "HostRuntimeLegacySecretMigration-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated defaults suite")
        return
    }
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set("device_1", forKey: "deviceID")
    defaults.set("Test Mac", forKey: "deviceName")

    let keychain = KeychainTokenStore(service: keychainService)
    keychain.save(nil, for: .deviceSecret)
    let legacyKeychain = KeychainTokenStore(service: "HostRuntimeLegacySecret-\(UUID().uuidString)")
    legacyKeychain.save("secret_legacy", for: .deviceSecret)
    defer {
        keychain.save(nil, for: .deviceSecret)
        legacyKeychain.save(nil, for: .deviceSecret)
    }

    let runtime = try HostRuntime(
        configurationStore: ConfigurationStore(defaults: defaults),
        deviceSecretStore: makeDeviceSecretStore(keychain: keychain, defaults: defaults, legacyKeychain: legacyKeychain)
    )

    #expect(runtime.configuration.deviceID == "device_1")
    #expect(runtime.configuration.deviceSecret == "secret_legacy")
    #expect(keychain.load(.deviceSecret) == "secret_legacy")
}

@MainActor
@Test func ensureDeviceRegistrationClearsIncompleteStoredRegistration() async throws {
    let suiteName = "HostRuntimeMissingSecretTests-\(UUID().uuidString)"
    let keychainService = "HostRuntimeMissingSecret-\(UUID().uuidString)"
    let host = "example-missing-secret.test"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated defaults suite")
        return
    }
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set("http://\(host)", forKey: "controlPlaneBaseURL")
    defaults.set("device_1", forKey: "deviceID")
    defaults.set("Test Mac", forKey: "deviceName")

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let urlSession = URLSession(configuration: configuration)
    let requestCounter = RequestCounter()
    let keychain = KeychainTokenStore(service: keychainService)
    let legacyKeychain = KeychainTokenStore(service: "HostRuntimeMissingSecretLegacy-\(UUID().uuidString)")
    keychain.save(nil, for: .deviceSecret)
    legacyKeychain.save(nil, for: .deviceSecret)

    await MockURLProtocolState.shared.setHandler(forHost: host) { request in
        switch request.url?.path {
        case "/devices/register":
            await requestCounter.increment()
            let payload: [String: Any] = [
                "device": [
                    "id": "device_new",
                    "name": "Test Mac",
                    "mode": "hosted",
                    "online": false,
                    "registeredAt": "2026-03-25T00:00:00Z",
                    "lastSeenAt": NSNull()
                ],
                "deviceSecret": "secret_new",
                "wsUrl": "ws://example.test/ws/host?deviceId=device_new&deviceSecret=secret_new"
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try #require(
                HTTPURLResponse(
                    url: request.url ?? URL(string: "http://\(host)/devices/register")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, data)
        default:
            Issue.record("Unexpected request path \(request.url?.path ?? "nil")")
            throw URLError(.unsupportedURL)
        }
    }
    defer {
        Task {
            await MockURLProtocolState.shared.setHandler(forHost: host, nil)
        }
        keychain.save(nil, for: .deviceSecret)
        legacyKeychain.save(nil, for: .deviceSecret)
    }

    let runtime = try HostRuntime(
        configurationStore: ConfigurationStore(defaults: defaults),
        deviceSecretStore: makeDeviceSecretStore(keychain: keychain, defaults: defaults, legacyKeychain: legacyKeychain),
        brokerClient: BrokerClient(urlSession: urlSession),
        urlSession: urlSession
    )

    let registration = try await runtime.ensureDeviceRegistration()

    #expect(registration.device?.id == "device_new")
    #expect(runtime.configuration.deviceID == "device_new")
    #expect(runtime.configuration.deviceSecret == "secret_new")
    #expect(await requestCounter.value() == 1)
}

@MainActor
@Test func ensureDeviceRegistrationRetriesFreshAfterUnauthorizedStoredRegistration() async throws {
    let suiteName = "HostRuntimeUnauthorizedRegistrationTests-\(UUID().uuidString)"
    let keychainService = "HostRuntimeUnauthorizedRegistration-\(UUID().uuidString)"
    let host = "example-unauthorized-registration.test"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated defaults suite")
        return
    }
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set("http://\(host)", forKey: "controlPlaneBaseURL")
    defaults.set("device_old", forKey: "deviceID")
    defaults.set("Test Mac", forKey: "deviceName")

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let urlSession = URLSession(configuration: configuration)
    let requestCounter = RequestCounter()
    let keychain = KeychainTokenStore(service: keychainService)
    keychain.save("secret_old", for: .deviceSecret)

    await MockURLProtocolState.shared.setHandler(forHost: host) { request in
        switch request.url?.path {
        case "/devices/register":
            await requestCounter.increment()
            let requestNumber = await requestCounter.value()

            if requestNumber == 1 {
                let data = try JSONSerialization.data(withJSONObject: ["error": "Unauthorized device"])
                let response = try #require(
                    HTTPURLResponse(
                        url: request.url ?? URL(string: "http://\(host)/devices/register")!,
                        statusCode: 401,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )
                )
                return (response, data)
            }

            let payload: [String: Any] = [
                "device": [
                    "id": "device_new",
                    "name": "Test Mac",
                    "mode": "hosted",
                    "online": false,
                    "registeredAt": "2026-03-25T00:00:00Z",
                    "lastSeenAt": NSNull()
                ],
                "deviceSecret": "secret_new",
                "wsUrl": "ws://example.test/ws/host?deviceId=device_new&deviceSecret=secret_new"
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try #require(
                HTTPURLResponse(
                    url: request.url ?? URL(string: "http://\(host)/devices/register")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, data)
        default:
            Issue.record("Unexpected request path \(request.url?.path ?? "nil")")
            throw URLError(.unsupportedURL)
        }
    }
    defer {
        Task {
            await MockURLProtocolState.shared.setHandler(forHost: host, nil)
        }
        keychain.save(nil, for: .deviceSecret)
    }

    let runtime = try HostRuntime(
        configurationStore: ConfigurationStore(defaults: defaults),
        deviceSecretStore: makeDeviceSecretStore(keychain: keychain, defaults: defaults),
        brokerClient: BrokerClient(urlSession: urlSession),
        urlSession: urlSession
    )

    let registration = try await runtime.ensureDeviceRegistration()

    #expect(registration.device?.id == "device_new")
    #expect(runtime.configuration.deviceID == "device_new")
    #expect(runtime.configuration.deviceSecret == "secret_new")
    #expect(defaults.string(forKey: "deviceID") == "device_new")
    #expect(keychain.load(.deviceSecret) == "secret_new")
    #expect(await requestCounter.value() == 2)
}

@MainActor
@Test func logOutHostedDeviceClearsStoredRegistration() throws {
    let suiteName = "HostRuntimeLogoutTests-\(UUID().uuidString)"
    let keychainService = "HostRuntimeLogout-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated defaults suite")
        return
    }
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set("http://localhost:8787", forKey: "controlPlaneBaseURL")
    defaults.set(HostMode.hosted.rawValue, forKey: "hostMode")
    defaults.set("device_1", forKey: "deviceID")
    defaults.set("Test Mac", forKey: "deviceName")

    let keychain = KeychainTokenStore(service: keychainService)
    keychain.save("secret_1", for: .deviceSecret)
    defer {
        keychain.save(nil, for: .deviceSecret)
    }

    let runtime = try HostRuntime(
        configurationStore: ConfigurationStore(defaults: defaults),
        deviceSecretStore: makeDeviceSecretStore(keychain: keychain, defaults: defaults)
    )

    #expect(runtime.configuration.deviceID == "device_1")
    #expect(runtime.configuration.deviceSecret == "secret_1")

    runtime.logOutHostedDevice()

    #expect(runtime.configuration.deviceID == nil)
    #expect(runtime.configuration.deviceSecret == nil)
    #expect(runtime.hostStatus.deviceId == "unregistered")
    #expect(defaults.string(forKey: "deviceID") == nil)
    #expect(keychain.load(.deviceSecret) == nil)
}

@MainActor
@Test func updateConfigurationClearsStoredRegistrationWhenConnectionTargetChanges() async throws {
    let suiteName = "HostRuntimeUpdateConfigurationTests-\(UUID().uuidString)"
    let keychainService = "HostRuntimeUpdateConfiguration-\(UUID().uuidString)"
    let oldHost = "local-control-plane.test"
    let newHost = "hosted-control-plane.test"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated defaults suite")
        return
    }
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set("http://\(oldHost)", forKey: "controlPlaneBaseURL")
    defaults.set(HostMode.hosted.rawValue, forKey: "hostMode")
    defaults.set("device_1", forKey: "deviceID")
    defaults.set("Test Mac", forKey: "deviceName")

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let urlSession = URLSession(configuration: configuration)

    await MockURLProtocolState.shared.setHandler(forHost: newHost) { request in
        switch request.url?.path {
        case "/health":
            let payload: [String: Any] = [
                "ok": true,
                "now": "2026-03-22T00:00:00Z",
                "authMode": "required"
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try #require(
                HTTPURLResponse(
                    url: request.url ?? URL(string: "https://\(newHost)/health")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, data)
        default:
            Issue.record("Unexpected request path \(request.url?.path ?? "nil")")
            throw URLError(.unsupportedURL)
        }
    }
    defer {
        Task {
            await MockURLProtocolState.shared.setHandler(forHost: newHost, nil)
        }
    }

    let keychain = KeychainTokenStore(service: keychainService)
    keychain.save("secret_1", for: .deviceSecret)
    defer {
        keychain.save(nil, for: .deviceSecret)
    }

    let runtime = try HostRuntime(
        configurationStore: ConfigurationStore(defaults: defaults),
        deviceSecretStore: makeDeviceSecretStore(keychain: keychain, defaults: defaults),
        brokerClient: BrokerClient(urlSession: urlSession),
        urlSession: urlSession
    )

    runtime.updateConfiguration(
        baseURL: "https://\(newHost)",
        mode: .hosted,
        deviceName: "Test Mac",
        codexModel: "gpt-5.4-mini"
    )

    #expect(runtime.configuration.controlPlaneBaseURL == "https://\(newHost)")
    #expect(runtime.configuration.deviceID == nil)
    #expect(runtime.configuration.deviceSecret == nil)
    #expect(runtime.hostStatus.deviceId == "unregistered")
    #expect(defaults.string(forKey: "deviceID") == nil)
    #expect(keychain.load(.deviceSecret) == nil)
}

@Test func brokerReconnectReusesUnexpiredPairingForSameDevice() {
    let current = PairingSessionPayload(
        id: "pairing_1",
        deviceId: "device_1",
        pairingCode: "ABC123",
        claimed: false,
        expiresAt: "2026-03-20T17:00:00Z",
        createdAt: "2026-03-20T16:45:00Z",
        pairingUrl: "http://localhost:5173/?code=ABC123"
    )

    let shouldRefresh = HostRuntime.shouldRefreshPairingSession(
        current: current,
        deviceID: "device_1",
        now: ISO8601DateFormatter().date(from: "2026-03-20T16:50:00Z")!
    )

    #expect(shouldRefresh == false)
}

@Test func brokerReconnectRefreshesExpiredOrMismatchedPairing() {
    let expired = PairingSessionPayload(
        id: "pairing_expired",
        deviceId: "device_1",
        pairingCode: "ABC123",
        claimed: false,
        expiresAt: "2026-03-20T16:00:00Z",
        createdAt: "2026-03-20T15:45:00Z",
        pairingUrl: "http://localhost:5173/?code=ABC123"
    )
    let mismatched = PairingSessionPayload(
        id: "pairing_other",
        deviceId: "device_2",
        pairingCode: "XYZ789",
        claimed: false,
        expiresAt: "2026-03-20T17:00:00Z",
        createdAt: "2026-03-20T16:45:00Z",
        pairingUrl: "http://localhost:5173/?code=XYZ789"
    )

    #expect(
        HostRuntime.shouldRefreshPairingSession(
            current: expired,
            deviceID: "device_1",
            now: ISO8601DateFormatter().date(from: "2026-03-20T16:50:00Z")!
        ) == true
    )
    #expect(
        HostRuntime.shouldRefreshPairingSession(
            current: mismatched,
            deviceID: "device_1",
            now: ISO8601DateFormatter().date(from: "2026-03-20T16:50:00Z")!
        ) == true
    )
    #expect(
        HostRuntime.shouldRefreshPairingSession(
            current: nil,
            deviceID: "device_1",
            now: ISO8601DateFormatter().date(from: "2026-03-20T16:50:00Z")!
        ) == true
    )
}

@Test func capturedWindowBoundsStillMatchAllowsMinorMovement() {
    #expect(
        HostRuntime.capturedWindowBoundsStillMatch(
            WindowBounds(x: 100, y: 200, width: 800, height: 600),
            current: WindowBounds(x: 104, y: 206, width: 798, height: 602)
        )
    )
}

@Test func capturedWindowBoundsStillMatchRejectsMovedOrResizedWindows() {
    #expect(
        HostRuntime.capturedWindowBoundsStillMatch(
            WindowBounds(x: 100, y: 200, width: 800, height: 600),
            current: WindowBounds(x: 132, y: 200, width: 800, height: 600)
        ) == false
    )
    #expect(
        HostRuntime.capturedWindowBoundsStillMatch(
            WindowBounds(x: 100, y: 200, width: 800, height: 600),
            current: WindowBounds(x: 100, y: 200, width: 840, height: 600)
        ) == false
    )
}
