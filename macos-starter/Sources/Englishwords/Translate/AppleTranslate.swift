import Foundation
import Translation

/// Apple 本地翻译。
///
/// 只用已安装的语言包，不在后台触发系统下载；需要语言包时抛出
/// `.languagePackRequired`，由用户主动打开「准备语言包」窗口完成下载。
struct AppleTranslate: TranslationProviding {

    let id = "apple"
    let displayName = "Apple 本地翻译"

    func availability(source: Locale.Language, target: Locale.Language) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: source, to: target)
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranslationError.emptyText }

        let source = Locale.Language(identifier: request.source ?? "en")
        let target = Locale.Language(identifier: request.target)

        let translated = try await withTimeout(20) {
            switch await availability(source: source, target: target) {
            case .installed:
                try Task.checkCancellation()
            case .supported:
                throw TranslationError.languagePackRequired
            default:
                throw TranslationError.languageUnavailable
            }
            return try await TranslationSessionHost.shared.translate(text, source: source, target: target)
        }
        let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationError.service("本地翻译返回空结果") }
        return TranslationResult(text: trimmed, providerID: id, providerName: displayName)
    }
}
