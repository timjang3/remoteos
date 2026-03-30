import Foundation
import Testing
@testable import RemoteOSCore

private actor MockWebSocketTransport: RemoteOSWebSocketTransport {
    private var sent: [Data] = []
    private var queuedInbound: [Data] = []
    private var receiveContinuation: CheckedContinuation<Data, Error>?
    private(set) var connectedURL: URL?

    func connect(to url: URL) async throws {
        connectedURL = url
    }

    func disconnect() async {
        if let receiveContinuation {
            self.receiveContinuation = nil
            receiveContinuation.resume(throwing: CancellationError())
        }
    }

    func send(_ data: Data) async throws {
        sent.append(data)
    }

    func receive() async throws -> Data {
        if queuedInbound.isEmpty == false {
            return queuedInbound.removeFirst()
        }

        return try await withCheckedThrowingContinuation { continuation in
            receiveContinuation = continuation
        }
    }

    func pushInbound(_ data: Data) {
        if let receiveContinuation {
            self.receiveContinuation = nil
            receiveContinuation.resume(returning: data)
            return
        }

        queuedInbound.append(data)
    }

    func sentMessages() -> [Data] {
        sent
    }
}

private actor NotificationRecorder {
    private var notifications: [RemoteOSNotification] = []

    func append(_ notification: RemoteOSNotification) {
        notifications.append(notification)
    }

    func snapshot() -> [RemoteOSNotification] {
        notifications
    }
}

private func waitForSentMessages(
    _ transport: MockWebSocketTransport,
    count: Int,
    attempts: Int = 50
) async -> [Data] {
    for _ in 0..<attempts {
        let messages = await transport.sentMessages()
        if messages.count >= count {
            return messages
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await transport.sentMessages()
}

@Test func clientBrokerConnectionSendsStreamProfileAndResolvesResponse() async throws {
    let transport = MockWebSocketTransport()
    let connection = ClientBrokerConnection(transport: transport)
    try await connection.connect(to: URL(string: "wss://example.com/ws/client")!)

    let task = Task {
        try await connection.startStream(windowId: 42, profile: .balanced)
    }

    let sentMessages = await waitForSentMessages(transport, count: 1)
    #expect(sentMessages.count == 1)
    guard let firstMessage = sentMessages.first else {
        Issue.record("Expected the broker request to be sent")
        return
    }

    let request = try JSONDecoder().decode(JSONRPCRequestEnvelope.self, from: firstMessage)
    #expect(request.method == RemoteOSRPCMethod.streamStart.rawValue)
    let payload = try request.params?.decode(StreamStartPayload.self)
    #expect(payload?.windowId == 42)
    #expect(payload?.profile == .balanced)

    let success = try TestSupport.jsonObjectData([
        "jsonrpc": "2.0",
        "id": request.id,
        "result": ["ok": true]
    ])
    await transport.pushInbound(success)

    try await task.value
}

@Test func clientBrokerConnectionDispatchesDecodedNotifications() async throws {
    let transport = MockWebSocketTransport()
    let recorder = NotificationRecorder()
    let connection = ClientBrokerConnection(transport: transport)
    await connection.setNotificationHandler { notification in
        await recorder.append(notification)
    }
    try await connection.connect(to: URL(string: "wss://example.com/ws/client")!)

    await transport.pushInbound(try TestSupport.fixtureData(named: "rpc-notification-agent-prompt-requested.json"))

    for _ in 0..<50 {
        let notifications = await recorder.snapshot()
        if notifications.isEmpty == false {
            guard case let .agentPromptRequested(prompt) = notifications[0] else {
                Issue.record("Expected first notification to be an agent prompt")
                return
            }
            #expect(prompt.id == "prompt_1")
            #expect(prompt.questions.count == 1)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }

    Issue.record("Timed out waiting for client broker notification")
}
