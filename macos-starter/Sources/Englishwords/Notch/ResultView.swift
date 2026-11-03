import AppKit
import AVFoundation
import SwiftUI

/// 朗读：由稳定生命周期对象持有，按实际完成回调更新状态。
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {

    static let shared = Speaker()

    @Published fileprivate(set) var speaking = false

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        if speaking {
            synthesizer.stopSpeaking(at: .immediate)
            speaking = false
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.48
        synthesizer.speak(utterance)
        speaking = true
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speaking = false }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speaking = false }
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
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.8))
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

                Button {
                    speaker.speak(result.title.isEmpty ? result.input : result.title)
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(speaker.speaking ? 1 : 0.7))
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.white.opacity(speaker.speaking ? 0.14 : 0))
                        )
                }
                .buttonStyle(.plain)
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

            HStack(spacing: 6) {
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
            Text("⌥D 查词 · Esc 收起")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.28))
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
            Text("⌥D 查词 · Esc 收起")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.25))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
