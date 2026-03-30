import Foundation

public enum RemoteOSRPCMethod: String, Codable, CaseIterable, Sendable {
    case windowsList = "windows.list"
    case windowSelect = "window.select"
    case streamStart = "stream.start"
    case streamStop = "stream.stop"
    case inputTap = "input.tap"
    case inputDrag = "input.drag"
    case inputScroll = "input.scroll"
    case inputKey = "input.key"
    case semanticSnapshot = "semantic.snapshot"
    case semanticDiffSubscribe = "semantic.diff.subscribe"
    case agentTurnStart = "agent.turn.start"
    case agentTurnCancel = "agent.turn.cancel"
    case agentThreadReset = "agent.thread.reset"
    case agentPromptRespond = "agent.prompt.respond"
    case agentConfigSetModel = "agent.config.setModel"
    case agentStateGet = "agent.state.get"
    case windowsUpdated = "windows.updated"
    case windowSnapshot = "window.snapshot"
    case windowFrame = "window.frame"
    case semanticDiff = "semantic.diff"
    case agentTurn = "agent.turn"
    case agentItem = "agent.item"
    case agentPromptRequested = "agent.prompt.requested"
    case agentPromptResolved = "agent.prompt.resolved"
    case traceEvent = "trace.event"
    case hostStatus = "host.status"
    case codexStatus = "codex.status"
}

public struct JSONRPCRequestEnvelope: Codable, Sendable {
    public let jsonrpc: String
    public let id: String
    public let method: String
    public let params: JSONValue?

    public init(id: String, method: String, params: JSONValue?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCSuccessEnvelope: Codable, Sendable {
    public let jsonrpc: String
    public let id: String
    public let result: JSONValue?
}

public struct JSONRPCErrorDetail: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?
}

public struct JSONRPCErrorEnvelope: Codable, Sendable {
    public let jsonrpc: String
    public let id: String?
    public let error: JSONRPCErrorDetail
}

public struct JSONRPCNotificationEnvelope: Codable, Sendable {
    public let jsonrpc: String
    public let method: String
    public let params: JSONValue?
}

public enum JSONRPCInboundEnvelope: Sendable {
    case success(JSONRPCSuccessEnvelope)
    case error(JSONRPCErrorEnvelope)
    case notification(JSONRPCNotificationEnvelope)
    case request(JSONRPCRequestEnvelope)

    public init(data: Data, decoder: JSONDecoder = JSONDecoder()) throws {
        let object = try anyDictionary(from: data)
        guard object["jsonrpc"] as? String == "2.0" else {
            throw AppCoreError.invalidResponse
        }

        let hasID = object["id"] != nil
        let hasMethod = object["method"] != nil
        let hasResult = object["result"] != nil
        let hasError = object["error"] != nil

        switch (hasID, hasMethod, hasResult, hasError) {
        case (true, false, true, false):
            self = .success(try decoder.decode(JSONRPCSuccessEnvelope.self, from: data))
        case (true, false, false, true):
            self = .error(try decoder.decode(JSONRPCErrorEnvelope.self, from: data))
        case (true, true, false, false):
            self = .request(try decoder.decode(JSONRPCRequestEnvelope.self, from: data))
        case (false, true, false, false):
            self = .notification(try decoder.decode(JSONRPCNotificationEnvelope.self, from: data))
        default:
            throw AppCoreError.invalidResponse
        }
    }
}

public struct RemoteOSRPCError: Error, LocalizedError, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var errorDescription: String? {
        message
    }
}
