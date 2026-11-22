import Foundation

struct SubtitleCue: Codable, Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

enum SentenceMerger {
    static func merge(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        var result: [SubtitleCue] = []
        var current: SubtitleCue?
        var count = 0
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let previous = current {
                let endsSentence = previous.text.last.map { ".!?。！？".contains($0) } ?? false
                if cue.start - previous.end > 1 || count >= 3 || endsSentence || text.hasPrefix(">>") {
                    result.append(previous)
                } else {
                    current = SubtitleCue(text: join(previous.text, text), start: previous.start,
                                          end: max(previous.end, cue.end))
                    count += 1
                    continue
                }
            }
            current = SubtitleCue(text: text, start: cue.start, end: cue.end)
            count = 1
        }
        if let current { result.append(current) }
        return Array(result.suffix(80))
    }

    private static func join(_ left: String, _ right: String) -> String {
        let a = left.split(separator: " ")
        let b = right.split(separator: " ")
        if !a.isEmpty, !b.isEmpty {
            for count in stride(from: min(a.count, b.count), through: 1, by: -1) {
                // 比对时去首尾标点并忽略大小写，但拼接仍用原文
                let tail = a.suffix(count).map(Self.comparable)
                let head = b.prefix(count).map(Self.comparable)
                if tail == head {
                    return (a + b.dropFirst(count)).joined(separator: " ")
                }
            }
        }
        return left + " " + right
    }

    private static func comparable(_ word: Substring) -> String {
        var value = word.lowercased()
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        while let first = value.unicodeScalars.first, punctuation.contains(first) {
            value.removeFirst()
        }
        while let last = value.unicodeScalars.last, punctuation.contains(last) {
            value.removeLast()
        }
        return value
    }
}
