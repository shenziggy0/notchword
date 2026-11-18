import Foundation

enum ProviderPreset: String, CaseIterable, Identifiable {
    case custom, openai, deepseek, moonshot, siliconflow, dashscope, minimax, gemini, anthropic

    var id: String { rawValue }
    var name: String {
        switch self {
        case .custom: return "自定义"
        case .openai: return "OpenAI"
        case .deepseek: return "DeepSeek"
        case .moonshot: return "Moonshot"
        case .siliconflow: return "SiliconFlow"
        case .dashscope: return "DashScope"
        case .minimax: return "MiniMax"
        case .gemini: return "Gemini"
        case .anthropic: return "Anthropic"
        }
    }

    var address: String {
        switch self {
        case .custom, .openai: return "https://api.openai.com/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .moonshot: return "https://api.moonshot.cn/v1"
        case .siliconflow: return "https://api.siliconflow.cn/v1"
        case .dashscope: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .minimax: return "https://api.minimax.io/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .anthropic: return "https://api.anthropic.com/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .custom, .openai: return "gpt-4o-mini"
        case .deepseek: return "deepseek-flash"
        case .moonshot: return "kimi-k2.5"
        case .siliconflow: return "deepseek-ai/DeepSeek-V4-Flash"
        case .dashscope: return "qwen-flash"
        case .minimax: return "MiniMax-M2.7"
        case .gemini: return "gemini-3.8-flash"
        case .anthropic: return "claude-haiku-5-5"
        }
    }

    var supportsOpenAIModelList: Bool { self != .anthropic }

    @MainActor
    func makeProvider(url: URL, model: String, key: String) -> any TranslationProviding {
        if self == .anthropic {
            return AnthropicProvider(baseURL: url, model: model, apiKey: key)
        }
        return OpenAICompatProvider(baseURL: url, model: model, apiKey: key,
                                    id: rawValue, displayName: self == .custom ? "联网翻译" : name)
    }
}
