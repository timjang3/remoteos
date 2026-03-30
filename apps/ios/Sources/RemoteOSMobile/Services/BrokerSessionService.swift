import Foundation
import RemoteOSCore

enum BrokerSessionEvent: Sendable {
    case notification(RemoteOSNotification)
    case disconnected(String?)
}

actor BrokerSessionService {
    private let connection = ClientBrokerConnection()
    private var handlersInstalled = false
    private var eventHandler: (@Sendable (BrokerSessionEvent) async -> Void)?

    func setEventHandler(_ handler: (@Sendable (BrokerSessionEvent) async -> Void)?) async {
        eventHandler = handler
        await ensureHandlersInstalled()
    }

    func connect(to rawURL: String) async throws {
        await ensureHandlersInstalled()
        guard let url = URL(string: rawURL) else {
            throw AppCoreError.invalidPayload("Invalid websocket URL")
        }
        try await connection.connect(to: url)
    }

    func disconnect() async {
        await connection.disconnect()
    }

    func listWindows() async throws -> [WindowDescriptor] {
        try await connection.listWindows()
    }

    func selectWindow(_ windowID: Int) async throws {
        try await connection.selectWindow(windowID)
    }

    func startStream(windowID: Int, profile: StreamProfile?) async throws {
        try await connection.startStream(windowId: windowID, profile: profile)
    }

    func stopStream(windowID: Int) async throws {
        try await connection.stopStream(windowId: windowID)
    }

    func semanticSnapshot(windowID: Int) async throws -> SemanticSnapshot {
        try await connection.semanticSnapshot(windowId: windowID)
    }

    func tap(_ payload: InputTapPayload) async throws {
        try await connection.tap(payload)
    }

    func drag(_ payload: InputDragPayload) async throws {
        try await connection.drag(payload)
    }

    func scroll(_ payload: InputScrollPayload) async throws {
        try await connection.scroll(payload)
    }

    func key(_ payload: InputKeyPayload) async throws {
        try await connection.key(payload)
    }

    func startAgent(prompt: String) async throws -> AgentTurnStartResultPayload {
        try await connection.startAgent(prompt: prompt)
    }

    func cancelAgent(turnID: String) async throws {
        try await connection.cancelAgent(turnID: turnID)
    }

    func resetAgentThread() async throws {
        try await connection.resetAgentThread()
    }

    func respondToPrompt(_ payload: AgentPromptResponsePayload) async throws {
        try await connection.respondToPrompt(payload)
    }

    func setAgentModel(_ modelID: String) async throws {
        try await connection.setAgentModel(modelID)
    }

    func agentState() async throws -> AgentStateGetResultPayload {
        try await connection.agentState()
    }

    private func ensureHandlersInstalled() async {
        guard handlersInstalled == false else {
            return
        }

        handlersInstalled = true
        await connection.setNotificationHandler { [weak self] notification in
            await self?.eventHandler?(.notification(notification))
        }
        await connection.setDisconnectHandler { [weak self] error in
            await self?.eventHandler?(.disconnected(error?.localizedDescription))
        }
    }
}
