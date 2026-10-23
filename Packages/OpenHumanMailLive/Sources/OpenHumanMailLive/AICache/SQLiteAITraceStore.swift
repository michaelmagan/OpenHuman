import Foundation
import OpenHumanAI
import SQLite3

actor SQLiteAITraceStore: AITraceStore {
    enum StoreError: Error { case open(Int32), write(Int32) }

    static let fileName = "ai-traces.sqlite"
    private static let schemaVersion: Int32 = 1

    private var db: OpaquePointer?

    init(url: URL) throws {
        let handle = try SQLiteFileRecovery.open(url, status: Self.openStatus, Self.open)
        db = handle
    }

    isolated deinit {
        sqlite3_close_v2(db)
    }

    private static func openStatus(_ error: any Error) -> Int32? {
        guard case .open(let status)? = error as? StoreError else { return nil }
        return status
    }

    private static func open(_ url: URL) throws -> OpaquePointer? {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            _ = manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            throw StoreError.open(status)
        }
        sqlite3_busy_timeout(handle, 2_000)
        let setup = """
            CREATE TABLE IF NOT EXISTS traces (
                trace_id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                feature TEXT NOT NULL,
                task TEXT NOT NULL,
                trigger TEXT NOT NULL,
                account_keys TEXT NOT NULL,
                thread_key TEXT,
                parent_trace_id TEXT,
                group_id TEXT,
                prompt_id TEXT,
                prompt_digest TEXT,
                override_rev INTEGER,
                provider_id TEXT NOT NULL,
                provider_name TEXT NOT NULL,
                model TEXT,
                model_version TEXT,
                data_location TEXT NOT NULL,
                left_device INTEGER NOT NULL,
                params_json TEXT NOT NULL,
                system_text TEXT,
                input_text TEXT,
                input_parts_json TEXT NOT NULL,
                output_text TEXT,
                final_text TEXT,
                steps_json TEXT NOT NULL,
                counted_input_tokens INTEGER,
                context_tokens INTEGER,
                usage_json TEXT,
                latency_ms INTEGER,
                first_token_ms INTEGER,
                cache TEXT NOT NULL CHECK (cache IN ('hit','miss','none')),
                outcome TEXT NOT NULL CHECK (outcome IN ('completed','cached','failed','cancelled')),
                error_kind TEXT,
                error_text TEXT,
                rating INTEGER,
                bytes INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS traces_by_time ON traces (created_at);
            CREATE INDEX IF NOT EXISTS traces_by_feature ON traces (feature, created_at);
            CREATE INDEX IF NOT EXISTS traces_by_thread ON traces (thread_key, created_at);
            PRAGMA user_version = \(schemaVersion);
            """
        let check = SQLiteFileRecovery.quickCheck(handle)
        guard check == SQLITE_OK,
              sqlite3_exec(handle, setup, nil, nil, nil) == SQLITE_OK else {
            let code = check == SQLITE_OK ? sqlite3_errcode(handle) : check
            sqlite3_close_v2(handle)
            throw StoreError.open(code)
        }
        return handle
    }

    var userVersion: Int32 {
        guard let statement = prepare("PRAGMA user_version", []) else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
    }

    func append(_ trace: AITraceRecord, retention: AITraceRetention, now: Date) async throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try write("INSERT OR REPLACE INTO traces (\(Self.columns)) VALUES (\(Self.placeholders))", Self.values(trace))
            try prune(retention, now: now)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func amend(_ id: UUID, finalText: String?, steps: [AITraceStep]) async throws {
        guard let current = try await trace(id) else { return }
        let text = finalText ?? current.finalText
        let combined = current.steps + steps
        var updated = current
        updated.finalText = text
        try write("UPDATE traces SET final_text = ?, steps_json = ?, bytes = ? WHERE trace_id = ?", [
            text.map(Value.text) ?? .null, .text(Self.json(combined)), .int(Int64(updated.textBytes)),
            .text(id.uuidString),
        ])
    }

    func setRating(_ id: UUID, rating: Int?) async throws {
        try write("UPDATE traces SET rating = ? WHERE trace_id = ?",
                  [rating.map { .int(Int64($0)) } ?? .null, .text(id.uuidString)])
    }

    func recent(limit: Int) async throws -> [AITraceRecord] {
        rows("SELECT \(Self.columns) FROM traces ORDER BY created_at DESC, rowid DESC LIMIT ?", [.int(Int64(max(0, limit)))])
    }

    func traces(matching query: AITraceQuery, limit: Int) async throws -> [AITraceRecord] {
        var conditions: [String] = []
        var arguments: [Value] = []
        if let features = query.features {
            let names = features.map(\.rawValue).sorted()
            conditions.append("feature IN (\(Array(repeating: "?", count: names.count).joined(separator: ", ")))")
            arguments += names.map(Value.text)
        }
        if let triggers = query.triggers {
            let names = triggers.map(\.rawValue).sorted()
            conditions.append("trigger IN (\(Array(repeating: "?", count: names.count).joined(separator: ", ")))")
            arguments += names.map(Value.text)
        }
        switch query.rating {
        case nil: break
        case .rated: conditions.append("rating IS NOT NULL AND rating != 0")
        case .thumbsDown: conditions.append("rating < 0")
        }
        let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ") + " "
        return rows("SELECT \(Self.columns) FROM traces \(filter)ORDER BY created_at DESC, rowid DESC LIMIT ?",
                    arguments + [.int(Int64(max(0, limit)))])
    }

    func trace(_ id: UUID) async throws -> AITraceRecord? {
        rows("SELECT \(Self.columns) FROM traces WHERE trace_id = ?", [.text(id.uuidString)]).first
    }

    func delete(_ id: UUID) async throws {
        try write("DELETE FROM traces WHERE trace_id = ?", [.text(id.uuidString)])
    }

    func deleteAll() async throws {
        try write("DELETE FROM traces", [])
    }

    func forget(accountKey: String) async throws {
        try write("DELETE FROM traces WHERE instr(account_keys, ?) > 0", [.text(Self.marker(accountKey))])
    }

    private func prune(_ retention: AITraceRetention, now: Date) throws {
        try write("DELETE FROM traces WHERE created_at < ?", [.real(now.addingTimeInterval(-retention.keepFor).timeIntervalSince1970)])
        try write("""
            DELETE FROM traces WHERE trace_id IN (
                SELECT trace_id FROM (
                    SELECT trace_id, ROW_NUMBER() OVER (PARTITION BY feature ORDER BY created_at DESC, rowid DESC) AS position
                    FROM traces
                ) WHERE position > ?
            )
            """, [.int(Int64(retention.perFeature))])
        try write("""
            DELETE FROM traces WHERE trace_id IN (
                SELECT trace_id FROM (
                    SELECT trace_id, SUM(bytes) OVER (ORDER BY created_at DESC, rowid DESC) AS running FROM traces
                ) WHERE running > ?
            )
            """, [.int(Int64(retention.maxBytes))])
    }

    private enum Value { case int(Int64), real(Double), text(String), null }

    private static let columnNames = [
        "trace_id", "created_at", "feature", "task", "trigger", "account_keys", "thread_key", "parent_trace_id",
        "group_id", "prompt_id", "prompt_digest", "override_rev", "provider_id", "provider_name", "model",
        "model_version", "data_location", "left_device", "params_json", "system_text", "input_text",
        "input_parts_json", "output_text", "final_text", "steps_json", "counted_input_tokens", "context_tokens",
        "usage_json", "latency_ms", "first_token_ms", "cache", "outcome", "error_kind", "error_text", "rating", "bytes",
    ]
    private static let columns = columnNames.joined(separator: ", ")
    private static let placeholders = Array(repeating: "?", count: columnNames.count).joined(separator: ", ")

    private static func marker(_ key: String) -> String { "\u{1F}" + key + "\u{1F}" }

    private static func json<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ text: String?) -> T? {
        guard let text else { return nil }
        return try? JSONDecoder().decode(type, from: Data(text.utf8))
    }

    private static func values(_ trace: AITraceRecord) -> [Value] {
        func text(_ value: String?) -> Value { value.map(Value.text) ?? .null }
        func int(_ value: Int?) -> Value { value.map { .int(Int64($0)) } ?? .null }
        let accounts = trace.accountKeys.isEmpty ? "" : trace.accountKeys.map(marker).joined()
        return [
            .text(trace.id.uuidString), .real(trace.createdAt.timeIntervalSince1970), .text(trace.feature.rawValue),
            .text(trace.task.rawValue), .text(trace.trigger.rawValue), .text(accounts), text(trace.threadKey),
            text(trace.parentID?.uuidString), text(trace.groupID?.uuidString), text(trace.promptID?.description),
            text(trace.promptDigest), int(trace.overrideRevision), .text(trace.providerID.rawValue),
            .text(trace.providerName), text(trace.model), text(trace.modelVersion),
            .text(trace.dataLocation.traceValue), .int(trace.leftDevice ? 1 : 0), .text(json(trace.parameters)),
            text(trace.systemText), text(trace.inputText), .text(json(trace.inputParts)), text(trace.outputText),
            text(trace.finalText), .text(json(trace.steps)), int(trace.countedInputTokens), int(trace.contextTokens),
            trace.usage.map { .text(json($0)) } ?? .null, int(trace.latencyMilliseconds),
            int(trace.firstTokenMilliseconds), .text(trace.cache.rawValue), .text(trace.outcome.rawValue),
            text(trace.errorKind), text(trace.errorText), int(trace.rating), .int(Int64(trace.textBytes)),
        ]
    }

    private func rows(_ sql: String, _ arguments: [Value]) -> [AITraceRecord] {
        guard let statement = prepare(sql, arguments) else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [AITraceRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String? {
                sqlite3_column_type(statement, column) == SQLITE_NULL ? nil
                    : sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
            func int(_ column: Int32) -> Int? {
                sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, column))
            }
            guard let id = text(0).flatMap(UUID.init(uuidString:)),
                  let feature = text(2).flatMap(AIFeature.init(rawValue:)),
                  let task = text(3).flatMap(AITask.init(rawValue:)),
                  let trigger = text(4).flatMap(AITrigger.init(rawValue:)),
                  let providerID = text(12), let providerName = text(13),
                  let location = text(16).flatMap(AIDataLocation.init(traceValue:)),
                  let cache = text(30).flatMap(AITraceCacheUse.init(rawValue:)),
                  let outcome = text(31).flatMap(AITraceOutcome.init(rawValue:)) else { continue }
            let accounts = (text(5) ?? "").split(separator: "\u{1F}").map(String.init)
            out.append(AITraceRecord(
                id: id, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), feature: feature,
                task: task, trigger: trigger, accountKeys: accounts, threadKey: text(6),
                parentID: text(7).flatMap(UUID.init(uuidString:)), groupID: text(8).flatMap(UUID.init(uuidString:)),
                promptID: text(9).flatMap { PromptID($0) }, promptDigest: text(10), overrideRevision: int(11),
                providerID: AIProviderID(rawValue: providerID), providerName: providerName, model: text(14),
                modelVersion: text(15), dataLocation: location,
                parameters: Self.decode(AITraceParameters.self, text(18)) ?? AITraceParameters(),
                systemText: text(19), inputText: text(20),
                inputParts: Self.decode([AITracePart].self, text(21)) ?? [], outputText: text(22), finalText: text(23),
                steps: Self.decode([AITraceStep].self, text(24)) ?? [], countedInputTokens: int(25),
                contextTokens: int(26), usage: Self.decode(AIUsage.self, text(27)), latencyMilliseconds: int(28),
                firstTokenMilliseconds: int(29), cache: cache, outcome: outcome, errorKind: text(32),
                errorText: text(33), rating: int(34)))
        }
        return out
    }

    private func exec(_ sql: String) throws {
        let status = sqlite3_exec(db, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw StoreError.write(status) }
    }

    private func write(_ sql: String, _ arguments: [Value]) throws {
        guard let statement = prepare(sql, arguments) else { throw StoreError.write(sqlite3_errcode(db)) }
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { throw StoreError.write(status) }
    }

    private func prepare(_ sql: String, _ arguments: [Value]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        for (offset, value) in arguments.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .real(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, traceStoreTransient)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }
}

private var traceStoreTransient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
