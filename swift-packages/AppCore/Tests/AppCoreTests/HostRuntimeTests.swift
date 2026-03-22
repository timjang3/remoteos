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

@MainActor
@Test func ensureDeviceRegistrationReusesInFlightRequest() async throws {
    let suiteName = "HostRuntimeTests-\(UUID().uuidString)"
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

    let runtime = try HostRuntime(
        configurationStore: ConfigurationStore(defaults: defaults),
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

    let runtime = try HostRuntime(
        configurationStore: ConfigurationStore(defaults: defaults),
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
@Test func ensureDeviceRegistrationFailsWhenStoredDeviceSecretIsMissing() async throws {
    let suiteName = "HostRuntimeMissingSecretTests-\(UUID().uuidString)"
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

    await MockURLProtocolState.shared.setHandler(forHost: host) { request in
        await requestCounter.increment()
        Issue.record("Unexpected request path \(request.url?.path ?? "nil")")
        throw URLError(.unsupportedURL)
    }
    defer {
        Task {
            await MockURLProtocolState.shared.setHandler(forHost: host, nil)
        }
    }

    let runtime = try HostRuntime(
        configurationStore: ConfigurationStore(defaults: defaults),
        keychainTokenStore: KeychainTokenStore(service: "HostRuntimeMissingSecret-\(UUID().uuidString)"),
        brokerClient: BrokerClient(urlSession: urlSession),
        urlSession: urlSession
    )

    do {
        _ = try await runtime.ensureDeviceRegistration()
        Issue.record("Expected registration to fail when the stored device secret is missing")
    } catch {
        #expect(error.localizedDescription.contains("Stored device registration is incomplete"))
    }

    #expect(await requestCounter.value() == 0)
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
        keychainTokenStore: keychain
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
