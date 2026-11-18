import Foundation

enum SubtitleAligner {
    static func translation(of sentence: SubtitleCue, in chinese: [SubtitleCue]) -> String? {
        let duration = sentence.end - sentence.start
        guard duration > 0 else { return nil }
        let overlapping = chinese.filter { $0.end > sentence.start && $0.start < sentence.end }
            .sorted { $0.start < $1.start }
        var covered = 0.0
        var rightmost = sentence.start
        var parts: [String] = []
        for cue in overlapping {
            let start = max(rightmost, cue.start, sentence.start)
            let end = min(cue.end, sentence.end)
            if end > start {
                covered += end - start
                rightmost = end
            }
            if !parts.contains(cue.text) { parts.append(cue.text) }
        }
        return covered / duration >= 0.2 && !parts.isEmpty ? parts.joined(separator: " ") : nil
    }
}
