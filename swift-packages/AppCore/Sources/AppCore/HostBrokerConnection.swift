import Foundation
import RemoteOSCore

public typealias BrokerOutboundQueue = RemoteOSCore.BrokerOutboundQueue

public final class HostBrokerConnection: NSObject, @unchecked Sendable {
    public var onRequest: (@Sendable (JsonRpcRequest) async -> Void)?
    public var onDisconnected: (@Sendable () async -> Void)?

    private let log = AppLogs.broker
    private let urlSession: URLSession
    private let outboundQueue = BrokerOutboundQueue()
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var shouldNotifyDisconnect = false

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        super.init()
    }

    public func connect(to wsURL: URL) {
        log.notice("Connecting broker websocket url=\(wsURL.absoluteString)")
        disconnect(notify: false)
        connectionGeneration += 1
        let generation = connectionGeneration
        shouldNotifyDisconnect = true
        let task = urlSession.webSocketTask(with: wsURL)
        webSocketTask = task
        task.resume()

        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop(generation: generation)
        }
    }

    public func disconnect() {
        log.notice("Disconnecting broker websocket")
        disconnect(notify: false)
    }

    private func disconnect(notify: Bool) {
        log.debug("Broker websocket cleanup notify=\(notify)")
        shouldNotifyDisconnect = notify
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        Task {
            await outboundQueue.clear()
        }
    }

    public func sendNotification<Payload: Encodable>(method: String, payload: Payload) async {
        do {
            if Self.shouldLogOutgoing(method: method) {
                log.debug("Sending broker notification method=\(method)")
            }
            let payloadData = try JSONEncoder().encode(payload)
            let payloadObject = try JSONSerialization.jsonObject(with: payloadData)
            let envelope: [String: Any] = [
                "jsonrpc": "2.0",
                "method": method,
                "params": payloadObject
            ]
            let data = try dataFromJSONObject(envelope)
            try await enqueueOutbound(
                data: data,
                kind: Self.isLowPriorityNotification(method: method) ? .frame : .control
            )
        } catch {
            log.error("Failed to send broker notification method=\(method) error=\(error.localizedDescription)")
        }
    }

    public func sendSuccess<Payload: Encodable>(id: String, payload: Payload) async {
        do {
            log.debug("Sending broker success id=\(id)")
            let payloadData = try JSONEncoder().encode(payload)
            let payloadObject = try JSONSerialization.jsonObject(with: payloadData)
            let envelope: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": payloadObject
            ]
            let data = try dataFromJSONObject(envelope)
            try await enqueueOutbound(data: data, kind: .control)
        } catch {
            log.error("Failed to send broker success id=\(id) error=\(error.localizedDescription)")
        }
    }

    public func sendError(id: String?, code: Int, message: String) async {
        log.error("Sending broker error id=\(id ?? "nil") code=\(code) message=\(message)")
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id as Any,
            "error": [
                "code": code,
                "message": message
            ]
        ]

        do {
            let data = try dataFromJSONObject(envelope)
            try await enqueueOutbound(data: data, kind: .control)
        } catch {
            log.error("Failed to send broker error id=\(id ?? "nil") code=\(code) error=\(error.localizedDescription)")
        }
    }

    private func enqueueOutbound(data: Data, kind: BrokerOutboundQueue.Kind) async throws {
        let generation = connectionGeneration
        try await outboundQueue.enqueue(kind: kind, data: data) { [weak self] payload in
            guard let self else {
                throw CancellationError()
            }
            try await self.sendRaw(payload, generation: generation)
        }
    }

    private func sendRaw(_ data: Data, generation: Int) async throws {
        guard generation == connectionGeneration, let task = webSocketTask else {
            throw CancellationError()
        }

        try await task.send(.data(data))
    }

    private func receiveLoop(generation: Int) async {
        defer {
            Task { [weak self] in
                guard let self else {
                    return
                }
                guard generation == self.connectionGeneration else {
                    return
                }

                let shouldNotify = self.shouldNotifyDisconnect
                self.shouldNotifyDisconnect = false
                if shouldNotify {
                    self.log.warning("Broker receive loop ended; notifying disconnect")
                    await self.onDisconnected?()
                }
            }
        }

        while !Task.isCancelled {
            do {
                guard let message = try await webSocketTask?.receive() else {
                    return
                }
                let data: Data
                switch message {
                case let .string(string):
                    data = Data(string.utf8)
                case let .data(messageData):
                    data = messageData
                @unknown default:
                    continue
                }

                let object = try anyDictionary(from: data)
                guard let method = object["method"] as? String else {
                    continue
                }
                let id = object["id"].map { String(describing: $0) }
                let params = stringDictionary(object["params"])
                self.log.info("Received broker request method=\(method) id=\(id ?? "nil")")
                let request = JsonRpcRequest(id: id, method: method, params: params)
                let handler = onRequest
                Task {
                    await handler?(request)
                }
            } catch {
                log.error("Broker receive loop failed error=\(error.localizedDescription)")
                return
            }
        }
    }

    private static func shouldLogOutgoing(method: String) -> Bool {
        switch method {
        case "host.status", "codex.status", "agent.turn", "agent.item", "trace.event":
            return true
        default:
            return false
        }
    }

    private static func isLowPriorityNotification(method: String) -> Bool {
        switch method {
        case "window.frame", "window.snapshot":
            return true
        default:
            return false
        }
    }
}

@available(*, deprecated, renamed: "HostBrokerConnection")
public typealias BrokerClient = HostBrokerConnection
