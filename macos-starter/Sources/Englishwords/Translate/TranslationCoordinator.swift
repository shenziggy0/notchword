import Foundation

/// 翻译编排：本地优先，联网可选降级；带内存缓存与并发上限。
@MainActor
final class TranslationCoordinator: Translating {

    enum OnlineAvailability {
        case disabled
        case missingCredentials
        case ready
    }

    private let preferences: Preferences
    private let apple = AppleTranslate()

    private var cache: [String: TranslationResult] = [:]
    private var insertionOrder: [String] = []
    private let cacheLimit = 200

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let key = cacheKey(request)
        if let hit = cache[key] { return hit }

        let localFailure: Error
        do {
            let result = try await apple.translate(request)
            remember(result, for: key)
            return result
        } catch let error as TranslationError {
            if case .cancelled = error { throw error }
            localFailure = error
        }

        guard preferences.onlineEnabled else { throw localFailure }
        guard let provider = makeOnlineProvider() else { throw localFailure }

        let result = try await provider.translate(request)
        remember(result, for: key)
        return result
    }

    func onlineAvailability() -> OnlineAvailability {
        guard preferences.onlineEnabled else { return .disabled }
        return makeOnlineProvider() == nil ? .missingCredentials : .ready
    }

    /// 密钥缺失或地址非法时返回 nil，调用方保留本地失败原因。
    private func makeOnlineProvider() -> OpenAICompatProvider? {
        let trimmed = preferences.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else { return nil }
        let model = preferences.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        guard let key = SecretStore.read(account: OpenAICompatProvider.account), !key.isEmpty else { return nil }
        return OpenAICompatProvider(baseURL: url, model: model, apiKey: key)
    }

    private func cacheKey(_ request: TranslationRequest) -> String {
        let signature = preferences.onlineEnabled
            ? "\(preferences.baseURL)|\(preferences.model)"
            : "offline"
        return "\(request.text)|\(request.source ?? "auto")|\(request.target)|\(signature)"
    }

    private func remember(_ result: TranslationResult, for key: String) {
        if cache[key] == nil { insertionOrder.append(key) }
        cache[key] = result
        while insertionOrder.count > cacheLimit {
            let oldest = insertionOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}

extension OpenAICompatProvider {
    /// 钥匙串 account。现有自定义服务迁到 `custom`，与预设 id 对齐。
    static let account = "custom"
}
