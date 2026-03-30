import Foundation

public struct RemoteOSAcknowledgement: Codable, Equatable, Sendable {
    public var ok: Bool
}

public actor ClientBrokerConnection {
    private let log = RemoteOSLogs.broker
    private let transport: RemoteOSWebSocketTransport
    private let outboundQueue = BrokerOutboundQueue()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var requestID = 0
    private var connectionGeneration = 0
    private var receiveLoopTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<JSONValue?, Error>] = [:]
    private var notificationHandler: (@Sendable (RemoteOSNotification) async -> Void)?
    private var disconnectHandler: (@Sendable (Error?) async -> Void)?

    public init(transport: RemoteOSWebSocketTransport = URLSessionWebSocketTransport()) {
        self.transport = transport
    }

    public func setNotificationHandler(_ handler: (@Sendable (RemoteOSNotification) async -> Void)?) {
        notificationHandler = handler
    }

    public func setDisconnectHandler(_ handler: (@Sendable (Error?) async -> Void)?) {
        disconnectHandler = handler
    }

    public func connect(to url: URL) async throws {
        log.notice("Connecting client broker url=\(url.absoluteString)")
        await disconnect()
        try await transport.connect(to: url)
        connectionGeneration += 1
        let generation = connectionGeneration
        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop(generation: generation)
        }
    }

    public func disconnect() async {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        pending.values.forEach { $0.resume(throwing: CancellationError()) }
        pending.removeAll()
        await outboundQueue.clear()
        await transport.disconnect()
    }

    public func listWindows() async throws -> [WindowDescriptor] {
        try await request(method: .windowsList, params: Optional<WindowSelectionPayload>.none, result: WindowsListPayload.self).windows
    }

    public func selectWindow(_ windowId: Int) async throws {
        _ = try await request(method: .windowSelect, params: WindowSelectionPayload(windowId: windowId), result: RemoteOSAcknowledgement.self)
    }

    public func startStream(windowId: Int, profile: StreamProfile? = nil) async throws {
        _ = try await request(method: .streamStart, params: StreamStartPayload(windowId: windowId, profile: profile), result: RemoteOSAcknowledgement.self)
    }

    public func stopStream(windowId: Int) async throws {
        _ = try await request(method: .streamStop, params: StreamStopPayload(windowId: windowId), result: RemoteOSAcknowledgement.self)
    }

    public func semanticSnapshot(windowId: Int) async throws -> SemanticSnapshot {
        try await request(method: .semanticSnapshot, params: SemanticSnapshotRequestPayload(windowId: windowId), result: SemanticSnapshot.self)
    }

    public func tap(_ payload: InputTapPayload) async throws {
        _ = try await request(method: .inputTap, params: payload, result: RemoteOSAcknowledgement.self)
    }

    public func drag(_ payload: InputDragPayload) async throws {
        _ = try await request(method: .inputDrag, params: payload, result: RemoteOSAcknowledgement.self)
    }

    public func scroll(_ payload: InputScrollPayload) async throws {
        _ = try await request(method: .inputScroll, params: payload, result: RemoteOSAcknowledgement.self)
    }

    public func key(_ payload: InputKeyPayload) async throws {
        _ = try await request(method: .inputKey, params: payload, result: RemoteOSAcknowledgement.self)
    }

    public func startAgent(prompt: String) async throws -> AgentTurnStartResultPayload {
        try await request(method: .agentTurnStart, params: AgentTurnStartPayload(prompt: prompt), result: AgentTurnStartResultPayload.self)
    }

    public func cancelAgent(turnID: String) async throws {
        _ = try await request(method: .agentTurnCancel, params: AgentTurnCancelPayload(turnId: turnID), result: RemoteOSAcknowledgement.self)
    }

    public func resetAgentThread() async throws {
        _ = try await request(method: .agentThreadReset, params: EmptyPayload(), result: RemoteOSAcknowledgement.self)
    }

    public func respondToPrompt(_ payload: AgentPromptResponsePayload) async throws {
        _ = try await request(method: .agentPromptRespond, params: payload, result: RemoteOSAcknowledgement.self)
    }

    public func setAgentModel(_ modelID: String) async throws {
        _ = try await request(method: .agentConfigSetModel, params: AgentModelSelectionPayload(modelId: modelID), result: RemoteOSAcknowledgement.self)
    }

    public func agentState() async throws -> AgentStateGetResultPayload {
        try await request(method: .agentStateGet, params: EmptyPayload(), result: AgentStateGetResultPayload.self)
    }

    public func request<Result: Decodable, Params: Encodable>(
        method: RemoteOSRPCMethod,
        params: Params?,
        result: Result.Type = Result.self
    ) async throws -> Result {
        let resultValue = try await rawRequest(method: method.rawValue, params: params)
        let payloadValue = resultValue ?? .object([:])
        return try payloadValue.decode(Result.self, using: decoder)
    }

    private func rawRequest<Params: Encodable>(method: String, params: Params?) async throws -> JSONValue? {
        let id = nextRequestID()
        let paramsValue = try params.map { try jsonValue(from: $0, encoder: encoder) }
        let request = JSONRPCRequestEnvelope(id: id, method: method, params: paramsValue)
        let data = try encoder.encode(request)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            let outboundQueue = self.outboundQueue
            let transport = self.transport
            Task { [self] in
                do {
                    try await outboundQueue.enqueue(kind: .control, data: data) { payload in
                        try await transport.send(payload)
                    }
                } catch {
                    resumePending(id: id, with: .failure(error))
                }
            }
        }
    }

    private func nextRequestID() -> String {
        requestID += 1
        return String(requestID)
    }

    private func receiveLoop(generation: Int) async {
        do {
            while !Task.isCancelled, generation == connectionGeneration {
                let data = try await transport.receive()
                try await handleInbound(data: data)
            }
        } catch {
            if !Task.isCancelled {
                log.error("Client broker receive loop failed error=\(error.localizedDescription)")
                failPending(error)
                await disconnectHandler?(error)
            }
        }
    }

    private func handleInbound(data: Data) async throws {
        let inbound = try JSONRPCInboundEnvelope(data: data, decoder: decoder)

        switch inbound {
        case let .success(payload):
            resumePending(id: payload.id, with: .success(payload.result))
        case let .error(payload):
            let error = RemoteOSRPCError(
                code: payload.error.code,
                message: payload.error.message,
                data: payload.error.data
            )
            resumePending(id: payload.id ?? "", with: .failure(error))
        case let .notification(payload):
            let notification = try RemoteOSNotification(method: payload.method, params: payload.params)
            await notificationHandler?(notification)
        case .request:
            throw AppCoreError.invalidPayload("Unexpected broker request received by client")
        }
    }

    private func resumePending(id: String, with result: Result<JSONValue?, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else {
            return
        }

        switch result {
        case let .success(value):
            continuation.resume(returning: value)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    private func failPending(_ error: Error) {
        pending.values.forEach { $0.resume(throwing: error) }
        pending.removeAll()
    }
}

public struct EmptyPayload: Codable, Equatable, Sendable {
    public init() {}
}

public struct AgentModelSelectionPayload: Codable, Equatable, Sendable {
    public var modelId: String

    public init(modelId: String) {
        self.modelId = modelId
    }
}
