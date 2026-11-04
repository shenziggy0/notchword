import Foundation
import SQLite3

/// `sqlite3_bind_text` 的瞬态析构：SQLite 会立刻拷贝字符串。
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 无状态 SQLite 辅助。不持有连接，词典与笔记本共用。
enum SQLite {

    static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DictionaryError.query(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    /// 单参数查询的第一列文本。没有行时返回 nil。
    static func querySingle(_ db: OpaquePointer, _ sql: String, _ argument: String) throws -> String? {
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, argument, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }
}
