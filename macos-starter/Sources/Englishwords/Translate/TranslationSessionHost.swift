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
        let id: UUID
        let text: String
        let continuation: CheckedContinuation<String, Error>
    }

    private final class Model: ObservableObject {
        @Published var configuration: TranslationSession.Configuration?
    }

    private struct HostView: View {
        @ObservedObject var model: Model
        let onSession: (TranslationSession, TranslationSession.Configuration?) async -> Void

        var body: some View {
            let configuration = model.configuration
            Color.clear
                .frame(width: 1, height: 1)
                .translationTask(configuration) { session in
                    await onSession(session, configuration)
                }
        }
    }

    private let model = Model()
    private var window: NSWindow?
    private var stream: AsyncStream<Void>?
    private var feed: AsyncStream<Void>.Continuation?
    private var configuration: TranslationSession.Configuration?
    private var pending: Request?
    private var activeID: UUID?
    private var activeContinuation: CheckedContinuation<String, Error>?
    private var activeTask: Task<String, Error>?

    func translate(_ text: String, source: Locale.Language, target: Locale.Language) async throws -> String {
        ensureWindow()

        let wanted = TranslationSession.Configuration(source: source, target: target)
        if configuration != wanted {
            if let pending { cancel(pending.id) }
            if let activeID { cancel(activeID) }
            feed?.finish()
            let (stream, feed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            self.stream = stream
            self.feed = feed
            configuration = wanted
            model.configuration = wanted
        }

        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: TranslationError.cancelled)
                    return
                }
                pending?.continuation.resume(throwing: TranslationError.cancelled)
                pending = Request(id: id, text: text, continuation: continuation)
                feed?.yield(())
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        if let request = pending, request.id == id {
            pending = nil
            request.continuation.resume(throwing: TranslationError.cancelled)
        }
        if activeID == id {
            let continuation = activeContinuation
            activeContinuation = nil
            activeTask?.cancel()
            continuation?.resume(throwing: TranslationError.cancelled)
        }
    }

    // MARK: - 私有

    private func ensureWindow() {
        if window != nil { return }

        let view = HostView(model: model) { [weak self] session, configuration in
            await self?.serve(session, configuration: configuration)
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

    private func serve(_ session: TranslationSession, configuration: TranslationSession.Configuration?) async {
        guard let stream, !Task.isCancelled, self.configuration == configuration else { return }
        for await _ in stream {
            guard !Task.isCancelled, self.configuration == configuration else { break }
            // 旧会话的框架调用可能还未释放，完成后会唤醒新会话。
            guard activeID == nil, let request = pending else { continue }
            pending = nil
            activeID = request.id
            activeContinuation = request.continuation
            let task = Task { try await session.translate(request.text).targetText }
            activeTask = task
            let result = await withTaskCancellationHandler {
                await task.result
            } onCancel: {
                task.cancel()
            }

            let continuation = activeContinuation
            activeID = nil
            activeContinuation = nil
            activeTask = nil
            continuation?.resume(with: result)
            if pending != nil { feed?.yield(()) }
            if Task.isCancelled { break }
        }
    }
}
