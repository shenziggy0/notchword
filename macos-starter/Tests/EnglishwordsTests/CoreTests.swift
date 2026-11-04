import Foundation
import SQLite3
import Testing
@testable import Englishwords

// 只覆盖核心逻辑：文本分类、词素拼写、响应清洗。
// TCC、焦点、多屏和真实翻译属于实机验收，不做重复实现逻辑的测试。

private func word(from text: String) -> String? {
    if case .word(let value) = TextFilter.classify(text) { return value }
    return nil
}

private func sentence(from text: String) -> String? {
    if case .sentence(let value) = TextFilter.classify(text) { return value }
    return nil
}

private func isRejected(_ text: String) -> Bool {
    if case .rejected = TextFilter.classify(text) { return true }
    return false
}

@Suite("文本分类")
struct TextFilterTests {

    @Test("单词会被规范化")
    func singleWordIsNormalized() {
        #expect(word(from: "  Unbelievable,  ") == "unbelievable")
    }

    @Test("所有格与标点")
    func possessiveAndPunctuation() {
        #expect(TextFilter.normalizeWord("dog's") == "dog")
        #expect(TextFilter.normalizeWord("“word”") == "word")
        #expect(TextFilter.normalizeWord("well-known") == "well-known")
        #expect(TextFilter.normalizeWord("don't") == "don't")
    }

    @Test("短句保留原文")
    func sentenceKeepsOriginal() {
        let original = "Hello, world. This is a test."
        #expect(sentence(from: original) == original)
    }

    @Test("网址、邮箱、域名被拒绝")
    func rejectsLinks() {
        #expect(isRejected("https://example.com/a?b=1"))
        #expect(isRejected("someone@example.com"))
        #expect(isRejected("example.com"))
    }

    @Test("数字与中文被拒绝")
    func rejectsNumbersAndChinese() {
        #expect(isRejected("12345"))
        #expect(isRejected("你好"))
    }

    @Test("超长文本被拒绝")
    func rejectsTooLong() {
        #expect(isRejected(String(repeating: "word ", count: 100)))
    }
}

@Suite("词素解析")
struct SegmentTests {

    private let morphemes: [Int32: Morpheme] = [
        1: Morpheme(role: "prefix", label: "un-", zh: "不", en: "not", lemma: ""),
        2: Morpheme(role: "root", label: "believe", zh: "相信", en: "believe", lemma: "credere"),
        3: Morpheme(role: "suffix", label: "-able", zh: "能……的", en: "capable of", lemma: "")
    ]

    @Test("使用 segments 里的实际拼写，而不是 parts.label")
    func usesEncodedSpelling() {
        let segments = DictionaryStore.parseSegments("un:1 believ:2 able:3") { morphemes[$0] }
        #expect(segments.map(\.label) == ["un", "believ", "able"])
        #expect(segments.map(\.role) == ["prefix", "root", "suffix"])
        #expect(segments.map(\.gloss) == ["不", "相信", "能……的"])
    }

    @Test("无效引用会被丢弃")
    func dropsUnknownMorpheme() {
        let segments = DictionaryStore.parseSegments("un:9 xx:y") { _ in nil }
        #expect(segments.isEmpty)
    }
}

@Suite("热键规格")
struct HotKeySpecTests {

    @Test("编码后解码与原值相等")
    func roundTrip() throws {
        let spec = HotKeySpec.lookup
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(HotKeySpec.self, from: data)
        #expect(decoded == spec)
    }
}

@Suite("屏幕文字聚行")
struct ScreenTextMergeTests {

    @Test("相近的 y 合成一行，行内按 x 排序")
    func mergesNearbyBoxes() {
        let lines = ScreenText.mergeLines([
            RecognizedFragment(text: "b", x: 0.40, y: 0.80),
            RecognizedFragment(text: "a", x: 0.10, y: 0.81),
            RecognizedFragment(text: "c", x: 0.20, y: 0.60)
        ])
        #expect(lines == ["a b", "c"])
    }
}

@Suite("翻译保留拆分")
struct MorphologyOnTranslationTests {

    @Test("词库和系统词典都未命中时，翻译结果仍带词素")
    @MainActor
    func translationKeepsMorphology() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("englishwords-morphology-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let dictionaryURL = folder.appendingPathComponent("dictionary.sqlite")
        let wordpartsURL = folder.appendingPathComponent("wordparts.sqlite")
        try writeSQLite(dictionaryURL, """
            CREATE TABLE words (
                word TEXT PRIMARY KEY, phonetic TEXT, translation TEXT,
                pos TEXT, tag TEXT, frq INTEGER
            );
            CREATE TABLE forms (form TEXT, lemma TEXT);
            """)
        try writeSQLite(wordpartsURL, """
            CREATE TABLE parts (
                id INTEGER PRIMARY KEY, role TEXT NOT NULL, label TEXT NOT NULL,
                zh TEXT NOT NULL, en TEXT NOT NULL, lemma TEXT
            );
            CREATE TABLE words (
                word TEXT PRIMARY KEY, segments TEXT NOT NULL, origin TEXT
            );
            INSERT INTO parts (id, role, label, zh, en, lemma)
                VALUES (1, 'prefix', 'zzqx-', '甲', 'a', NULL),
                       (2, 'root', 'morph', '乙', 'b', NULL);
            INSERT INTO words (word, segments, origin)
                VALUES ('zzqxmorph', 'zzqx:1 morph:2', '合成');
            """)

        let suite = "io.github.shenziggy0.notchword.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let coordinator = LookupCoordinator(
            store: DictionaryStore(dictionaryURL: dictionaryURL, wordpartsURL: wordpartsURL),
            systemDictionary: MissingSystemDictionary(),
            translator: FixedTranslator(),
            preferences: preferences
        )

        let state: LookupState = await withCheckedContinuation { continuation in
            var resumed = false
            coordinator.onState = { state in
                if case .loading = state { return }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: state)
            }
            coordinator.submit(LookupRequest(text: "zzqxmorph", trigger: .hotkey, screen: nil))
        }

        guard case .result(_, let result) = state else {
            Issue.record("预期是翻译结果，实际 \(state)")
            return
        }
        #expect(result.source == "固定译文")
        #expect(result.segments.map(\.label) == ["zzqx", "morph"])
        #expect(result.origin == "合成")
    }
}

private struct MissingSystemDictionary: SystemDictionaryLooking {
    func lookup(_ word: String) -> Entry? { nil }
}

@MainActor
private struct FixedTranslator: Translating {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        TranslationResult(text: "固定译文", providerID: "fixed", providerName: "固定译文")
    }
}

private func writeSQLite(_ url: URL, _ sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw SQLiteTestError("无法创建 \(url.lastPathComponent)")
    }
    defer { sqlite3_close(db) }
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
        let message = error.map { String(cString: $0) } ?? "sqlite"
        sqlite3_free(error)
        throw SQLiteTestError(message)
    }
}

private struct SQLiteTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@Suite("响应清洗")
struct ProviderCleanTests {

    @Test("剥离 think 段与引号")
    func removesThinkBlock() {
        #expect(OpenAICompatProvider.clean("<think>internal</think>\n“难以置信的”") == "难以置信的")
    }

    @Test("普通文本原样返回")
    func keepsPlainText() {
        #expect(OpenAICompatProvider.clean("  hello  ") == "hello")
    }

    @Test("系统词典去掉重复词头")
    func removesSystemDictionaryHeadword() {
        let raw = "hello\nBrE həˈləʊ\nA. noun 问候"
        #expect(SystemDictionaryBridge.clean(raw, headword: "hello") == "BrE həˈləʊ\nA. noun 问候")
    }
}
