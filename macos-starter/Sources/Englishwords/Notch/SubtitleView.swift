import SwiftUI

struct SubtitleViewport: View {
    @ObservedObject var tracker: SubtitleTracker
    let subtitle: SubtitleView
    let width: CGFloat
    let topInset: CGFloat
    let maxHeight: CGFloat?
    let onHeightChanged: (CGFloat) -> Void

    var body: some View {
        ScrollViewReader { scroll in
            NotchViewport(width: width, topInset: topInset, maxHeight: maxHeight) {
                subtitle.fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: onHeightChanged)
                    .id("subtitle-top")
            }
            .onChange(of: tracker.currentCueID) {
                scroll.scrollTo("subtitle-top", anchor: .top)
            }
        }
    }
}

struct SubtitleView: View {
    @ObservedObject var tracker: SubtitleTracker
    var onDismiss: (() -> Void)? = nil
    let lookup: (String, LookupContext) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var cueSize: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var translationSize: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "captions.bubble.fill")
                    .foregroundStyle(Lexicon.onDarkAccent).accessibilityHidden(true)
                Text("视频字幕").font(.headline).accessibilityAddTraits(.isHeader)
                if tracker.current != nil {
                    Text("\(tracker.position + 1) / \(tracker.cues.count)")
                        .monospacedDigit().font(.callout).foregroundStyle(Lexicon.notchSecondary)
                }
                Spacer()
                Button { tracker.move(by: -1) } label: { LexiconIcon(.previous, size: 16) }
                    .accessibilityLabel("上一句").help("上一句")
                    .disabled(tracker.position <= 0)
                Button { tracker.move(by: 1) } label: { LexiconIcon(.next, size: 16) }
                    .accessibilityLabel("下一句").help("下一句")
                    .disabled(tracker.position + 1 >= tracker.cues.count)
                if tracker.canReplay {
                    Button { tracker.replayCurrent() } label: {
                        Image(systemName: "gobackward").font(.system(size: 15))
                    }.accessibilityLabel("重听这句").help("重听这句")
                        .disabled(tracker.replayActive)
                }
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    }
                    .accessibilityLabel("收起字幕").help("收起字幕（Esc）")
                }
            }
            .buttonStyle(LexiconIconButtonStyle())
            if let cue = tracker.current {
                VStack(alignment: .leading, spacing: 10) {
                    Text(linkedWords(cue.text))
                        .font(.system(size: cueSize, weight: .semibold))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .environment(\.openURL, OpenURLAction { url in
                            guard url.scheme == "notchword-subtitle",
                                  let offset = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                                      .queryItems?.first(where: { $0.name == "offset" })?.value.flatMap(Int.init),
                                  let length = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                                      .queryItems?.first(where: { $0.name == "length" })?.value.flatMap(Int.init)
                            else {
                                return .discarded
                            }
                            let context = LookupContext(sentence: cue.text, range: NSRange(location: offset, length: length),
                                                        video: tracker.videoBookmark)
                            guard let word = context.selected else { return .discarded }
                            lookup(word, context)
                            return .handled
                        })
                    if !tracker.translation.isEmpty {
                        Text(tracker.translation).font(.system(size: translationSize))
                            .lineSpacing(3).foregroundStyle(Lexicon.notchSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: tracker.position)
            }
            Text(tracker.status)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Lexicon.notchMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 18)
        .foregroundStyle(Lexicon.notchText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func linkedWords(_ text: String) -> AttributedString {
        var output = AttributedString()
        var cursor = text.startIndex
        for token in text.split(whereSeparator: \.isWhitespace) {
            output.append(AttributedString(String(text[cursor..<token.startIndex])))
            cursor = token.endIndex
            var value = AttributedString(String(token))
            if TextFilter.isSingleWord(String(token)) {
                let word = TextFilter.normalizeWord(String(token))
                if !word.isEmpty {
                    value.link = Self.link(for: NSRange(token.startIndex..<token.endIndex, in: text))
                }
            }
            output.append(value)
        }
        output.append(AttributedString(String(text[cursor...])))
        return output
    }

    /// 用 URLComponents 构造查询串，避免 `don’t`、`café` 被转成 Punycode 主机名。
    private static func link(for range: NSRange) -> URL? {
        var components = URLComponents()
        components.scheme = "notchword-subtitle"
        components.host = "lookup"
        components.queryItems = [URLQueryItem(name: "offset", value: String(range.location)),
                                 URLQueryItem(name: "length", value: String(range.length))]
        return components.url
    }
}
