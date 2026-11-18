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

func writeSQLite(_ url: URL, _ sql: String) throws {
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

@Suite("查词与翻译回归")
@MainActor
struct LookupRegressionTests {
    private let request = TranslationRequest(text: "hello", source: "en", target: "zh-Hans")

    @Test("代码候选不进入查词，但普通英文保留",
          arguments: ["const token = \"example\";", "foo(bar)", "print(123)"])
    func filtersCode(_ code: String) {
        guard case .rejected(.code) = TextFilter.classify(code) else {
            Issue.record("代码候选未被过滤")
            return
        }
        #expect(sentence(from: "Try again (if needed).") != nil)
        #expect(word(from: "don't") == "don't")
        #expect(word(from: "well-known") == "well-known")
    }

    @Test("超时先于不响应取消的底层任务返回")
    func timesOutBeforeUnderlyingTaskFinishes() async {
        let (release, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        // detached 模拟无需等待调用方取消的框架请求。
        let underlying = Task.detached {
            var iterator = release.makeAsyncIterator()
            _ = await iterator.next()
            return "late"
        }
        // 安全阀使旧实现也能结束，随后下方断言会抓到回归。
        var releasedBySafetyTimer = false
        let safetyTimer = Task {
            guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            releasedBySafetyTimer = true
            continuation.finish()
        }
        defer { safetyTimer.cancel() }

        do {
            _ = try await withTimeout(0.05) { await underlying.value }
            Issue.record("预期超时")
        } catch TranslationError.timedOut {
            #expect(!releasedBySafetyTimer)
        } catch {
            Issue.record("意外错误：\(error)")
        }
    }

    @Test("本地失败按配置降级，取消不发联网请求",
          arguments: ["fallback", "disabled", "missing", "cancelled"])
    func fallbackUsesCurrentConfiguration(_ scenario: String) async {
        let name = "io.github.shenziggy0.notchword.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        preferences.onlineEnabled = scenario != "disabled"

        let local = StubProvider {
            if scenario == "cancelled" { throw URLError(.cancelled) }
            throw CocoaError(.fileReadUnknown)
        }
        var onlineCalls = 0
        let online = StubProvider {
            onlineCalls += 1
            return TranslationResult(text: "你好", providerID: "stub", providerName: "测试服务")
        }
        let translator = TranslationCoordinator(preferences: preferences, apple: local) {
            scenario == "missing" ? nil : online
        }

        do {
            let result = try await translator.translate(request)
            #expect(scenario == "fallback")
            #expect(result.text == "你好")
        } catch TranslationError.configurationMissing {
            #expect(scenario == "missing")
        } catch TranslationError.cancelled {
            #expect(scenario == "cancelled")
        } catch is CocoaError {
            #expect(scenario == "disabled")
        } catch {
            Issue.record("意外错误：\(error)")
        }
        #expect(onlineCalls == (scenario == "fallback" ? 1 : 0))
    }

    @Test("被动拒绝不会中止译文，缺语言包显示真实原因")
    func passiveRejectionKeepsCurrentLookup() async throws {
        let (finish, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { continuation.finish() }
        let (states, stateFeed) = AsyncStream<LookupState>.makeStream()
        defer { stateFeed.finish() }
        let coordinator = LookupCoordinator(
            store: DictionaryStore(dictionaryURL: nil, wordpartsURL: nil),
            systemDictionary: MissingSystemDictionary(),
            translator: StubProvider {
                var input = finish.makeAsyncIterator()
                _ = await input.next()
                throw TranslationError.languagePackRequired
            },
            preferences: .shared
        )
        coordinator.onState = { stateFeed.yield($0) }
        defer { coordinator.cancel() }

        #expect(coordinator.submit(LookupRequest(text: "hello", trigger: .translate, screen: nil, mode: .translate)))
        #expect(!coordinator.submit(LookupRequest(text: "https://example.com", trigger: .selection, screen: nil)))
        continuation.yield(())
        try await withTimeout(1) {
            var output = states.makeAsyncIterator()
            guard case .loading? = await output.next(),
                  case .failure(_, let message)? = await output.next() else {
                Issue.record("预期加载后提示语言包缺失")
                return
            }
            #expect(message.contains("准备语言包"))
        }
    }

    @Test("空白保存保留既有密钥")
    func emptySavePreservesKey() throws {
        let account = "test-\(UUID())"
        defer { SecretStore.delete(account: account) }
        try SecretStore.save("isolated-test-key", account: account).get()

        for value in ["", "  \n"] {
            guard case .failure(.emptyValue) = SecretStore.save(value, account: account) else {
                Issue.record("空白保存应失败")
                return
            }
            #expect(SecretStore.read(account: account) == "isolated-test-key")
        }

        try SecretStore.delete(account: account).get()
        #expect(SecretStore.read(account: account) == nil)
    }
}

@MainActor
private struct StubProvider: TranslationProviding, Translating {
    let id = "stub"
    let displayName = "测试服务"
    let operation: () async throws -> TranslationResult

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try await operation()
    }
}
