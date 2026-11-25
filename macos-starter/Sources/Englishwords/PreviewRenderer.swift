import AppKit
import SwiftUI

/// 离屏渲染结果面板，用于自检与生成预览图。
///
/// 用法：`Englishwords --render-preview /tmp/preview.png [word|sentence|loading|miss|failure]`
/// 演示数据只在这里显式构造，查询链路不会拿它兜底。
enum PreviewRenderer {

    enum Demo: String {
        case word
        case sentence
        case loading
        case miss
        case failure
    }

    @MainActor
    @discardableResult
    static func render(to path: String, demo: Demo = .word) -> Bool {
        LexiconTheme.current.apply()
        let dictionary = DictionaryStore()
        let view = ResultView(
            state: makeState(demo, dictionary: dictionary),
            mode: .expanded,
            topInset: 12,
            width: 474,
            maxHeight: nil,
            showWordParts: true,
            lookupShortcut: HotKeySpec.lookup.display,
            notebook: NotebookModel(store: NotebookStore()),
            relatedWords: { id, word in await dictionary.relatedWords(partID: id, excluding: word) },
            isStaticPreview: true
        )
        .environment(\.lexiconSnapshot, true)
        .padding(.top, 18)
        .padding(.bottom, 26)
        .padding(.horizontal, 26)
        .background(Lexicon.subtle)
        .environment(\.colorScheme, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            FileLog.write("preview: 渲染失败")
            return false
        }

        do {
            try png.write(to: URL(fileURLWithPath: path))
            FileLog.write("preview: 已写入 \(path) (\(Int(image.size.width))x\(Int(image.size.height)) @2x)")
            return true
        } catch {
            FileLog.write("preview: 写文件失败 \(error)")
            return false
        }
    }

    // MARK: - 演示数据

    private static func makeState(_ demo: Demo, dictionary: DictionaryStore) -> LookupState {
        let wordRequest = LookupRequest(text: "unbelievable", trigger: .hover, screen: NSScreen.main)
        let sentenceText = "The quick brown fox jumps over the lazy dog."
        let sentenceRequest = LookupRequest(text: sentenceText, trigger: .selection, screen: NSScreen.main)

        switch demo {
        case .word:
            switch dictionary.lookup(wordRequest.text) {
            case .success(let entry?):
                return .result(wordRequest, .word(input: wordRequest.text, entry: entry,
                                                  morphology: dictionary.morphology(entry.word), note: nil))
            case .success(nil): return .miss(wordRequest)
            case .failure(let error): return .failure(wordRequest, error.localizedDescription)
            }

        case .sentence:
            return .result(sentenceRequest, .translated(
                text: sentenceText,
                kind: .sentence,
                translation: "敏捷的棕色狐狸跃过那只懒狗。",
                provider: "Apple 本地翻译"
            ))

        case .loading:
            return .loading(wordRequest)

        case .miss:
            return .miss(LookupRequest(text: "zzzq", trigger: .hotkey, screen: NSScreen.main))

        case .failure:
            return .failure(
                LookupRequest(text: "serendipity", trigger: .hotkey, screen: NSScreen.main),
                "需要先下载语言包：设置 → 翻译 → 准备语言包。"
            )
        }
    }
}
