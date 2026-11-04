import AppKit

enum LookupTrigger {
    case hotkey
    /// `⌥T`：跳过词典，直接把选中的内容送去翻译。
    case translate
    case menu
    case clipboard
    case hover
    case selection
    case region

    var label: String {
        switch self {
        case .hotkey:    return "快捷键"
        case .translate: return "翻译快捷键"
        case .menu:      return "菜单栏"
        case .clipboard: return "剪贴板"
        case .hover:     return "悬停取词"
        case .selection: return "划词取词"
        case .region:    return "区域取词"
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

struct LookupRequest {
    let text: String
    let trigger: LookupTrigger
    let screen: NSScreen?
    var mode: LookupMode = .lookup
    /// 入口处的说明，例如「未授权辅助功能，已改用剪贴板」。
    var note: String?
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
