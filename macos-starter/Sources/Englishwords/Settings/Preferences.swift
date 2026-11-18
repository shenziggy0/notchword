import Foundation

enum PrefKey {
    static let hoverEnabled      = "trigger.pointerLookupEnabled"
    static let selectionEnabled  = "trigger.selectionEnabled"
    static let hoverDwellSeconds = "trigger.hoverDwellSeconds"
    static let expandsOnHover    = "trigger.expandsOnNotchHover"
    static let autoHideSeconds   = "panel.autoHideSeconds"
    static let showWordParts     = "trigger.wordParts"
    static let onlineEnabled     = "translation.online"
    static let baseURL           = "translation.baseURL"
    static let model             = "translation.model"
    static let targetLanguage    = "translation.target"
    static let lookupHotKey      = "hotkey.lookup"
    static let translateHotKey   = "hotkey.translate"
    static let regionLookupEnabled = "trigger.regionLookupEnabled"
    static let dictionarySources = "dictionary.sources"
    static let regionHotKey      = "hotkey.region"
}

/// 非敏感配置，存 UserDefaults。密钥走 `SecretStore`。
@MainActor
final class Preferences: ObservableObject {

    static let shared = Preferences()

    /// 任一配置变化后回调，用于重启自动入口、刷新面板计时。
    var onChange: (() -> Void)?

    private let defaults: UserDefaults

    var hoverEnabled: Bool = true {
        didSet { persist(hoverEnabled, PrefKey.hoverEnabled, oldValue) }
    }
    var selectionEnabled: Bool = true {
        didSet { persist(selectionEnabled, PrefKey.selectionEnabled, oldValue) }
    }
    var hoverDwellSeconds: Double = 0.35 {
        didSet { persist(hoverDwellSeconds, PrefKey.hoverDwellSeconds, oldValue) }
    }
    var expandsOnHover: Bool = true {
        didSet { persist(expandsOnHover, PrefKey.expandsOnHover, oldValue) }
    }
    var autoHideSeconds: Double = 5.0 {
        didSet { persist(autoHideSeconds, PrefKey.autoHideSeconds, oldValue) }
    }
    var showWordParts: Bool = true {
        didSet { persist(showWordParts, PrefKey.showWordParts, oldValue) }
    }
    var onlineEnabled: Bool = false {
        didSet { persist(onlineEnabled, PrefKey.onlineEnabled, oldValue) }
    }
    var baseURL: String = "https://api.openai.com/v1" {
        didSet { persist(baseURL, PrefKey.baseURL, oldValue) }
    }
    var model: String = "gpt-4o-mini" {
        didSet { persist(model, PrefKey.model, oldValue) }
    }
    var targetLanguage: String = "zh-Hans" {
        didSet { persist(targetLanguage, PrefKey.targetLanguage, oldValue) }
    }
    var lookupHotKey: HotKeySpec = .lookup {
        didSet { persistHotKey(lookupHotKey, PrefKey.lookupHotKey, oldValue) }
    }
    var translateHotKey: HotKeySpec = .translate {
        didSet { persistHotKey(translateHotKey, PrefKey.translateHotKey, oldValue) }
    }
    var regionLookupEnabled: Bool = true {
        didSet { persist(regionLookupEnabled, PrefKey.regionLookupEnabled, oldValue) }
    }
    var regionHotKey: HotKeySpec = .region {
        didSet { persistHotKey(regionHotKey, PrefKey.regionHotKey, oldValue) }
    }

    var videoSubtitles = false {
        didSet { persist(videoSubtitles, "trigger.videoSubtitles", oldValue) }
    }
    var screenSubtitles = true {
        didSet { persist(screenSubtitles, "trigger.screenSubtitles", oldValue) }
    }
    var pausesVideoOnPeek = true {
        didSet { persist(pausesVideoOnPeek, "trigger.pausesVideoOnPeek", oldValue) }
    }
    var resumesVideoAfterPeek = true {
        didSet { persist(resumesVideoAfterPeek, "trigger.resumesVideoAfterPeek", oldValue) }
    }
    var subtitleHotKey: HotKeySpec = .subtitle {
        didSet { persistHotKey(subtitleHotKey, "hotkey.subtitle", oldValue) }
    }
    var previousSubtitleHotKey: HotKeySpec = .previousSubtitle {
        didSet { persistHotKey(previousSubtitleHotKey, "hotkey.previousSubtitle", oldValue) }
    }
    var nextSubtitleHotKey: HotKeySpec = .nextSubtitle {
        didSet { persistHotKey(nextSubtitleHotKey, "hotkey.nextSubtitle", oldValue) }
    }

    var translationPreset: ProviderPreset = .custom {
        didSet { persist(translationPreset.rawValue, "translation.preset", oldValue.rawValue) }
    }
    private var presetModels: [String: String] = [:] {
        didSet { persist(presetModels, "translation.models", oldValue) }
    }
    var onlineModel: String {
        get { translationPreset == .custom ? model : presetModels[translationPreset.rawValue] ?? translationPreset.defaultModel }
        set {
            if translationPreset == .custom { model = newValue }
            else { presetModels[translationPreset.rawValue] = newValue }
        }
    }
    var onlineAddress: String { translationPreset == .custom ? baseURL : translationPreset.address }

    var speechVoice = "" {
        didSet { persist(speechVoice, "speech.voice", oldValue) }
    }
    var speechRate = 0.48 {
        didSet { persist(speechRate, "speech.rate", oldValue) }
    }
    var hapticOnExpand = true {
        didSet { persist(hapticOnExpand, "panel.hapticOnExpand", oldValue) }
    }
    var userExcluded: [String] = [] {
        didSet { persist(userExcluded, "apprules.userExcluded", oldValue) }
    }
    var sawOnboarding = false {
        didSet { persist(sawOnboarding, "firstRun.sawOnboarding", oldValue) }
    }

    var dictionarySources: [DictionarySource] = DictionarySource.defaults {
        didSet {
            guard dictionarySources != oldValue, let encoded = try? JSONEncoder().encode(dictionarySources) else { return }
            defaults.set(encoded, forKey: PrefKey.dictionarySources)
            objectWillChange.send()
            onChange?()
        }
    }

    /// 悬停停留时长下限/上限，避免配置里出现不可用的值。
    var hoverDwell: Double { min(max(hoverDwellSeconds, 0.15), 2.0) }
    var autoHideInterval: Double { min(max(autoHideSeconds, 1.5), 30.0) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            PrefKey.hoverEnabled: true,
            PrefKey.selectionEnabled: true,
            PrefKey.hoverDwellSeconds: 0.35,
            PrefKey.expandsOnHover: true,
            PrefKey.autoHideSeconds: 5.0,
            PrefKey.showWordParts: true,
            PrefKey.onlineEnabled: false,
            PrefKey.baseURL: "https://api.openai.com/v1",
            PrefKey.model: "gpt-4o-mini",
            PrefKey.targetLanguage: "zh-Hans",
            PrefKey.lookupHotKey: Self.encodeHotKey(.lookup),
            PrefKey.translateHotKey: Self.encodeHotKey(.translate),
            PrefKey.regionLookupEnabled: true,
            PrefKey.regionHotKey: Self.encodeHotKey(.region)
        ])

        hoverEnabled = defaults.bool(forKey: PrefKey.hoverEnabled)
        selectionEnabled = defaults.bool(forKey: PrefKey.selectionEnabled)
        hoverDwellSeconds = defaults.double(forKey: PrefKey.hoverDwellSeconds)
        expandsOnHover = defaults.bool(forKey: PrefKey.expandsOnHover)
        autoHideSeconds = defaults.double(forKey: PrefKey.autoHideSeconds)
        showWordParts = defaults.bool(forKey: PrefKey.showWordParts)
        onlineEnabled = defaults.bool(forKey: PrefKey.onlineEnabled)
        baseURL = defaults.string(forKey: PrefKey.baseURL) ?? "https://api.openai.com/v1"
        model = defaults.string(forKey: PrefKey.model) ?? "gpt-4o-mini"
        targetLanguage = defaults.string(forKey: PrefKey.targetLanguage) ?? "zh-Hans"
        lookupHotKey = Self.decodeHotKey(defaults, PrefKey.lookupHotKey, .lookup)
        translateHotKey = Self.decodeHotKey(defaults, PrefKey.translateHotKey, .translate)
        regionLookupEnabled = defaults.bool(forKey: PrefKey.regionLookupEnabled)
        regionHotKey = Self.decodeHotKey(defaults, PrefKey.regionHotKey, .region)
        videoSubtitles = defaults.bool(forKey: "trigger.videoSubtitles")
        screenSubtitles = defaults.object(forKey: "trigger.screenSubtitles") as? Bool ?? true
        pausesVideoOnPeek = defaults.object(forKey: "trigger.pausesVideoOnPeek") as? Bool ?? true
        resumesVideoAfterPeek = defaults.object(forKey: "trigger.resumesVideoAfterPeek") as? Bool ?? true
        subtitleHotKey = Self.decodeHotKey(defaults, "hotkey.subtitle", .subtitle)
        previousSubtitleHotKey = Self.decodeHotKey(defaults, "hotkey.previousSubtitle", .previousSubtitle)
        nextSubtitleHotKey = Self.decodeHotKey(defaults, "hotkey.nextSubtitle", .nextSubtitle)
        translationPreset = defaults.string(forKey: "translation.preset").flatMap(ProviderPreset.init(rawValue:)) ?? .custom
        presetModels = defaults.dictionary(forKey: "translation.models") as? [String: String] ?? [:]
        speechVoice = defaults.string(forKey: "speech.voice") ?? ""
        speechRate = defaults.object(forKey: "speech.rate") as? Double ?? 0.48
        hapticOnExpand = defaults.object(forKey: "panel.hapticOnExpand") as? Bool ?? true
        userExcluded = defaults.stringArray(forKey: "apprules.userExcluded") ?? []
        sawOnboarding = defaults.bool(forKey: "firstRun.sawOnboarding")
        if let data = defaults.data(forKey: PrefKey.dictionarySources),
           let decoded = try? JSONDecoder().decode([DictionarySource].self, from: data) {
            dictionarySources = decoded
        }
    }

    private func persist<T: Equatable>(_ value: T, _ key: String, _ oldValue: T) {
        guard value != oldValue else { return }
        defaults.set(value, forKey: key)
        objectWillChange.send()
        onChange?()
    }

    private func persistHotKey(_ value: HotKeySpec, _ key: String, _ oldValue: HotKeySpec) {
        guard value != oldValue else { return }
        defaults.set(Self.encodeHotKey(value), forKey: key)
        objectWillChange.send()
        onChange?()
    }

    private static func encodeHotKey(_ spec: HotKeySpec) -> Data {
        (try? JSONEncoder().encode(spec)) ?? Data()
    }

    private static func decodeHotKey(_ defaults: UserDefaults, _ key: String, _ fallback: HotKeySpec) -> HotKeySpec {
        guard let data = defaults.data(forKey: key),
              let spec = try? JSONDecoder().decode(HotKeySpec.self, from: data) else { return fallback }
        return spec
    }
}
