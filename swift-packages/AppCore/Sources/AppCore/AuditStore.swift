import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public actor AuditStore {
    private var database: OpaquePointer?

    public init(appSupportDirectory: URL? = nil) throws {
        let baseDirectory: URL
        if let appSupportDirectory {
            baseDirectory = appSupportDirectory
        } else {
            baseDirectory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }

        let remoteDirectory = baseDirectory.appendingPathComponent("RemoteOS", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteDirectory, withIntermediateDirectories: true)
        let databaseURL = remoteDirectory.appendingPathComponent("audit.sqlite")
        var db: OpaquePointer?
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            throw AppCoreError.invalidResponse
        }
        database = db
        try Self.execute(on: db, """
        CREATE TABLE IF NOT EXISTS audit_events (
          id TEXT PRIMARY KEY,
          created_at TEXT NOT NULL,
          level TEXT NOT NULL,
          kind TEXT NOT NULL,
          task_id TEXT,
          message TEXT NOT NULL,
          metadata_json TEXT NOT NULL
        );
        """)
    }

    public func append(_ event: TraceEventPayload) throws {
        let metadataData = try JSONEncoder().encode(event.metadata)
        try Self.execute(
            on: database,
            """
            INSERT INTO audit_events (id, created_at, level, kind, task_id, message, metadata_json)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                event.id,
                event.createdAt,
                event.level,
                event.kind,
                event.taskId,
                event.message,
                String(decoding: metadataData, as: UTF8.self)
            ]
        )
    }

    public func recent(limit: Int = 30) throws -> [TraceEventPayload] {
        let sql = """
        SELECT id, created_at, level, kind, task_id, message, metadata_json
        FROM audit_events
        ORDER BY created_at DESC
        LIMIT ?;
        """

        guard let database else {
            return []
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AppCoreError.invalidResponse
        }
        defer {
            sqlite3_finalize(statement)
        }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var events: [TraceEventPayload] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            let createdAt = String(cString: sqlite3_column_text(statement, 1))
            let level = String(cString: sqlite3_column_text(statement, 2))
            let kind = String(cString: sqlite3_column_text(statement, 3))
            let taskID = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let message = String(cString: sqlite3_column_text(statement, 5))
            let metadataJSON = String(cString: sqlite3_column_text(statement, 6))
            let metadataData = Data(metadataJSON.utf8)
            let metadata = (try? JSONDecoder().decode([String: String].self, from: metadataData)) ?? [:]

            events.append(
                TraceEventPayload(
                    id: id,
                    taskId: taskID,
                    level: level,
                    kind: kind,
                    message: message,
                    createdAt: createdAt,
                    metadata: metadata
                )
            )
        }

        return events
    }

    private static func execute(on database: OpaquePointer?, _ sql: String, bindings: [String?] = []) throws {
        guard let database else {
            throw AppCoreError.invalidResponse
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AppCoreError.invalidResponse
        }
        defer {
            sqlite3_finalize(statement)
        }

        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            if let binding {
                sqlite3_bind_text(statement, position, binding, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, position)
            }
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AppCoreError.invalidResponse
        }
    }
}
