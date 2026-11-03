import AppKit
import SwiftUI
import Translation

/// Apple Translation 的会话宿主。
///
/// macOS 15/26 的公开 API 差异：`TranslationSession(installedSource:target:)`
/// 需要 macOS 26，而最低目标是 macOS 15。这里用一个 1×1 的离屏窗口承载
/// `.translationTask`，把会话拿回来使用；配置只设置一次，之后由同一个会话
/// 串行处理请求，天然满足「翻译限制并发」。
@MainActor
final class TranslationSessionHost {

    static let shared = TranslationSessionHost()

    private struct Request {
        let text: String
        let continuation: CheckedContinuation<String, Error>
    }

    private final class Model: ObservableObject {
        @Published var configuration: TranslationSession.Configuration?
    }

    private struct HostView: View {
        @ObservedObject var model: Model
        let onSession: (TranslationSession) async -> Void

        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .translationTask(model.configuration) { session in
                    await onSession(session)
                }
        }
    }

    private let model = Model()
    private var window: NSWindow?
    private var stream: AsyncStream<Request>?
    private var feed: AsyncStream<Request>.Continuation?
    private var configuration: TranslationSession.Configuration?

    func translate(_ text: String, source: Locale.Language, target: Locale.Language) async throws -> String {
        ensureWindow()

        let wanted = TranslationSession.Configuration(source: source, target: target)
        if configuration != wanted {
            configuration = wanted
            model.configuration = wanted
        }

        return try await withCheckedThrowingContinuation { continuation in
            guard let feed else {
                continuation.resume(throwing: TranslationError.service("翻译会话未就绪"))
                return
            }
            feed.yield(Request(text: text, continuation: continuation))
        }
    }

    // MARK: - 私有

    private func ensureWindow() {
        if window != nil { return }

        var continuation: AsyncStream<Request>.Continuation?
        let stream = AsyncStream<Request> { continuation = $0 }
        self.stream = stream
        self.feed = continuation

        let view = HostView(model: model) { [weak self] session in
            await self?.serve(session)
        }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.orderFrontRegardless()

        self.window = window
    }

    private func serve(_ session: TranslationSession) async {
        guard let stream else { return }
        for await request in stream {
            do {
                let response = try await session.translate(request.text)
                request.continuation.resume(returning: response.targetText)
            } catch {
                request.continuation.resume(throwing: error)
            }
        }
    }
}
