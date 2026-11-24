import AppKit
import AVFoundation
import SwiftUI

// Command Line Tools 不带 SwiftUI 宏插件，直接引用 State 属性包装器。
private typealias ResultViewState<Value> = State<Value>

/// 朗读：由稳定生命周期对象持有，按实际完成回调更新状态。
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {

    static let shared = Speaker()

    @Published fileprivate(set) var speaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, voiceID: String = "", rate: Double = 0.48) {
        guard !text.isEmpty else { return }
        if speaking {
            currentUtterance = nil
            synthesizer.stopSpeaking(at: .immediate)
            speaking = false
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID) ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = Float(min(0.65, max(0.15, rate)))
        currentUtterance = utterance
        synthesizer.speak(utterance)
        speaking = true
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(utterance)
    }

    /// 只有当前那次朗读结束才重置状态，避免旧的回调把新朗读的图标误置为停止。
    private func finish(_ utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard utterance === self.currentUtterance else { return }
            self.currentUtterance = nil
            self.speaking = false
        }
    }
}

/// 顶部留出摄像头空间。长释义只滚动下方文字，内容始终与屏幕边缘对齐。
struct NotchViewport<Content: View>: View {
    let width: CGFloat
    let topInset: CGFloat
    var maxHeight: CGFloat?
    var compact = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset).accessibilityHidden(true)
            if let maxHeight {
                ScrollView { content().frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: max(0, maxHeight - topInset))
            } else {
                content()
            }
        }
        .frame(width: width, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .notchSurface(compact: compact)
    }
}

struct ResultView: View {
    let state: LookupState
    let mode: PanelController.Mode
    let topInset: CGFloat
    let width: CGFloat
    let maxHeight: CGFloat?
    var showWordParts = true
    let lookupShortcut: String
    var notebook: NotebookModel? = nil
    var onBackToSubtitle: (() -> Void)? = nil
    var onExpand: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    var onAccessibilityFocusChanged: ((Bool) -> Void)? = nil
    var speechVoice = ""
    var speechRate = 0.48
    var isStaticPreview = false

    @ObservedObject private var speaker = Speaker.shared
    @AccessibilityFocusState(for: .voiceOver) private var accessibilityFocus: Focus?
    @ResultViewState private var focusHeadingOnExpand = false
    @ScaledMetric(relativeTo: .largeTitle) private var headwordSize: CGFloat = 35
    @ScaledMetric(relativeTo: .body) private var definitionSize: CGFloat = 16
    @ScaledMetric(relativeTo: .title2) private var translationSize: CGFloat = 21

    private enum Focus: Hashable {
        case expand, back, heading, source, trigger, original, definition, note, speech, favorite, phonetic, input
        case tag(String), morphology, segment(Int), origin, shortcut, dismiss
    }

    var body: some View {
        NotchViewport(width: width, topInset: topInset, maxHeight: maxHeight, compact: mode == .compact) {
            if mode == .compact {
                compactContent
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if let onBackToSubtitle {
                        Button(action: onBackToSubtitle) {
                            Label("返回字幕", systemImage: "chevron.backward").font(.callout.weight(.medium))
                                .padding(.horizontal, 12).frame(minHeight: 32)
                        }
                        .buttonStyle(.plain)
                        .lexiconGlass(in: Capsule(), interactive: true)
                        .accessibilityFocused($accessibilityFocus, equals: .back)
                        .padding(.bottom, 10)
                    }
                    expandedContent
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: mode) {
            if mode == .expanded, focusHeadingOnExpand {
                focusHeadingOnExpand = false
                accessibilityFocus = .heading
            }
        }
        .onChange(of: accessibilityFocus != nil) { _, inside in
            onAccessibilityFocusChanged?(inside)
        }
    }

    private var compactContent: some View {
        HStack(spacing: 4) {
            if let onExpand {
                Button {
                    focusHeadingOnExpand = accessibilityFocus == .expand
                    onExpand()
                } label: {
                    compactRow
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(compactTitle)，\(compactSubtitle)")
                .accessibilityHint("展开查词结果")
                .accessibilityFocused($accessibilityFocus, equals: .expand)
            } else {
                compactRow
            }
            if let onBackToSubtitle {
                Button(action: onBackToSubtitle) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(LexiconIconButtonStyle())
                .accessibilityLabel("返回字幕")
                .accessibilityFocused($accessibilityFocus, equals: .back)
                .help("返回字幕")
                .padding(.trailing, 8)
            }
        }
    }

    private var compactRow: some View {
        HStack(spacing: 9) {
            Image(systemName: stateSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Lexicon.onDarkAccent)
                .frame(width: 29, height: 29)
                .background(Lexicon.onDarkAccent.opacity(0.13), in: Circle())
            Text(compactTitle)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Lexicon.notchText)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            if !compactSubtitle.isEmpty {
                Text(compactSubtitle)
                    .font(.system(size: 12)).foregroundStyle(Lexicon.notchSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold)).foregroundStyle(Lexicon.notchMuted)
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 46)
        .contentShape(Rectangle())
    }

    private var stateSymbol: String {
        switch state {
        case .loading: "magnifyingglass"
        case .result(_, let result): result.kind == .sentence ? "translate" : "book.closed.fill"
        case .miss: "text.magnifyingglass"
        case .failure: "exclamationmark.circle"
        }
    }

    private var compactTitle: String {
        switch state {
        case .loading: return "查询中…"
        case .result(_, let result):
            return result.kind == .sentence ? "翻译" : (result.title.isEmpty ? result.input : result.title)
        case .miss: return "未收录"
        case .failure: return "查询失败"
        }
    }

    private var compactSubtitle: String {
        switch state {
        case .loading(let request), .miss(let request): return request.text
        case .result(_, let result): return firstLine(result.body)
        case .failure(_, let message): return firstLine(message)
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        switch state {
        case .loading(let request):
            status(title: "正在查询", message: request.text)
        case .result(_, let result):
            sourceLine(result.source, isSentence: result.kind == .sentence)
            if result.kind == .sentence {
                Text(result.originalText ?? result.input)
                    .font(.system(size: definitionSize)).foregroundStyle(Lexicon.notchSecondary)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    .accessibilityFocused($accessibilityFocus, equals: .original)
                Text(result.body)
                    .font(.system(size: translationSize, weight: .medium)).foregroundStyle(Lexicon.notchText)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                    .accessibilityFocused($accessibilityFocus, equals: .definition)
            } else {
                header(result)
                Text(result.body)
                    .font(.system(size: definitionSize)).foregroundStyle(Lexicon.notchText)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                    .accessibilityFocused($accessibilityFocus, equals: .definition)
                if showWordParts, !result.segments.isEmpty { morphology(result) }
            }
            if let note = result.note {
                Text(note).font(.callout).foregroundStyle(Lexicon.onDarkAccent)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                    .accessibilityFocused($accessibilityFocus, equals: .note)
            }
            footer
        case .miss(let request):
            status(title: "未收录", message: "词典里没有「\(request.text)」。选中一句话可以直接翻译。")
        case .failure(_, let message):
            status(title: "没能完成查询", message: message)
        }
    }

    private func sourceLine(_ name: String, isSentence: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: stateSymbol).accessibilityHidden(true)
            Text(name)
                .accessibilityFocused($accessibilityFocus, equals: isSentence ? .heading : .source)
            Spacer(minLength: 8)
            Text(state.request.trigger.label).foregroundStyle(Lexicon.notchMuted)
                .accessibilityFocused($accessibilityFocus, equals: .trigger)
        }
        .font(.system(size: 12, weight: .medium)).foregroundStyle(Lexicon.onDarkAccent)
        .padding(.bottom, 13)
    }

    private func header(_ result: LookupResult) -> some View {
        let title = result.title.isEmpty ? result.input : result.title
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(.system(size: headwordSize, weight: .bold)).tracking(-1.1)
                    .foregroundStyle(Lexicon.notchText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($accessibilityFocus, equals: .heading)
                Button {
                    speaker.speak(title, voiceID: speechVoice, rate: speechRate)
                } label: {
                    LexiconIcon(speaker.speaking ? .stop : .volume, size: 17)
                }
                .buttonStyle(LexiconIconButtonStyle(active: speaker.speaking))
                .help(speaker.speaking ? "停止朗读" : "朗读单词")
                .accessibilityLabel(speaker.speaking ? "停止朗读" : "朗读单词")
                .accessibilityFocused($accessibilityFocus, equals: .speech)
                if let notebook, let word = result.notebookWord {
                    NotebookStar(model: notebook, word: word)
                        .accessibilityFocused($accessibilityFocus, equals: .favorite)
                }
            }
            if !result.phonetic.isEmpty || !result.pos.isEmpty {
                Text([Self.displayPhonetic(result.phonetic), result.pos].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(.system(size: 14)).foregroundStyle(Lexicon.notchSecondary)
                    .accessibilityFocused($accessibilityFocus, equals: .phonetic)
            }
            if !result.input.isEmpty, result.input != title.lowercased() {
                Text("查询 \(result.input)").font(.callout).foregroundStyle(Lexicon.notchSecondary)
                    .accessibilityFocused($accessibilityFocus, equals: .input)
            }
            if !result.tags.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 5) {
                    ForEach(result.tags, id: \.self) { tag in
                        Text(tag).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Lexicon.onDarkAccent)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Lexicon.onDarkAccent.opacity(0.13), in: Capsule())
                            .accessibilityFocused($accessibilityFocus, equals: .tag(tag))
                    }
                }
            }
        }
    }

    private func morphology(_ result: LookupResult) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Text("词根词缀").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                Text("\(result.segments.count) 段").foregroundStyle(Lexicon.notchMuted)
            }
            .font(.system(size: 12)).foregroundStyle(Lexicon.notchText)
            .accessibilityElement(children: .combine)
            .accessibilityFocused($accessibilityFocus, equals: .morphology)
            FlowLayout(spacing: 7, lineSpacing: 7) {
                ForEach(Array(result.segments.enumerated()), id: \.offset) { index, segment in
                    SegmentChip(seg: segment)
                        .accessibilityFocused($accessibilityFocus, equals: .segment(index))
                }
            }
            if !result.origin.isEmpty {
                Text(result.origin).font(.callout).foregroundStyle(Lexicon.notchSecondary)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("词源，\(result.origin)")
                    .accessibilityFocused($accessibilityFocus, equals: .origin)
            }
        }
        .padding(.top, 16)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            HStack(spacing: 7) {
                Text(lookupShortcut).font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
                Text("查词")
            }
            .accessibilityElement(children: .combine)
            .accessibilityFocused($accessibilityFocus, equals: .shortcut)
            Spacer()
            if let onDismiss {
                Button(action: onDismiss) {
                    HStack(spacing: 5) {
                        Text("Esc").fontWeight(.semibold)
                        Text("收起")
                    }.padding(.horizontal, 12).frame(minHeight: 30)
                }
                .buttonStyle(.plain)
                .lexiconGlass(in: Capsule(), interactive: true)
                .accessibilityLabel("收起面板")
                .accessibilityFocused($accessibilityFocus, equals: .dismiss)
            } else {
                Text("Esc  收起")
            }
        }
        .font(.system(size: 12)).foregroundStyle(Lexicon.notchSecondary)
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }
        .padding(.top, 15)
    }

    private func status(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                if case .loading = state, !isStaticPreview {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                } else {
                    Image(systemName: stateSymbol).foregroundStyle(Lexicon.onDarkAccent).accessibilityHidden(true)
                }
                Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($accessibilityFocus, equals: .heading)
            }
            Text(message).font(.body).foregroundStyle(Lexicon.notchSecondary)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true).padding(.top, 9)
                .accessibilityFocused($accessibilityFocus, equals: .definition)
            footer
        }
        .foregroundStyle(Lexicon.notchText)
    }

    /// ECDICT 的音标不带斜杠，展示时补上，保持词典排版习惯。
    private static func displayPhonetic(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("[") { return trimmed }
        return "/\(trimmed)/"
    }

    private func firstLine(_ text: String) -> String {
        text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
    }
}

// MARK: - 语素片段

/// 标签按自然宽度换行，单个超长释义可以占满一行并继续向下换行。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = measured(subview, limit: maxWidth)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width
            widest = max(widest, x)
            lineHeight = max(lineHeight, size.height)
            x += spacing
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = measured(subview, limit: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }

    private func measured(_ subview: LayoutSubview, limit: CGFloat) -> CGSize {
        let natural = subview.sizeThatFits(.unspecified)
        guard natural.width > limit else { return natural }
        return subview.sizeThatFits(ProposedViewSize(width: limit, height: nil))
    }
}

struct SegmentChip: View {
    let seg: Segment

    private var role: (name: String, tint: Color) {
        switch seg.role {
        case "prefix": ("前缀", Lexicon.onDarkAccent)
        case "suffix": ("后缀", Color(red: 0.80, green: 0.74, blue: 1))
        default:       ("词根", Color(red: 0.59, green: 0.86, blue: 0.82))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(seg.label).font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(role.name).font(.system(size: 11, weight: .medium)).foregroundStyle(role.tint)
            }
            Text(seg.gloss).font(.system(size: 12)).foregroundStyle(Lexicon.notchSecondary)
        }
        .foregroundStyle(Lexicon.notchText)
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(role.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .combine)
    }
}
