import Foundation
import Testing
@testable import RemoteOSCore

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Test func bootstrapRequestAddsBearerAuthorizationWhenAvailable() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let urlSession = URLSession(configuration: configuration)
    let client = ControlPlaneHTTPClient(
        urlSession: urlSession,
        authTokenProvider: { "mobile_auth_token" }
    )

    StubURLProtocol.handler = { request in
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer mobile_auth_token")
        #expect(request.url?.absoluteString == "https://example.com/bootstrap?clientToken=client_token")

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["content-type": "application/json"]
        )!
        let data = try TestSupport.jsonObjectData([
            "client": [
                "id": "client_1",
                "deviceId": "device_1",
                "name": "Phone",
                "token": "client_token"
            ],
            "device": [
                "id": "device_1",
                "name": "My Mac",
                "mode": "hosted",
                "online": true,
                "registeredAt": "2026-03-30T12:00:00.000Z",
                "lastSeenAt": "2026-03-30T12:00:00.000Z"
            ],
            "windows": [],
            "status": [
                "deviceId": "device_1",
                "online": true,
                "selectedWindowId": NSNull(),
                "screenRecording": "granted",
                "accessibility": "granted",
                "directUrl": NSNull(),
                "codex": [
                    "state": "ready",
                    "installed": true,
                    "authenticated": true,
                    "authMode": "chatgpt",
                    "model": "gpt-5.4-mini",
                    "threadId": NSNull(),
                    "activeTurnId": NSNull(),
                    "lastError": NSNull()
                ]
            ],
            "wsUrl": "wss://example.com/ws/client?ticket=abc123",
            "speech": [
                "transcriptionAvailable": true,
                "provider": "openai",
                "maxDurationMs": 120000,
                "maxUploadBytes": 10485760
            ]
        ])
        return (response, data)
    }
    defer { StubURLProtocol.handler = nil }

    let bootstrap = try await client.bootstrap(baseURL: "https://example.com/", clientToken: "client_token")
    #expect(bootstrap.client.id == "client_1")
    #expect(bootstrap.wsUrl == "wss://example.com/ws/client?ticket=abc123")
}

@Test func mobileAuthStartURLBuildsASWebAuthenticationSessionEntryPoint() throws {
    let client = ControlPlaneHTTPClient()
    let url = try client.mobileAuthStartURL(
        baseURL: "https://control.remoteos.app/",
        request: MobileAuthStartRequest(
            redirectUri: "remoteos://auth",
            provider: "google"
        )
    )

    #expect(url.absoluteString == "https://control.remoteos.app/mobile/auth/start?redirectUri=remoteos://auth&provider=google")
}
