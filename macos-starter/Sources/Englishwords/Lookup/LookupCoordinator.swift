import AppKit

/// 查询编排。所有入口（热键、菜单、剪贴板、悬停、划词）都提交到这里。
///
/// 单词顺序：内置词库 → 系统词典 → 翻译；短句直接翻译。
/// 每次提交带递增标识，只有最新请求可以更新 UI。
@MainActor
final class LookupCoordinator {

    private let store: DictionaryStore
    private let systemDictionary: any SystemDictionaryLooking
    private let translator: any Translating
    private let preferences: Preferences

    var onState: ((LookupState) -> Void)?

    private var generation = 0
    private var task: Task<Void, Never>?

    init(store: DictionaryStore,
         systemDictionary: any SystemDictionaryLooking,
         translator: any Translating,
         preferences: Preferences) {
        self.store = store
        self.systemDictionary = systemDictionary
        self.translator = translator
        self.preferences = preferences
    }

    @discardableResult
    func submit(_ request: LookupRequest) -> Bool {
        let classification = TextFilter.classify(request.text)
        if case .rejected = classification, request.trigger.isPassive { return false }

        cancel()
        let currentGeneration = generation

        if case .rejected(let reason) = classification {
            if request.trigger == .region, case .empty = reason {
                onState?(.failure(request, "未识别到文字"))
                return true
            }
            let message = request.note.map { reason.message + "\n" + $0 } ?? reason.message
            onState?(.failure(request, message))
            return true
        }

        onState?(.loading(request))

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await self.resolve(request, classification: classification)
                guard !Task.isCancelled, currentGeneration == self.generation else { return }
                self.task = nil
                self.onState?(state)
            } catch {
                // 取消不显示为查询失败。
            }
        }
        return true
    }

    /// 关闭入口或重开面板时调用：丢弃在途任务，不展示错误。
    func cancel() {
        task?.cancel()
        task = nil
        generation &+= 1
    }

    // MARK: - 流程

    private func resolve(_ request: LookupRequest, classification: TextClassification) async throws -> LookupState {
        switch classification {
        case .rejected(let reason):
            return .failure(request, reason.message)
        case .sentence(let text):
            return try await translate(text: text, request: request, kind: .sentence, note: request.note)
        case .word(let word):
            return try await resolveWord(word, request: request)
        }
    }

    private func resolveWord(_ word: String, request: LookupRequest) async throws -> LookupState {
        let morphology = await store.morphologyAsync(word)
        try Task.checkCancellation()

        // 翻译快捷键：跳过词典，单词仍带上已查到的拆分。短句不走这里。
        if request.mode == .translate {
            return try await translate(text: word, request: request, kind: .word,
                                   note: request.note, morphology: morphology)
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

        try Task.checkCancellation()
        if let entry {
            return .result(request, .word(input: word, entry: entry, morphology: morphology, note: note))
        }
        if let systemEntry = systemDictionary.lookup(word) {
            return .result(request, .word(input: word, entry: systemEntry, morphology: morphology, note: note))
        }
        return try await translate(text: word, request: request, kind: .word, note: note, morphology: morphology)
    }

    private func translate(text: String,
                           request: LookupRequest,
                           kind: TextKind,
                           note: String?,
                           morphology: Morphology? = nil) async throws -> LookupState {
        do {
            let result = try await translator.translate(
                TranslationRequest(text: text, source: "en", target: preferences.targetLanguage)
            )
            var mapped = LookupResult.translated(text: text, kind: kind,
                                                 translation: result.text, provider: result.providerName,
                                                 morphology: kind == .word ? morphology : nil)
            mapped.note = note
            return .result(request, mapped)
        } catch {
            if Task.isCancelled || TranslationError.isCancellation(error) { throw error }
            let message = Self.describe(error)
            if let note, !note.isEmpty {
                return .failure(request, message + "\n" + note)
            }
            return .failure(request, message)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? TranslationError {
            return error.errorDescription ?? "翻译失败"
        }
        return error.localizedDescription
    }
}
