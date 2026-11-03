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
