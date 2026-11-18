using System.Text;
using System.Text.Json;

namespace Englishwords.Core.Translate;

/// <summary>
/// Anthropic Messages API 联网翻译实现。
/// </summary>
public sealed class AnthropicProvider : ITranslationProviding
{
    private static readonly HttpClient SharedHttpClient = new();

    public string Id => "anthropic";
    public string DisplayName => "Anthropic";
    public Uri BaseUrl { get; }
    public string Model { get; }
    public string ApiKey { get; }
    public TimeSpan Timeout { get; }

    private readonly HttpClient _httpClient;

    public AnthropicProvider(
        Uri baseUrl,
        string model,
        string apiKey,
        HttpClient? httpClient = null,
        TimeSpan? timeout = null)
    {
        BaseUrl = baseUrl;
        Model = model;
        ApiKey = apiKey;
        _httpClient = httpClient ?? SharedHttpClient;
        Timeout = timeout ?? TimeSpan.FromSeconds(20);
    }

    public async Task<TranslationResult> TranslateAsync(
        TranslationRequest request,
        CancellationToken cancellationToken = default)
    {
        var text = (request.Text ?? string.Empty).Trim();
        if (text.Length == 0) throw new TranslationException(TranslationErrorKind.EmptyText);

        var endpoint = OpenAICompatProvider.AppendPath(BaseUrl, "messages");
        var payload = new
        {
            model = Model,
            max_tokens = 1024,
            system = OpenAICompatProvider.BuildPrompt(request.Target),
            messages = new[]
            {
                new { role = "user", content = text }
            }
        };

        using var httpReq = new HttpRequestMessage(HttpMethod.Post, endpoint)
        {
            Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json")
        };
        httpReq.Headers.Add("x-api-key", ApiKey);
        httpReq.Headers.Add("anthropic-version", "2023-06-01");

        var body = await OpenAICompatProvider.SendAsync(_httpClient, httpReq, Timeout, cancellationToken)
            .ConfigureAwait(false);
        var translation = ParseTranslationText(body);
        return new TranslationResult(translation, Id, DisplayName);
    }

    public static string ParseTranslationText(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("content", out var content) ||
                content.ValueKind != JsonValueKind.Array)
            {
                throw new TranslationException(TranslationErrorKind.Service, "Anthropic 响应格式无法解析");
            }

            var parts = new List<string>();
            foreach (var block in content.EnumerateArray())
            {
                if (block.TryGetProperty("type", out var typeProp) &&
                    typeProp.GetString() == "text" &&
                    block.TryGetProperty("text", out var textProp) &&
                    textProp.ValueKind == JsonValueKind.String)
                {
                    var text = textProp.GetString();
                    if (!string.IsNullOrEmpty(text)) parts.Add(text);
                }
            }

            var cleaned = OpenAICompatProvider.Clean(string.Join("\n", parts));
            if (cleaned.Length == 0)
            {
                throw new TranslationException(TranslationErrorKind.Service, "Anthropic 返回空译文");
            }
            return cleaned;
        }
        catch (TranslationException)
        {
            throw;
        }
        catch
        {
            throw new TranslationException(TranslationErrorKind.Service, "Anthropic 响应格式无法解析");
        }
    }
}
