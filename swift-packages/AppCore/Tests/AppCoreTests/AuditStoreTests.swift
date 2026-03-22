import Foundation
import Testing
@testable import AppCore

@Test func auditStorePersistsRecentEvents() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let store = try AuditStore(appSupportDirectory: directory)
    let event = TraceEventPayload(
        id: UUID().uuidString,
        taskId: nil,
        level: "info",
        kind: "test",
        message: "hello",
        createdAt: isoNow(),
        metadata: ["key": "value"]
    )
    try await store.append(event)

    let recent = try await store.recent(limit: 5)
    #expect(recent.first?.message == "hello")
}
