import Foundation
import Testing
@testable import AppCore

private actor BlockingSender {
    private var sentMessages: [String] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func send(_ data: Data) async throws {
        sentMessages.append(String(decoding: data, as: UTF8.self))
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func messages() -> [String] {
        sentMessages
    }

    func completeNextSend() {
        guard !waiters.isEmpty else {
            return
        }
        let continuation = waiters.removeFirst()
        continuation.resume()
    }
}

private func encode(_ value: String) -> Data {
    Data(value.utf8)
}

private func drainTasks() async {
    await Task.yield()
    await Task.yield()
    await Task.yield()
}

private func waitForMessages(
    _ sender: BlockingSender,
    toEqual expected: [String],
    attempts: Int = 40
) async {
    for _ in 0..<attempts {
        if await sender.messages() == expected {
            return
        }
        await drainTasks()
    }
}

@Test func brokerOutboundQueueCoalescesQueuedFrames() async throws {
    let queue = BrokerOutboundQueue()
    let sender = BlockingSender()

    let first = Task {
        try await queue.enqueue(kind: .frame, data: encode("frame-1")) { data in
            try await sender.send(data)
        }
    }
    await waitForMessages(sender, toEqual: ["frame-1"])
    #expect(await sender.messages() == ["frame-1"])

    let second = Task {
        try await queue.enqueue(kind: .frame, data: encode("frame-2")) { data in
            try await sender.send(data)
        }
    }
    let third = Task {
        try await queue.enqueue(kind: .frame, data: encode("frame-3")) { data in
            try await sender.send(data)
        }
    }

    await sender.completeNextSend()
    _ = try await first.value
    _ = try await second.value

    await waitForMessages(sender, toEqual: ["frame-1", "frame-3"])
    #expect(await sender.messages() == ["frame-1", "frame-3"])

    await sender.completeNextSend()
    _ = try await third.value
}

@Test func brokerOutboundQueuePrioritizesControlAheadOfPendingFrame() async throws {
    let queue = BrokerOutboundQueue()
    let sender = BlockingSender()

    let firstFrame = Task {
        try await queue.enqueue(kind: .frame, data: encode("frame-1")) { data in
            try await sender.send(data)
        }
    }
    await waitForMessages(sender, toEqual: ["frame-1"])
    #expect(await sender.messages() == ["frame-1"])

    let secondFrame = Task {
        try await queue.enqueue(kind: .frame, data: encode("frame-2")) { data in
            try await sender.send(data)
        }
    }
    let control = Task {
        try await queue.enqueue(kind: .control, data: encode("control")) { data in
            try await sender.send(data)
        }
    }

    await sender.completeNextSend()
    _ = try await firstFrame.value
    await waitForMessages(sender, toEqual: ["frame-1", "control"])
    #expect(await sender.messages() == ["frame-1", "control"])

    await sender.completeNextSend()
    _ = try await control.value
    await waitForMessages(sender, toEqual: ["frame-1", "control", "frame-2"])
    #expect(await sender.messages() == ["frame-1", "control", "frame-2"])

    await sender.completeNextSend()
    _ = try await secondFrame.value
}

@Test func brokerOutboundQueueLetsLatestLiveFrameReplaceQueuedSnapshot() async throws {
    let queue = BrokerOutboundQueue()
    let sender = BlockingSender()

    let firstSnapshot = Task {
        try await queue.enqueue(kind: .frame, data: encode("snapshot-1")) { data in
            try await sender.send(data)
        }
    }
    await waitForMessages(sender, toEqual: ["snapshot-1"])
    #expect(await sender.messages() == ["snapshot-1"])

    let secondSnapshot = Task {
        try await queue.enqueue(kind: .frame, data: encode("snapshot-2")) { data in
            try await sender.send(data)
        }
    }
    let frame = Task {
        try await queue.enqueue(kind: .frame, data: encode("frame-1")) { data in
            try await sender.send(data)
        }
    }

    await drainTasks()
    await sender.completeNextSend()
    _ = try await firstSnapshot.value
    _ = try await secondSnapshot.value

    await waitForMessages(sender, toEqual: ["snapshot-1", "frame-1"])
    #expect(await sender.messages() == ["snapshot-1", "frame-1"])

    await sender.completeNextSend()
    _ = try await frame.value
}
