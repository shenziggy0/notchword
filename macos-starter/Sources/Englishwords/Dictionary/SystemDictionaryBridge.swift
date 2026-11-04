import CoreServices
import Foundation

protocol SystemDictionaryLooking {
    func lookup(_ word: String) -> Entry?
}

/// macOS Dictionary Services 桥。
///
/// 只做「单词 → 系统词典释义」这一步，不负责降级决策。
/// 系统词典不可用或没装对应词典时返回 nil，调用方继续走翻译。
struct SystemDictionaryBridge: SystemDictionaryLooking {

    func lookup(_ word: String) -> Entry? {
        let length = (word as NSString).length
        guard length > 0,
              let raw = DCSCopyTextDefinition(nil, word as CFString, CFRange(location: 0, length: length))
        else { return nil }

        let text = raw.takeRetainedValue() as String
        let cleaned = Self.clean(text, headword: word)
        guard !cleaned.isEmpty else { return nil }

        return Entry(word: word, translation: cleaned, dictionary: "系统词典")
    }

    /// 系统词典返回的第一行通常就是词头本身，去掉它以免面板重复标题。
    static func clean(_ text: String, headword: String) -> String {
        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        if let first = lines.first,
           first.compare(headword, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            lines.removeFirst()
        }

        let joined = lines
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return String(joined.prefix(2000))
    }
}
