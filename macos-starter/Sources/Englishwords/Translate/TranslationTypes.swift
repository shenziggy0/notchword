import Foundation

struct TranslationRequest {
    let text: String
    let source: String?     // nil = 自动检测
    let target: String      // "zh-Hans"
}

struct TranslationResult {
    let text: String
    let providerID: String
    let providerName: String
}

enum TranslationError: LocalizedError {
    case emptyText
    case languageUnavailable
    case languagePackRequired
    case configurationMissing
    case timedOut
    case service(String)
    case cancelled

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        if let error = error as? TranslationError, case .cancelled = error { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .emptyText:             return "没有可翻译的内容。"
        case .languageUnavailable:   return "这台 Mac 不支持英译中本地翻译。"
        case .languagePackRequired:  return "需要先下载语言包：设置 → 翻译 → 准备语言包。"
        case .configurationMissing:  return "联网翻译未配置完整的服务地址、模型或密钥。"
        case .timedOut:              return "翻译超时，请稍后重试。"
        case .service(let detail):   return "翻译服务失败：\(detail)"
        case .cancelled:             return "翻译已取消。"
        }
    }
}

/// 编排层用的翻译入口。测试可以换成固定译文，避免这条用例依赖语言包。
@MainActor
protocol Translating {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult
}

@MainActor
protocol TranslationProviding {
    var id: String { get }
    var displayName: String { get }
    func translate(_ request: TranslationRequest) async throws -> TranslationResult
}

/// 调用者可以先于暂不响应取消的框架任务返回。退出后丢弃晚到结果。
@MainActor
func withTimeout<T>(_ seconds: Double, _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
    let (stream, continuation) = AsyncStream<Result<T, Error>>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let work = Task {
        do {
            continuation.yield(.success(try await operation()))
        } catch {
            continuation.yield(.failure(error))
        }
    }
    let timer = Task {
        do {
            try await Task.sleep(for: .seconds(seconds))
            continuation.yield(.failure(TranslationError.timedOut))
        } catch {
            // 任务已完成或调用者已取消。
        }
    }
    defer {
        continuation.finish()
        work.cancel()
        timer.cancel()
    }

    var iterator = stream.makeAsyncIterator()
    guard let result = await iterator.next(), !Task.isCancelled else {
        throw TranslationError.cancelled
    }
    return try result.get()
}
