import Foundation

enum TextKind {
    case word
    case sentence
}

enum RejectReason {
    case empty
    case tooLong
    case url
    case email
    case domain
    case code
    case noLetters
    case unsupportedScript

    /// 显式入口给的提示；被动入口静默丢弃，不打扰用户。
    var message: String {
        switch self {
        case .empty:              return "没有取到文字。\n先选中一个英文单词或短句，再试一次。"
        case .tooLong:            return "选中的内容太长，只支持单词或短句。"
        case .url:                return "这是一个网址，不做翻译。"
        case .email:              return "这是一个邮箱地址，不做翻译。"
        case .domain:             return "这是一个域名，不做翻译。"
        case .code:               return "选中的内容看起来是代码，不做翻译。"
        case .noLetters:          return "没有找到英文内容。"
        case .unsupportedScript:  return "目前只支持英文查词与英译中。"
        }
    }
}

enum TextClassification {
    case word(String)          // 规范化后的查询词
    case sentence(String)      // 保留原文，不做清洗
    case rejected(RejectReason)
}

/// 把 AX 采集到的文本分成「单词 / 短句 / 拒绝」。
///
/// 关键点：原文永远保留给翻译，只有单词才生成规范化查询词。
/// 旧实现把所有字符粘成一个字符串，会把整句拼成乱码。
enum TextFilter {

    static let maxSentenceLength = 300
    static let maxPassiveLength = 300

    private static let wordScalars = CharacterSet.letters
        .union(CharacterSet.nonBaseCharacters)
        .union(CharacterSet(charactersIn: "-'’"))

    /// 只剥首尾常见标点，不用 `wordScalars.inverted`，避免把数字、% 和空格裁掉。
    private static let surroundingPunctuation = CharacterSet(
        charactersIn: "\"'“”‘’()[]{}.,!?;:「」『』【】《》"
    )

    /// 英文单复数写法：`item(s)`、`box(es)` 仍是一个单词。
    private static let pluralNotation = #"^[A-Za-z][\w'’\-]*\((?:s|es|ies)\)$"#

    static func classify(_ raw: String) -> TextClassification {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .rejected(.empty) }
        guard text.count <= maxSentenceLength else { return .rejected(.tooLong) }
        guard !containsUnsupportedScript(text) else { return .rejected(.unsupportedScript) }

        let lowercased = text.lowercased()
        if lowercased.range(of: #"^[a-z][a-z0-9+.\-]*://"#, options: .regularExpression) != nil {
            return .rejected(.url)
        }
        if lowercased.range(of: #"^[^\s@]+@[^\s@]+\.[a-z]{2,}$"#, options: .regularExpression) != nil {
            return .rejected(.email)
        }
        if lowercased.range(of: #"^[a-z0-9\-]+(\.[a-z0-9\-]+)*\.(com|org|net|io|dev|app|co|cn|edu|gov|me|ai|xyz|info)(/\S*)?$"#,
                           options: .regularExpression) != nil {
            return .rejected(.domain)
        }

        if text.hasPrefix("```")
            || text.range(of: #"^(?:let|const|var)\s+[A-Za-z_$]\w*\s*(?::[^=\n]+)?\s*="#,
                          options: .regularExpression) != nil
            || (text.range(of: pluralNotation, options: .regularExpression) == nil
                && text.range(of: #"^[A-Za-z_$][\w$.]*\([^()\n]*\)\s*;?$"#,
                              options: .regularExpression) != nil) {
            return .rejected(.code)
        }

        if isSingleWord(text) {
            let word = normalizeWord(text)
            return word.isEmpty ? .rejected(.noLetters) : .word(word)
        }

        guard containsLatinLetter(text) else { return .rejected(.noLetters) }
        return .sentence(text)
    }

    static func isSingleWord(_ text: String) -> Bool {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 先识别单复数写法，避免右括号被当成首尾标点剥掉
        let unquoted = raw.trimmingCharacters(in: surroundingPunctuation.subtracting(CharacterSet(charactersIn: "()")))
        if unquoted.range(of: pluralNotation, options: .regularExpression) != nil {
            let base = unquoted.replacingOccurrences(of: #"\((?:s|es|ies)\)$"#, with: "", options: .regularExpression)
            return !base.isEmpty && base.unicodeScalars.allSatisfy { wordScalars.contains($0) }
        }

        let core = raw.trimmingCharacters(in: surroundingPunctuation)
        guard !core.isEmpty else { return false }
        return core.unicodeScalars.allSatisfy { wordScalars.contains($0) }
    }

    /// 只做「单词」规范化：小写、去掉所有格、去掉两端标点。
    /// 句子不要走这里。
    static func normalizeWord(_ raw: String) -> String {
        var best = ""
        var current = ""

        func consider(_ candidate: String) {
            if candidate.count > best.count, containsLatinLetter(candidate) { best = candidate }
        }

        for scalar in raw.unicodeScalars {
            if wordScalars.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                consider(current)
                current = ""
            }
        }
        consider(current)

        var word = best.lowercased()
        for suffix in ["'s", "’s"] where word.hasSuffix(suffix) {
            word.removeLast(suffix.count)
        }
        while word.hasPrefix("'") || word.hasPrefix("’") || word.hasPrefix("-") { word.removeFirst() }
        while word.hasSuffix("'") || word.hasSuffix("’") || word.hasSuffix("-") { word.removeLast() }
        return word
    }

    // MARK: - 私有

    private static func containsLatinLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }
    }

    /// 中日韩文字、假名、注音符号：当前只做英译中，遇到就不处理。
    private static func containsUnsupportedScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // 跳过 U+3000...U+303F（CJK 标点区），「」《》等标点不应阻断取词
            (0x2E80...0x2FFF).contains(scalar.value)
                || (0x3040...0x9FFF).contains(scalar.value)
                || (0x3100...0x312F).contains(scalar.value)
                || (0x31A0...0x31BF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }
    }
}
