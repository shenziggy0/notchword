import Foundation
import SQLite3

/// 词素元数据（`parts` 表一行）。
struct Morpheme {
    let role: String
    let label: String      // 词典形态，如 "believe" / "un-" / "-able"
    let zh: String
    let en: String
    let lemma: String
}

/// 内置词库。只读访问随包的两个 SQLite 文件。
///
/// 与旧实现的区别：
///   - 未命中返回 `nil`（真实未命中），不再伪造「翻译占位」词条
///   - 打开/查询失败用 `DictionaryError` 表达，可与未命中区分
///   - 词素按语素 ID 缓存，避免 N+1；`segments` 编码里的拼写优先于 `parts.label`
///   - 没有内置演示词；演示数据只在 `PreviewRenderer` 里显式构造
/// 所有 SQLite 访问都在串行队列上执行（同步方法只在单线程的诊断/预览路径使用），
/// 因此可以安全地跨队列传递。
final class DictionaryStore: @unchecked Sendable {

    private var db: OpaquePointer?
    private var partsDB: OpaquePointer?

    private var openError: DictionaryError?
    private var partsError: DictionaryError?

    private var parts: [Int32: Morpheme] = [:]
    private var partsLoaded = false
    private var morphologyCache: [String: Morphology] = [:]

    private let queue = DispatchQueue(label: "io.github.shenziggy0.notchword.dictionary")

    init(dictionaryURL: URL? = AppResources.dictionaryURL(),
         wordpartsURL: URL? = AppResources.wordpartsURL()) {

        if let dictionaryURL {
            openError = open(dictionaryURL, into: &db, required: ["words", "forms"])
        } else {
            openError = .unavailable("未找到 dictionary.sqlite")
        }

        if let wordpartsURL {
            partsError = open(wordpartsURL, into: &partsDB, required: ["parts", "words"])
        } else {
            partsError = .unavailable("未找到 wordparts.sqlite")
            FileLog.write("词素库缺失，词根词缀将不可用")
        }

        if let openError { FileLog.write(openError.localizedDescription) }
    }

    deinit {
        if let db { sqlite3_close(db) }
        if let partsDB { sqlite3_close(partsDB) }
    }

    // MARK: - 查询

    /// 单词查询。`.success(nil)` 表示真实未命中，`.failure` 表示词库本身有问题。
    /// 入口统一小写，避免大写输入绕过 `forms`/`words` 的精确匹配。
    func lookup(_ word: String) -> Result<Entry?, DictionaryError> {
        queue.sync { lookupSync(word.lowercased()) }
    }

    /// 词素补充查询。与释义是否命中无关；缺失只返回 `nil`，不影响释义展示。
    func morphology(_ word: String) -> Morphology? {
        queue.sync { morphologySync(word.lowercased()) }
    }

    /// 屈折还原：`abandoned` → `abandon`。查不到时返回 nil。
    func lemma(for form: String) -> String? {
        queue.sync { lemmaSync(form.lowercased()) }
    }

    // MARK: - 异步包装（串行队列）

    func lookupAsync(_ word: String) async -> Result<Entry?, DictionaryError> {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.lookupSync(word.lowercased())) }
        }
    }

    func morphologyAsync(_ word: String) async -> Morphology? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.morphologySync(word.lowercased())) }
        }
    }

    // MARK: - 同步核心（只在串行队列上执行）

    private func lookupSync(_ word: String) -> Result<Entry?, DictionaryError> {
        do {
            return .success(try findEntry(word))
        } catch let error as DictionaryError {
            return .failure(error)
        } catch {
            return .failure(.query(error.localizedDescription))
        }
    }

    private func morphologySync(_ word: String) -> Morphology? {
        if let cached = morphologyCache[word] { return cached }
        let resolved = resolveMorphology(word)
        if let resolved { morphologyCache[word] = resolved }
        return resolved
    }

    private func lemmaSync(_ form: String) -> String? {
        guard let db, openError == nil else { return nil }
        return try? SQLite.querySingle(db, "SELECT lemma FROM forms WHERE form = ? LIMIT 1", form)
    }

    // MARK: - 实现

    private func findEntry(_ word: String) throws -> Entry? {
        if let openError { throw openError }
        guard let db else { throw DictionaryError.unavailable("词库未打开") }

        let headword = try SQLite.querySingle(db, "SELECT lemma FROM forms WHERE form = ? LIMIT 1", word) ?? word
        return try queryWord(db, headword)
    }

    private func queryWord(_ db: OpaquePointer, _ headword: String) throws -> Entry? {
        let stmt = try SQLite.prepare(db, "SELECT word, phonetic, translation, pos, tag FROM words WHERE word = ? LIMIT 1")
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, headword, -1, SQLITE_TRANSIENT)
        switch sqlite3_step(stmt) {
        case SQLITE_ROW:  break
        case SQLITE_DONE: return nil
        default:          throw DictionaryError.query(String(cString: sqlite3_errmsg(db)))
        }

        func column(_ index: Int32) -> String {
            guard let text = sqlite3_column_text(stmt, index) else { return "" }
            return String(cString: text)
        }

        var entry = Entry(word: column(0), dictionary: "内置词库")
        entry.phonetic = column(1)
        entry.translation = column(2)
        entry.pos = column(3)
        entry.tags = column(4).split(separator: " ").map { Self.prettyTag(String($0)) }
        return entry
    }

    private func resolveMorphology(_ word: String) -> Morphology? {
        guard partsDB != nil, partsError == nil else { return nil }
        if let morphology = morphologyExact(word) { return morphology }
        if let lemma = lemmaSync(word), lemma != word {
            return morphologyExact(lemma)
        }
        return nil
    }

    private func morphologyExact(_ word: String) -> Morphology? {
        guard let partsDB else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT segments, origin FROM words WHERE word = ? LIMIT 1"
        guard sqlite3_prepare_v2(partsDB, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, word, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let rawText = sqlite3_column_text(stmt, 0) else { return nil }

        let raw = String(cString: rawText)
        let origin = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        guard loadParts() else { return nil }

        let segments = Self.parseSegments(raw) { self.parts[$0] }
        guard !segments.isEmpty else { return nil }
        return Morphology(segments: segments, origin: origin)
    }

    @discardableResult
    private func loadParts() -> Bool {
        if partsLoaded { return !parts.isEmpty }
        guard let partsDB else { return false }

        var stmt: OpaquePointer?
        let sql = "SELECT id, role, label, zh, en, lemma FROM parts"
        guard sqlite3_prepare_v2(partsDB, sql, -1, &stmt, nil) == SQLITE_OK else {
            FileLog.write("词素表读取失败")
            return false
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            func column(_ index: Int32) -> String {
                guard let text = sqlite3_column_text(stmt, index) else { return "" }
                return String(cString: text)
            }
            parts[Int32(sqlite3_column_int(stmt, 0))] = Morpheme(
                role: column(1), label: column(2), zh: column(3), en: column(4), lemma: column(5)
            )
        }
        partsLoaded = true
        return !parts.isEmpty
    }

    // MARK: - SQLite 辅助

    private func open(_ url: URL, into handle: inout OpaquePointer?, required: [String]) -> DictionaryError? {
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开 \(url.lastPathComponent)"
            if let pointer { sqlite3_close(pointer) }
            return .unavailable(message)
        }
        handle = pointer

        for table in required where !tableExists(pointer, table) {
            return .schema("缺少表 \(table)")
        }
        return nil
    }

    private func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: - 解析

    /// 解析 `"un:12 believ:34 able:56"`。
    ///
    /// 展示用拼写来自编码本身，`parts.label` 只作为兜底。
    static func parseSegments(_ raw: String, resolve: (Int32) -> Morpheme?) -> [Segment] {
        raw.split(separator: " ").compactMap { piece in
            let parts = piece.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let id = Int32(parts[1]), let morpheme = resolve(id) else { return nil }
            let spelling = String(parts[0]).trimmingCharacters(in: .whitespaces)
            return Segment(role: morpheme.role,
                           label: spelling.isEmpty ? morpheme.label : spelling,
                           gloss: morpheme.zh)
        }
    }

    static func prettyTag(_ tag: String) -> String {
        switch tag {
        case "zk":    return "中考"
        case "gk":    return "高考"
        case "cet4":  return "四级"
        case "cet6":  return "六级"
        case "ky":    return "考研"
        case "toefl": return "托福"
        case "ielts": return "雅思"
        case "gre":   return "GRE"
        default:      return tag.uppercased()
        }
    }
}
