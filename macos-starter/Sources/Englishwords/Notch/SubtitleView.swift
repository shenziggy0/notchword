import SwiftUI

struct SubtitleView: View {
    @ObservedObject var tracker: SubtitleTracker
    let lookup: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tracker.status).font(.system(size: 12, weight: .medium))
                Spacer()
                Button { tracker.move(by: -1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("上一句")
                    .disabled(tracker.position <= 0)
                Button { tracker.move(by: 1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("下一句")
                    .disabled(tracker.position + 1 >= tracker.cues.count)
            }
            .foregroundStyle(.white.opacity(0.72))
            if let cue = tracker.current {
                Text(linkedWords(cue.text))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "notchword-subtitle",
                              let word = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                                  .queryItems?.first(where: { $0.name == "word" })?.value else {
                            return .discarded
                        }
                        lookup(word)
                        return .handled
                    })
                if !tracker.translation.isEmpty {
                    Text(tracker.translation)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.74))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .buttonStyle(.plain)
    }

    private func linkedWords(_ text: String) -> AttributedString {
        var output = AttributedString()
        for (index, token) in text.split(whereSeparator: \.isWhitespace).enumerated() {
            if index > 0 { output.append(AttributedString(" ")) }
            var value = AttributedString(String(token))
            if TextFilter.isSingleWord(String(token)) {
                let word = TextFilter.normalizeWord(String(token))
                if !word.isEmpty { value.link = Self.link(for: word) }
            }
            output.append(value)
        }
        return output
    }

    /// 用 URLComponents 构造查询串，避免 `don’t`、`café` 被转成 Punycode 主机名。
    private static func link(for word: String) -> URL? {
        var components = URLComponents()
        components.scheme = "notchword-subtitle"
        components.host = "lookup"
        components.queryItems = [URLQueryItem(name: "word", value: word)]
        return components.url
    }
}
