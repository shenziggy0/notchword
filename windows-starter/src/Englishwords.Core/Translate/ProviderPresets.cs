namespace Englishwords.Core.Translate;

public enum ProviderPreset
{
    Custom,
    OpenAI,
    DeepSeek,
    Moonshot,
    SiliconFlow,
    DashScope,
    MiniMax,
    Gemini,
    Anthropic
}

public static class ProviderPresetExtensions
{
    public static string GetRawValue(this ProviderPreset preset) => preset.ToString().ToLowerInvariant();

    public static string GetDisplayName(this ProviderPreset preset) => preset switch
    {
        ProviderPreset.Custom => "自定义",
        ProviderPreset.OpenAI => "OpenAI",
        ProviderPreset.DeepSeek => "DeepSeek",
        ProviderPreset.Moonshot => "Moonshot",
        ProviderPreset.SiliconFlow => "SiliconFlow",
        ProviderPreset.DashScope => "DashScope",
        ProviderPreset.MiniMax => "MiniMax",
        ProviderPreset.Gemini => "Gemini",
        ProviderPreset.Anthropic => "Anthropic",
        _ => "自定义"
    };

    public static string GetDefaultAddress(this ProviderPreset preset) => preset switch
    {
        ProviderPreset.Custom or ProviderPreset.OpenAI => "https://api.openai.com/v1",
        ProviderPreset.DeepSeek => "https://api.deepseek.com/v1",
        ProviderPreset.Moonshot => "https://api.moonshot.cn/v1",
        ProviderPreset.SiliconFlow => "https://api.siliconflow.cn/v1",
        ProviderPreset.DashScope => "https://dashscope.aliyuncs.com/compatible-mode/v1",
        ProviderPreset.MiniMax => "https://api.minimax.io/v1",
        ProviderPreset.Gemini => "https://generativelanguage.googleapis.com/v1beta/openai",
        ProviderPreset.Anthropic => "https://api.anthropic.com/v1",
        _ => "https://api.openai.com/v1"
    };

    public static string GetDefaultModel(this ProviderPreset preset) => preset switch
    {
        ProviderPreset.Custom or ProviderPreset.OpenAI => "gpt-4o-mini",
        ProviderPreset.DeepSeek => "deepseek-flash",
        ProviderPreset.Moonshot => "kimi-k2.5",
        ProviderPreset.SiliconFlow => "deepseek-ai/DeepSeek-V4-Flash",
        ProviderPreset.DashScope => "qwen-flash",
        ProviderPreset.MiniMax => "MiniMax-M2.7",
        ProviderPreset.Gemini => "gemini-3.8-flash",
        ProviderPreset.Anthropic => "claude-haiku-5-5",
        _ => "gpt-4o-mini"
    };

    public static bool SupportsOpenAIModelList(this ProviderPreset preset) => preset != ProviderPreset.Anthropic;

    public static ITranslationProviding MakeProvider(
        this ProviderPreset preset,
        Uri baseUrl,
        string model,
        string apiKey,
        HttpClient? httpClient = null)
    {
        if (preset == ProviderPreset.Anthropic)
        {
            return new AnthropicProvider(baseUrl, model, apiKey, httpClient);
        }

        var display = preset == ProviderPreset.Custom ? "联网翻译" : preset.GetDisplayName();
        return new OpenAICompatProvider(baseUrl, model, apiKey, preset.GetRawValue(), display, httpClient);
    }
}
