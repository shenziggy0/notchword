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
    private let apple: any TranslationProviding
    private let onlineProvider: (() -> (any TranslationProviding)?)?

    private var cache: [String: TranslationResult] = [:]
    private var insertionOrder: [String] = []
    private let cacheLimit = 200

    init(preferences: Preferences,
         apple: (any TranslationProviding)? = nil,
         onlineProvider: (() -> (any TranslationProviding)?)? = nil) {
        self.preferences = preferences
        self.apple = apple ?? AppleTranslate()
        self.onlineProvider = onlineProvider
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try Task.checkCancellation()
        let key = cacheKey(request)
        if let hit = cache[key] { return hit }

        let localFailure: Error
        do {
            let result = try await apple.translate(request)
            try Task.checkCancellation()
            remember(result, for: key)
            return result
        } catch {
            if Task.isCancelled || TranslationError.isCancellation(error) { throw TranslationError.cancelled }
            localFailure = error
        }

        guard preferences.onlineEnabled else { throw localFailure }
        try Task.checkCancellation()
        guard let provider = makeOnlineProvider() else { throw TranslationError.configurationMissing }

        let result = try await provider.translate(request)
        try Task.checkCancellation()
        remember(result, for: key)
        return result
    }

    func onlineAvailability() -> OnlineAvailability {
        guard preferences.onlineEnabled else { return .disabled }
        return makeOnlineProvider() == nil ? .missingCredentials : .ready
    }

    /// 密钥缺失或配置非法时，不构造联网服务。
    private func makeOnlineProvider() -> (any TranslationProviding)? {
        if let onlineProvider { return onlineProvider() }
        let trimmed = preferences.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
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
