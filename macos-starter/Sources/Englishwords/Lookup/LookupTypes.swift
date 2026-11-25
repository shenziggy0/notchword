import AppKit

enum LookupTrigger: String, Sendable {
    case hotkey
    /// `⌥T`：跳过词典，直接把选中的内容送去翻译。
    case translate
    case menu
    case clipboard
    case hover
    case selection
    case region
    case notebook
    case subtitle
    case example

    var label: String {
        switch self {
        case .hotkey:    return "快捷键"
        case .translate: return "翻译快捷键"
        case .menu:      return "菜单栏"
        case .clipboard: return "剪贴板"
        case .hover:     return "悬停取词"
        case .selection: return "划词取词"
        case .region:    return "区域取词"
        case .notebook:  return "笔记本"
        case .example:   return "欢迎示例"
        case .subtitle:  return "字幕"
        }
    }

    /// 被动入口（悬停 / 划词）失败时不打扰用户。
    var isPassive: Bool {
        self == .hover || self == .selection
    }
}

enum LookupMode {
    /// 内置词库 → 系统词典 → 翻译
    case lookup
    /// 跳过词典，直接翻译（⌥T）
    case translate
}

struct LookupContext: Sendable {
    let sentence: String
    let range: NSRange
    let video: VideoBookmark?

    init(sentence: String, range: NSRange, video: VideoBookmark? = nil) {
        self.sentence = sentence
        self.video = video
        guard let slice = Range(range, in: sentence) else {
            self.range = NSRange(location: 0, length: 0)
            return
        }
        let trim = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        let selection = sentence[slice]
        var first = selection.startIndex
        var last = selection.endIndex
        while first < last && selection[first].unicodeScalars.allSatisfy(trim.contains) {
            first = selection.index(after: first)
        }
        while last > first {
            let previous = selection.index(before: last)
            guard selection[previous].unicodeScalars.allSatisfy(trim.contains) else { break }
            last = previous
        }
        self.range = NSRange(first..<last, in: sentence)
    }

    var selected: String? {
        guard sentence.utf16.count <= 800, range.length > 0,
              let slice = Range(range, in: sentence) else { return nil }
        return String(sentence[slice])
    }

    static func sentence(in text: String, selection: NSRange,
                         beginsAtBoundary: Bool = true, endsAtBoundary: Bool = true) -> LookupContext? {
        guard let slice = Range(selection, in: text) else { return nil }
        let stops: Set<Character> = [".", "!", "?", "。", "！", "？", "\n"]
        let before = text[..<slice.lowerBound].lastIndex { stops.contains($0) }
        let after = text[slice.upperBound...].firstIndex { stops.contains($0) }
        guard before != nil || beginsAtBoundary, after != nil || endsAtBoundary else { return nil }
        var start = before.map { text.index(after: $0) } ?? text.startIndex
        while start < slice.lowerBound && text[start].isWhitespace { start = text.index(after: start) }
        let end = after.map { text.index(after: $0) } ?? text.endIndex
        let sentence = String(text[start..<end])
        let offset = text[start..<slice.lowerBound].utf16.count
        let context = LookupContext(sentence: sentence, range: NSRange(location: offset, length: selection.length))
        return context.selected == nil ? nil : context
    }

    func match(_ pattern: String) -> String? {
        guard selected != nil else { return nil }
        let words = pattern.split(separator: " ").map {
            $0 == "{person}" ? "(?:me|you|him|her|us|them)" : NSRegularExpression.escapedPattern(for: String($0))
        }.joined(separator: #"\s+"#)
        guard let regex = try? NSRegularExpression(pattern: "(?<![A-Za-z])" + words + "(?![A-Za-z])",
                                                   options: .caseInsensitive) else { return nil }
        let matches = regex.matches(in: sentence, range: NSRange(sentence.startIndex..., in: sentence))
        guard let hit = matches.first(where: {
            $0.range.location <= range.location && NSMaxRange($0.range) >= NSMaxRange(range)
        }) else { return nil }
        return (sentence as NSString).substring(with: hit.range)
    }
}

struct VideoBookmark: Sendable {
    let reference: String
    let seconds: Double
}

struct LookupRequest {
    let text: String
    let trigger: LookupTrigger
    let screen: NSScreen?
    var mode: LookupMode = .lookup
    /// 入口处的说明，例如「未授权辅助功能，已改用剪贴板」。
    var note: String?
    var context: LookupContext?
    var previous: String?
}

/// 面板要展示的一次查询结果，与词典内部模型解耦。
struct LookupResult {
    let input: String              // 规范化后的输入词，或短句原文
    let kind: TextKind
    let title: String              // 词头；短句为空
    let phonetic: String
    let pos: String
    let tags: [String]
    var body: String               // 释义或译文
    let originalText: String?      // 翻译时展示的原文
    let segments: [Segment]
    let origin: String
    let source: String             // 内置词库 / 系统词典 / Apple 本地翻译 / 联网翻译
    var note: String?              // 降级说明，例如内置库读取失败

    var readings: [String] = []
    var phrase: String? = nil

    var notebookWord: String? {
        guard kind == .word else { return nil }
        let word = TextFilter.normalizeWord(title.isEmpty ? input : title)
        return word.isEmpty ? nil : word
    }

    static func word(input: String, entry: Entry, morphology: Morphology?, note: String?) -> LookupResult {
        LookupResult(
            input: input,
            kind: .word,
            title: entry.word,
            phonetic: entry.phonetic,
            pos: entry.pos,
            tags: entry.tags,
            body: entry.translation,
            originalText: nil,
            segments: morphology?.segments ?? [],
            origin: morphology?.origin ?? "",
            source: entry.dictionary,
            note: note
        )
    }

    static func translated(text: String,
                           kind: TextKind,
                           translation: String,
                           provider: String,
                           morphology: Morphology? = nil) -> LookupResult {
        LookupResult(
            input: text,
            kind: kind,
            title: kind == .word ? text : "",
            phonetic: "",
            pos: "",
            tags: [],
            body: translation,
            originalText: kind == .sentence ? text : nil,
            segments: morphology?.segments ?? [],
            origin: morphology?.origin ?? "",
            source: provider,
            note: nil
        )
    }
}

enum LookupState {
    case loading(LookupRequest)
    case result(LookupRequest, LookupResult)
    case miss(LookupRequest)
    case failure(LookupRequest, String)

    var request: LookupRequest {
        switch self {
        case .loading(let request), .result(let request, _), .miss(let request), .failure(let request, _):
            return request
        }
    }
}
