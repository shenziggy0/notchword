import Foundation
import Testing
@testable import Englishwords

@Test("字幕重叠片段去重、断句与中文时间对齐")
func subtitleTiming() {
    let english = SentenceMerger.merge([
        SubtitleCue(text: "so we", start: 0, end: 0.7),
        SubtitleCue(text: "we went home.", start: 0.9, end: 1.6),
        SubtitleCue(text: "Then", start: 3.1, end: 3.7)
    ])
    #expect(english.map(\.text) == ["so we went home.", "Then"])
    guard let sentence = english.first else { return }
    #expect(SubtitleAligner.translation(of: sentence, in: [
        SubtitleCue(text: "所以", start: 0, end: 0.6),
        SubtitleCue(text: "我们回家了。", start: 0.6, end: 1.6)
    ]) == "所以 我们回家了。")
    #expect(SubtitleAligner.translation(of: sentence, in: [
        SubtitleCue(text: "不够覆盖", start: 1.5, end: 1.7)
    ]) == nil)
}

@Test("转换模型列表与 Anthropic 文本，预设模型彼此独立")
@MainActor
func providerFormatsAndPreferences() throws {
    let models = Data(#"{"data":[{"id":"a"},{"id":"z"},{"id":"a"}]}"#.utf8)
    #expect(try OpenAICompatProvider.models(from: models) == ["a", "z"])
    let response = Data(#"{"content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"你好。"}]}"#.utf8)
    #expect(try AnthropicProvider.translationText(from: response) == "你好。")

    let name = "notchword.test.translation.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let prefs = Preferences(defaults: defaults)
    prefs.baseURL = "https://example.invalid/v1"
    prefs.onlineModel = "old-custom"
    prefs.translationPreset = .deepseek
    prefs.onlineModel = "alternate-deepseek"
    prefs.translationPreset = .anthropic
    #expect(prefs.onlineModel == ProviderPreset.anthropic.defaultModel)
    prefs.translationPreset = .custom
    #expect(prefs.onlineModel == "old-custom")
    #expect(prefs.onlineAddress == "https://example.invalid/v1")
    prefs.translationPreset = .deepseek
    #expect(Preferences(defaults: defaults).onlineModel == "alternate-deepseek")
}
