import Foundation
import SQLite3

struct NotebookLookup: Identifiable, Sendable {
    let id: Int64
    let word: String
    let source: String
    let date: Date
}

struct FavoriteExample: Sendable {
    let word: String
    let context: LookupContext
    let meaning: String

    var prompt: String {
        guard let range = Range(context.range, in: context.sentence) else { return context.sentence }
        return context.sentence.replacingCharacters(in: range, with: "_____")
    }
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

    func saveExample(word: String, context: LookupContext, meaning: String) async throws {
        guard let selected = context.selected, TextFilter.isSingleWord(selected),
              !word.isEmpty, !meaning.isEmpty else { throw NotebookStoreError.invalidExample }
        try await perform { db in
            try Self.check(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil), db)
            do {
                try Self.execute(db, "INSERT OR IGNORE INTO favorites VALUES (?, unixepoch())") {
                    try Self.bind(word, at: 1, to: $0)
                }
                try Self.execute(db, """
                    INSERT INTO favorite_examples VALUES (?, ?, ?, ?, ?, unixepoch(), ?, ?)
                    ON CONFLICT(word, sentence, word_start) DO UPDATE SET
                      word_length=excluded.word_length, meaning=excluded.meaning, saved_at=excluded.saved_at,
                      video_ref=coalesce(excluded.video_ref, favorite_examples.video_ref),
                      video_seconds=coalesce(excluded.video_seconds, favorite_examples.video_seconds)
                    """) { stmt in
                    try Self.bind(word, at: 1, to: stmt)
                    try Self.bind(context.sentence, at: 2, to: stmt)
                    try Self.check(sqlite3_bind_int64(stmt, 3, Int64(context.range.location)), db)
                    try Self.check(sqlite3_bind_int64(stmt, 4, Int64(context.range.length)), db)
                    try Self.bind(meaning, at: 5, to: stmt)
                    if let video = context.video, video.seconds.isFinite, video.seconds >= 0 {
                        try Self.bind(video.reference, at: 6, to: stmt)
                        try Self.check(sqlite3_bind_double(stmt, 7, video.seconds), db)
                    }
                }
                try Self.check(sqlite3_exec(db, "COMMIT", nil, nil, nil), db)
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    func examples(word: String) async throws -> [FavoriteExample] {
        try await perform { db in
            try Self.rows(db, """
                SELECT sentence, word_start, word_length, meaning, video_ref, video_seconds
                FROM favorite_examples WHERE word = ? ORDER BY saved_at DESC, sentence, word_start
                """, bind: { try Self.bind(word, at: 1, to: $0) }) { stmt in
                let reference = Self.text(stmt, 4)
                let video = reference.isEmpty ? nil : VideoBookmark(reference: reference, seconds: sqlite3_column_double(stmt, 5))
                let range = NSRange(location: Int(sqlite3_column_int64(stmt, 1)),
                                    length: Int(sqlite3_column_int64(stmt, 2)))
                let context = LookupContext(sentence: Self.text(stmt, 0), range: range, video: video)
                return FavoriteExample(word: word, context: context, meaning: Self.text(stmt, 3))
            }
        }
    }

    func reviewWords(now: Date = .now, calendar: Calendar = .current) async throws -> [String] {
        let start = calendar.startOfDay(for: now)
        guard let from = calendar.date(byAdding: .day, value: -6, to: start),
              let until = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return try await perform { db in
            let records = try Self.rows(db, """
                SELECT word, created_at FROM lookups WHERE created_at >= ? AND created_at < ?
                AND trigger IN ('hotkey', 'translate', 'menu', 'clipboard', 'region', 'subtitle')
                """, bind: { stmt in
                    try Self.check(sqlite3_bind_int64(stmt, 1, Int64(from.timeIntervalSince1970)), db)
                    try Self.check(sqlite3_bind_int64(stmt, 2, Int64(until.timeIntervalSince1970)), db)
                }) { stmt in
                    (Self.text(stmt, 0), Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1))))
                }
            let ranks = Dictionary(grouping: records, by: \.0).compactMap { word, hits in
                let days = Set(hits.map { calendar.startOfDay(for: $0.1) }).count
                let latest = hits.map(\.1).max() ?? .distantPast
                return days > 1 ? (word, days, hits.count, latest) : nil
            }
            return ranks.sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                if $0.2 != $1.2 { return $0.2 > $1.2 }
                if $0.3 != $1.3 { return $0.3 > $1.3 }
                return $0.0 < $1.0
            }.prefix(3).map(\.0)
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
            try Self.check(sqlite3_exec(handle, "PRAGMA foreign_keys = ON; BEGIN IMMEDIATE", nil, nil, nil), handle)
            let version = try Self.rows(handle, "PRAGMA user_version") { sqlite3_column_int($0, 0) }.first ?? 0
            switch version {
            case 0:
                let migration = """
                CREATE TABLE lookups (id INTEGER PRIMARY KEY, word TEXT NOT NULL,
                    source TEXT NOT NULL, trigger TEXT NOT NULL, created_at INTEGER NOT NULL);
                CREATE INDEX lookups_created_at ON lookups(created_at);
                CREATE INDEX lookups_word ON lookups(word);
                CREATE TABLE favorites (word TEXT PRIMARY KEY, created_at INTEGER NOT NULL) WITHOUT ROWID;
                """
                try Self.check(sqlite3_exec(handle, migration, nil, nil, nil), handle)
            case 1, 2:
                break
            default:
                throw NotebookStoreError.sqlite("此版本无法读取较新的笔记本格式")
            }
            if version < 2 {
                let migration = """
                CREATE TABLE favorite_examples (
                    word          TEXT NOT NULL REFERENCES favorites(word) ON DELETE CASCADE,
                    sentence      TEXT NOT NULL,
                    word_start    INTEGER NOT NULL CHECK (word_start >= 0),
                    word_length   INTEGER NOT NULL CHECK (word_length > 0),
                    meaning       TEXT NOT NULL,
                    saved_at      INTEGER NOT NULL,
                    video_ref     TEXT,
                    video_seconds REAL,
                    PRIMARY KEY (word, sentence, word_start),
                    CHECK ((video_ref IS NULL AND video_seconds IS NULL) OR
                           (video_ref IS NOT NULL AND video_seconds IS NOT NULL AND video_seconds >= 0))
                ) WITHOUT ROWID;
                PRAGMA user_version = 2;
                """
                try Self.check(sqlite3_exec(handle, migration, nil, nil, nil), handle)
            }
            try Self.check(sqlite3_exec(handle, "COMMIT", nil, nil, nil), handle)
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
    case invalidExample

    var errorDescription: String? {
        switch self {
        case .invalidExample: return "无法保存此原句"
        case .sqlite(let detail): return "无法访问笔记本：\(detail)"
        }
    }
}
