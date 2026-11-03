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

    /// 悬停停留时长下限/上限，避免配置里出现不可用的值。
    var hoverDwell: Double { min(max(hoverDwellSeconds, 0.15), 2.0) }
    var autoHideInterval: Double { min(max(autoHideSeconds, 1.5), 30.0) }

    private init(defaults: UserDefaults = .standard) {
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
            PrefKey.targetLanguage: "zh-Hans"
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
    }

    private func persist<T: Equatable>(_ value: T, _ key: String, _ oldValue: T) {
        guard value != oldValue else { return }
        defaults.set(value, forKey: key)
        objectWillChange.send()
        onChange?()
    }
}
