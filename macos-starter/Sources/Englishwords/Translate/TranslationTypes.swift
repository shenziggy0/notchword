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

/// 超时竞速的结果。超时任务被取消时不会伪装成超时。
private enum TimeoutOutcome<T> {
    case value(T)
    case timeout
}

/// 给翻译服务加超时。
func withTimeout<T>(_ seconds: Double, _ operation: @escaping () async throws -> T) async throws -> T {
    let outcome = try await withThrowingTaskGroup(of: TimeoutOutcome<T>.self) { group -> TimeoutOutcome<T> in
        group.addTask { .value(try await operation()) }
        group.addTask {
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                return .timeout
            }
            return .timeout
        }
        guard let first = try await group.next() else {
            throw TranslationError.service("没有返回结果")
        }
        group.cancelAll()
        return first
    }

    switch outcome {
    case .value(let value): return value
    case .timeout: throw TranslationError.timedOut
    }
}
