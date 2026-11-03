import AppKit

/// 查询编排。所有入口（热键、菜单、剪贴板、悬停、划词）都提交到这里。
///
/// 单词顺序：内置词库 → 系统词典 → 翻译；短句直接翻译。
/// 每次提交带递增标识，只有最新请求可以更新 UI。
@MainActor
final class LookupCoordinator {

    private let store: DictionaryStore
    private let systemDictionary: SystemDictionaryBridge
    private let translator: TranslationCoordinator
    private let preferences: Preferences

    var onState: ((LookupState) -> Void)?

    private var generation = 0
    private var task: Task<Void, Never>?

    init(store: DictionaryStore,
         systemDictionary: SystemDictionaryBridge,
         translator: TranslationCoordinator,
         preferences: Preferences) {
        self.store = store
        self.systemDictionary = systemDictionary
        self.translator = translator
        self.preferences = preferences
    }

    func submit(_ request: LookupRequest) {
        task?.cancel()
        task = nil
        generation &+= 1
        let currentGeneration = generation

        let classification = TextFilter.classify(request.text)
        if case .rejected(let reason) = classification {
            // 被动入口失败不打扰用户
            guard !request.trigger.isPassive else { return }
            let message = request.note.map { reason.message + "\n" + $0 } ?? reason.message
            onState?(.failure(request, message))
            return
        }

        onState?(.loading(request))

        task = Task { [weak self] in
            guard let self else { return }
            let state = await self.resolve(request, classification: classification)
            guard !Task.isCancelled, currentGeneration == self.generation else { return }
            self.onState?(state)
        }
    }

    /// 关闭入口或重开面板时调用：丢弃在途任务，不展示错误。
    func cancel() {
        task?.cancel()
        task = nil
        generation &+= 1
    }

    // MARK: - 流程

    private func resolve(_ request: LookupRequest, classification: TextClassification) async -> LookupState {
        switch classification {
        case .rejected(let reason):
            return .failure(request, reason.message)
        case .sentence(let text):
            return await translate(text: text, request: request, kind: .sentence, note: request.note)
        case .word(let word):
            return await resolveWord(word, request: request)
        }
    }

    private func resolveWord(_ word: String, request: LookupRequest) async -> LookupState {
        // ⌥T：跳过词典，直接翻译
        if request.mode == .translate {
            return await translate(text: word, request: request, kind: .word, note: request.note)
        }

        var note: String? = request.note
        var entry: Entry?

        switch await store.lookupAsync(word) {
        case .success(let value):
            entry = value
        case .failure(let error):
            // 数据库故障可以降级，但必须保留原因，不能伪装成正常未命中
            let reason = error.localizedDescription + "；已继续查系统词典"
            note = [note, reason].compactMap { $0 }.joined(separator: "\n")
        }

        let morphology = await store.morphologyAsync(word)

        if let entry {
            return .result(request, .word(input: word, entry: entry, morphology: morphology, note: note))
        }
        if let systemEntry = systemDictionary.lookup(word) {
            return .result(request, .word(input: word, entry: systemEntry, morphology: morphology, note: note))
        }
        return await translate(text: word, request: request, kind: .word, note: note)
    }

    private func translate(text: String,
                           request: LookupRequest,
                           kind: TextKind,
                           note: String?) async -> LookupState {
        do {
            let result = try await translator.translate(
                TranslationRequest(text: text, source: "en", target: preferences.targetLanguage)
            )
            var mapped = LookupResult.translated(text: text, kind: kind,
                                                 translation: result.text, provider: result.providerName)
            mapped.note = note
            return .result(request, mapped)
        } catch {
            if kind == .word, Self.isLanguageUnavailable(error) {
                return .miss(request)
            }
            let message = Self.describe(error)
            if let note, !note.isEmpty {
                return .failure(request, message + "\n" + note)
            }
            return .failure(request, message)
        }
    }

    private static func isLanguageUnavailable(_ error: Error) -> Bool {
        guard let error = error as? TranslationError else { return false }
        switch error {
        case .languageUnavailable, .languagePackRequired:
            return true
        default:
            return false
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? TranslationError {
            return error.errorDescription ?? "翻译失败"
        }
        return error.localizedDescription
    }
}
