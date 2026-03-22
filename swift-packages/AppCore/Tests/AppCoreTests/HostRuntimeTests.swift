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

    private var handler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

    func setHandler(_ handler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?) {
        self.handler = handler
    }

    func currentHandler() -> (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))? {
        handler
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
                guard let handler = await MockURLProtocolState.shared.currentHandler() else {
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
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated defaults suite")
        return
    }
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set("http://example.test", forKey: "controlPlaneBaseURL")
    defaults.set("Test Mac", forKey: "deviceName")

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let urlSession = URLSession(configuration: configuration)
    let requestCounter = RequestCounter()

    await MockURLProtocolState.shared.setHandler { request in
        #expect(request.url?.path == "/devices/register")
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
    }
    defer {
        Task {
            await MockURLProtocolState.shared.setHandler(nil)
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

    #expect(firstRegistration.device.id == "device_1")
    #expect(secondRegistration.device.id == "device_1")
    #expect(runtime.configuration.deviceID == "device_1")
    #expect(runtime.configuration.deviceSecret == "secret_1")
    #expect(await requestCounter.value() == 1)
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
