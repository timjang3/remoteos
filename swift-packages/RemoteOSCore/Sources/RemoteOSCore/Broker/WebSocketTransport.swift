import Foundation

public protocol RemoteOSWebSocketTransport: Sendable {
    func connect(to url: URL) async throws
    func disconnect() async
    func send(_ data: Data) async throws
    func receive() async throws -> Data
}

public actor URLSessionWebSocketTransport: RemoteOSWebSocketTransport {
    private let urlSession: URLSession
    private var task: URLSessionWebSocketTask?

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func connect(to url: URL) async throws {
        await disconnect()
        let nextTask = urlSession.webSocketTask(with: url)
        task = nextTask
        nextTask.resume()
    }

    public func disconnect() async {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    public func send(_ data: Data) async throws {
        guard let task else {
            throw AppCoreError.transportUnavailable
        }
        try await task.send(.data(data))
    }

    public func receive() async throws -> Data {
        guard let task else {
            throw AppCoreError.transportUnavailable
        }

        let message = try await task.receive()
        switch message {
        case let .data(data):
            return data
        case let .string(string):
            return Data(string.utf8)
        @unknown default:
            throw AppCoreError.invalidResponse
        }
    }
}
