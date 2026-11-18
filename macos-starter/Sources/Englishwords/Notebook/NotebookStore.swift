import Foundation
import SQLite3

struct NotebookLookup: Identifiable, Sendable {
    let id: Int64
    let word: String
    let source: String
    let date: Date
}

struct NotebookStats: Sendable {
    let total: Int
    let daily: [(date: Date, count: Int)]
    let frequent: [(word: String, count: Int)]
}

final class NotebookStore: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "io.github.shenziggy0.notchword.notebook")
    private var database: OpaquePointer?

    init(url: URL = URL.applicationSupportDirectory
        .appendingPathComponent("Englishwords/user.sqlite")) {
        self.url = url
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func recordLookup(word: String, source: String, trigger: LookupTrigger, date: Date = .now) async throws {
        try await perform { db in
            try Self.execute(db, "INSERT INTO lookups(word, source, trigger, created_at) VALUES (?, ?, ?, ?)") { stmt in
                try Self.bind(word, at: 1, to: stmt)
                try Self.bind(source, at: 2, to: stmt)
                try Self.bind(trigger.rawValue, at: 3, to: stmt)
                try Self.check(sqlite3_bind_int64(stmt, 4, Int64(date.timeIntervalSince1970)), db)
            }
        }
    }

    func setFavorite(word: String, on: Bool) async throws {
        try await perform { db in
            let sql = on
                ? "INSERT OR IGNORE INTO favorites(word, created_at) VALUES (?, unixepoch())"
                : "DELETE FROM favorites WHERE word = ?"
            try Self.execute(db, sql) { stmt in try Self.bind(word, at: 1, to: stmt) }
        }
    }

    func favorites() async throws -> [String] {
        try await perform { db in
            try Self.rows(db, "SELECT word FROM favorites ORDER BY created_at DESC, word") {
                Self.text($0, 0)
            }
        }
    }

    func history(limit: Int = 200) async throws -> [NotebookLookup] {
        try await perform { db in
            try Self.rows(db, "SELECT id, word, source, created_at FROM lookups ORDER BY created_at DESC, id DESC LIMIT ?",
                          bind: { stmt in try Self.check(sqlite3_bind_int(stmt, 1, Int32(clamping: max(0, limit))), db) }) {
                NotebookLookup(id: sqlite3_column_int64($0, 0), word: Self.text($0, 1), source: Self.text($0, 2),
                               date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64($0, 3))))
            }
        }
    }

    func stats(now: Date = .now, calendar: Calendar = .current) async throws -> NotebookStats {
        let today = calendar.startOfDay(for: now)
        let days = (0...7).compactMap { calendar.date(byAdding: .day, value: $0 - 6, to: today) }
        return try await perform { db in
            let total = try Self.rows(db, "SELECT count(*) FROM lookups") {
                Int(sqlite3_column_int64($0, 0))
            }.first ?? 0
            let frequent = try Self.rows(db, "SELECT word, count(*) FROM lookups GROUP BY word ORDER BY count(*) DESC, word LIMIT 20") {
                (word: Self.text($0, 0), count: Int(sqlite3_column_int64($0, 1)))
            }
            let daily = try zip(days, days.dropFirst()).map { day, next in
                let count = try Self.rows(db, "SELECT count(*) FROM lookups WHERE created_at >= ? AND created_at < ?",
                                          bind: { stmt in
                    try Self.check(sqlite3_bind_int64(stmt, 1, Int64(day.timeIntervalSince1970)), db)
                    try Self.check(sqlite3_bind_int64(stmt, 2, Int64(next.timeIntervalSince1970)), db)
                }) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
                return (date: day, count: count)
            }
            return NotebookStats(total: total, daily: daily, frequent: frequent)
        }
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable (OpaquePointer) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try operation(self.open()) })
            }
        }
    }

    private func open() throws -> OpaquePointer {
        if let database { return database }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard let handle else { throw NotebookStoreError.sqlite("无法打开笔记本") }
        do {
            try Self.check(result, handle)
            try Self.check(sqlite3_busy_timeout(handle, 1_000), handle)
            let version = try Self.rows(handle, "PRAGMA user_version") { sqlite3_column_int($0, 0) }.first ?? 0
            switch version {
            case 0:
                let migration = """
                BEGIN;
                CREATE TABLE lookups (id INTEGER PRIMARY KEY, word TEXT NOT NULL,
                    source TEXT NOT NULL, trigger TEXT NOT NULL, created_at INTEGER NOT NULL);
                CREATE INDEX lookups_created_at ON lookups(created_at);
                CREATE INDEX lookups_word ON lookups(word);
                CREATE TABLE favorites (word TEXT PRIMARY KEY, created_at INTEGER NOT NULL) WITHOUT ROWID;
                PRAGMA user_version = 1;
                COMMIT;
                """
                try Self.check(sqlite3_exec(handle, migration, nil, nil, nil), handle)
            case 1:
                break
            default:
                throw NotebookStoreError.sqlite("此版本无法读取较新的笔记本格式")
            }
            database = handle
            return handle
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    private static func execute(_ db: OpaquePointer, _ sql: String,
                                bind: (OpaquePointer) throws -> Void) throws {
        let stmt = try SQLite.prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt)
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE else { throw error(db) }
    }

    private static func rows<T>(_ db: OpaquePointer, _ sql: String,
                                bind: ((OpaquePointer) throws -> Void)? = nil,
                                read: (OpaquePointer) -> T) throws -> [T] {
        let stmt = try SQLite.prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        try bind?(stmt)
        var values: [T] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: values.append(read(stmt))
            case SQLITE_DONE: return values
            default: throw error(db)
            }
        }
    }

    private static func text(_ stmt: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
    }

    private static func bind(_ value: String, at index: Int32, to stmt: OpaquePointer) throws {
        try check(sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT), sqlite3_db_handle(stmt))
    }

    private static func check(_ status: Int32, _ db: OpaquePointer?) throws {
        guard status == SQLITE_OK else { throw error(db) }
    }

    private static func error(_ db: OpaquePointer?) -> NotebookStoreError {
        .sqlite(String(cString: sqlite3_errmsg(db)))
    }
}

private enum NotebookStoreError: LocalizedError {
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let detail): return "无法访问笔记本：\(detail)"
        }
    }
}
