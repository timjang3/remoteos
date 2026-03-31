import Foundation

public actor BrokerOutboundQueue {
    public enum Kind: Sendable {
        case control
        case frame
    }

    private struct Entry {
        let data: Data
        let send: @Sendable (Data) async throws -> Void
        let continuation: CheckedContinuation<Void, Error>
    }

    private var sending = false
    private var controlQueue: [Entry] = []
    private var pendingFrame: Entry?

    public init() {}

    public func enqueue(
        kind: Kind,
        data: Data,
        send: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let entry = Entry(data: data, send: send, continuation: continuation)
            switch kind {
            case .control:
                controlQueue.append(entry)
            case .frame:
                pendingFrame?.continuation.resume()
                pendingFrame = entry
            }

            guard !sending else {
                return
            }

            sending = true
            let firstEntry = takeNextEntry()
            Task {
                await self.flush(startingWith: firstEntry)
            }
        }
    }

    public func clear(error: Error = CancellationError()) {
        let pendingControl = controlQueue
        let pendingFrame = pendingFrame
        controlQueue.removeAll()
        self.pendingFrame = nil

        for entry in pendingControl {
            entry.continuation.resume(throwing: error)
        }
        pendingFrame?.continuation.resume(throwing: error)
    }

    private func takeNextEntry() -> Entry? {
        if !controlQueue.isEmpty {
            return controlQueue.removeFirst()
        }

        let frame = pendingFrame
        pendingFrame = nil
        return frame
    }

    private func flush(startingWith initialEntry: Entry?) async {
        var currentEntry = initialEntry
        while true {
            guard let entry = currentEntry ?? takeNextEntry() else {
                sending = false
                return
            }
            currentEntry = nil

            do {
                try await entry.send(entry.data)
                entry.continuation.resume()
            } catch {
                entry.continuation.resume(throwing: error)
            }
        }
    }
}
