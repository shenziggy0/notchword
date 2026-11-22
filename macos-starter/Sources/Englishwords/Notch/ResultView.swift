import AppKit
import AVFoundation
import SwiftUI

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

/// 刘海结果面板。
///
/// - 顶部贴屏幕边缘；内容按刘海高度让位
/// - 黑底，保证任何壁纸下都可读
/// - 紧凑态只给「词 + 第一个意思」，展开态给完整释义与词根词缀
struct ResultView: View {

    let state: LookupState
    let mode: PanelController.Mode
    let topInset: CGFloat
    let width: CGFloat
    let maxHeight: CGFloat?
    var showWordParts: Bool = true
    let lookupShortcut: String
    var notebook: NotebookModel? = nil
    var onBackToSubtitle: (() -> Void)? = nil
    var speechVoice = ""
    var speechRate = 0.48
    /// 离屏预览没有事件循环，用静态进度环代替 `ProgressView`。
    var isStaticPreview: Bool = false

    @ObservedObject private var speaker = Speaker.shared

    var body: some View {
        Group {
            if let maxHeight {
                ScrollView(.vertical) { content }
                    .frame(width: width, height: maxHeight)
            } else {
                content
            }
        }
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 22,
            bottomTrailingRadius: 22,
            topTrailingRadius: 0
        ))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 0.5)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onBackToSubtitle {
                Button("返回字幕", action: onBackToSubtitle)
                    .buttonStyle(.link)
                    .padding(.bottom, 6)
            }
            if mode == .compact {
                compactRow
            } else {
                expandedContent
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, topInset + 8)
        .padding(.bottom, 12)
        .frame(width: width, alignment: .leading)
    }

    // MARK: - 紧凑态

    private var compactRow: some View {
        HStack(spacing: 8) {
            Text(compactTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if !compactSubtitle.isEmpty {
                Text(compactSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 26)
    }

    private var compactTitle: String {
        switch state {
        case .loading:
            return "查询中…"
        case .result(_, let result):
            return result.kind == .sentence ? "翻译" : (result.title.isEmpty ? result.input : result.title)
        case .miss:
            return "未收录"
        case .failure:
            return "查询失败"
        }
    }

    private var compactSubtitle: String {
        switch state {
        case .loading(let request):
            return request.text
        case .result(_, let result):
            return firstLine(result.body)
        case .miss(let request):
            return request.text
        case .failure(_, let message):
            return firstLine(message)
        }
    }

    // MARK: - 展开态

    @ViewBuilder
    private var expandedContent: some View {
        switch state {
        case .loading(let request):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    loadingIndicator
                    Text("正在查询")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Text(request.text)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .result(_, let result):
            resultContent(result)

        case .miss(let request):
            notice(title: "未收录",
                   message: "词典里没有「\(request.text)」。\n选中一句话再试，可以直接翻译。",
                   accent: .orange)

        case .failure(_, let message):
            notice(title: "没能完成查询", message: message, accent: .red)
        }
    }

    private func resultContent(_ result: LookupResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if result.kind == .sentence {
                Text(result.originalText ?? result.input)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)

                Text(result.body)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                header(result)

                if !result.tags.isEmpty {
                    tags(result.tags)
                }

                Text(result.body)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)

                if showWordParts, !result.segments.isEmpty {
                    morphology(result)
                }
            }

            if let note = result.note {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange.opacity(0.75))
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer(result.source)
        }
    }

    private func header(_ result: LookupResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(result.title.isEmpty ? result.input : result.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                if !result.phonetic.isEmpty {
                    Text(Self.displayPhonetic(result.phonetic))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                }

                if !result.pos.isEmpty {
                    Text(result.pos)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.38))
                }

                Spacer(minLength: 6)
                if let notebook, let word = result.notebookWord {
                    NotebookStar(model: notebook, word: word)
                }

                Button {
                    speaker.speak(result.title.isEmpty ? result.input : result.title, voiceID: speechVoice, rate: speechRate)
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(speaker.speaking ? 1 : 0.7))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.white.opacity(speaker.speaking ? 0.14 : 0))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(speaker.speaking ? "停止朗读" : "朗读单词")
            }

            if !result.input.isEmpty, result.input != result.title.lowercased() {
                Text("查询 \(result.input)")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private func tags(_ tags: [String]) -> some View {
        HStack(spacing: 5) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.orange.opacity(0.95))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.orange.opacity(0.13))
                    )
            }
        }
        .padding(.top, 7)
    }

    private func morphology(_ result: LookupResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("词根词缀")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.38))
                Text("\(result.segments.count) 段")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
                Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5)
                Text("→ \(state.request.trigger.label)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green.opacity(0.85))
            }

            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(Array(result.segments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Text("+")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.28))
                    }
                    SegmentChip(seg: segment)
                }
            }

            if !result.origin.isEmpty {
                Text("词源：\(result.origin)")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5)
        }
    }

    private func footer(_ source: String) -> some View {
        HStack(spacing: 6) {
            Text(source)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.blue.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.blue.opacity(0.15))
                )
            Spacer()
            Text("\(lookupShortcut) 查词 · Esc 收起")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.56))
        }
        .padding(.top, 10)
    }

    private func notice(title: String, message: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(accent.opacity(0.85)).frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(lookupShortcut) 查词 · Esc 收起")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.56))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var loadingIndicator: some View {
        if isStaticPreview {
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 14, height: 14)
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.8))
        }
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

/// 按可用宽度折行排布词素片段与分隔的 "+"。
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
            let size = subview.sizeThatFits(.unspecified)
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
            let size = subview.sizeThatFits(.unspecified)
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
}

struct SegmentChip: View {
    let seg: Segment

    private var tint: Color {
        switch seg.role {
        case "prefix": return .orange
        case "suffix": return .purple
        default:       return .cyan
        }
    }

    private var roleName: String {
        switch seg.role {
        case "prefix": return "前缀"
        case "suffix": return "后缀"
        default:       return "词根"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(seg.label)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(seg.gloss)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
            Text(roleName)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(tint.opacity(0.9))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.3), lineWidth: 0.5)
        )
    }
}
