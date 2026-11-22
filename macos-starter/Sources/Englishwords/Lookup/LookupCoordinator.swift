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
    private let starDictionaries: StarDictLibrary

    var onState: ((LookupState) -> Void)?

    private var generation = 0
    private var task: Task<Void, Never>?

    init(store: DictionaryStore,
         systemDictionary: any SystemDictionaryLooking,
         translator: any Translating,
         preferences: Preferences,
         starDictionaries: StarDictLibrary = .shared) {
        self.store = store
        self.systemDictionary = systemDictionary
        self.translator = translator
        self.preferences = preferences
        self.starDictionaries = starDictionaries
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
                // 取消不显示为查询失败；其他错误必须落地，避免面板永久停在 loading。
                guard !Task.isCancelled, currentGeneration == self.generation else { return }
                self.task = nil
                self.onState?(.failure(request, Self.describe(error)))
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

        var notes = [request.note].compactMap { $0 }
        for source in preferences.dictionarySources where source.enabled {
            try Task.checkCancellation()
            do {
                let entry: Entry?
                switch source.kind {
                case .builtin: entry = try await store.lookupAsync(word).get()
                case .system: entry = systemDictionary.lookup(word)
                case .stardict: entry = try await starDictionaries.lookup(word, source: source)
                }
                if let entry {
                    let note = notes.isEmpty ? nil : notes.joined(separator: "\n")
                    return .result(request, .word(input: word, entry: entry, morphology: morphology, note: note))
                }
            } catch {
                notes.append(error.localizedDescription)
            }
        }
        let note = notes.isEmpty ? nil : notes.joined(separator: "\n")
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
