using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Englishwords.Core.Translate;

/// <summary>
/// OpenAI 兼容协议联网翻译实现。
/// </summary>
public sealed partial class OpenAICompatProvider : ITranslationProviding
{
    private static readonly HttpClient SharedHttpClient = new();

    public string Id { get; }
    public string DisplayName { get; }
    public Uri BaseUrl { get; }
    public string Model { get; }
    public string ApiKey { get; }
    public TimeSpan Timeout { get; }

    private readonly HttpClient _httpClient;

    [GeneratedRegex(@"<think>.*?</think>", RegexOptions.Singleline | RegexOptions.CultureInvariant)]
    private static partial Regex ThinkTagRegex();

    public OpenAICompatProvider(
        Uri baseUrl,
        string model,
        string apiKey,
        string id = "openai-compatible",
        string displayName = "联网翻译",
        HttpClient? httpClient = null,
        TimeSpan? timeout = null)
    {
        BaseUrl = baseUrl;
        Model = model;
        ApiKey = apiKey;
        Id = id;
        DisplayName = displayName;
        _httpClient = httpClient ?? SharedHttpClient;
        Timeout = timeout ?? TimeSpan.FromSeconds(20);
    }

    public async Task<TranslationResult> TranslateAsync(
        TranslationRequest request,
        CancellationToken cancellationToken = default)
    {
        var text = (request.Text ?? string.Empty).Trim();
        if (text.Length == 0) throw new TranslationException(TranslationErrorKind.EmptyText);

        var endpoint = AppendPath(BaseUrl, "chat/completions");
        var payload = new
        {
            model = Model,
            temperature = 0,
            messages = new[]
            {
                new { role = "system", content = BuildPrompt(request.Target) },
                new { role = "user", content = text }
            }
        };

        using var httpReq = new HttpRequestMessage(HttpMethod.Post, endpoint)
        {
            Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json")
        };
        httpReq.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ApiKey);

        var body = await SendAsync(_httpClient, httpReq, Timeout, cancellationToken).ConfigureAwait(false);
        var content = ExtractContent(body)
            ?? throw new TranslationException(TranslationErrorKind.Service, "响应格式无法解析");

        var cleaned = Clean(content);
        if (cleaned.Length == 0) throw new TranslationException(TranslationErrorKind.Service, "服务返回空译文");

        return new TranslationResult(cleaned, Id, DisplayName);
    }

    public async Task<IReadOnlyList<string>> FetchModelsAsync(CancellationToken cancellationToken = default)
    {
        var endpoint = AppendPath(BaseUrl, "models");
        using var httpReq = new HttpRequestMessage(HttpMethod.Get, endpoint);
        httpReq.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ApiKey);

        var body = await SendAsync(_httpClient, httpReq, Timeout, cancellationToken).ConfigureAwait(false);
        return ParseModels(body);
    }

    public static IReadOnlyList<string> ParseModels(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array)
            {
                throw new TranslationException(TranslationErrorKind.Service, "模型列表格式无法解析");
            }

            var set = new HashSet<string>(StringComparer.Ordinal);
            foreach (var item in data.EnumerateArray())
            {
                if (item.TryGetProperty("id", out var idProp) && idProp.ValueKind == JsonValueKind.String)
                {
                    var id = idProp.GetString();
                    if (!string.IsNullOrEmpty(id)) set.Add(id);
                }
            }
            return set.OrderBy(s => s, StringComparer.Ordinal).ToArray();
        }
        catch (TranslationException)
        {
            throw;
        }
        catch
        {
            throw new TranslationException(TranslationErrorKind.Service, "模型列表格式无法解析");
        }
    }

    internal static async Task<string> SendAsync(
        HttpClient client,
        HttpRequestMessage request,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        try
        {
            return await TimeoutHelper.RunWithTimeoutAsync(timeout, async ct =>
            {
                using var resp = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct)
                    .ConfigureAwait(false);
                var data = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
                if (!resp.IsSuccessStatusCode)
                {
                    throw new TranslationException(
                        TranslationErrorKind.Service,
                        $"HTTP {(int)resp.StatusCode}{ExtractErrorDetail(data)}");
                }
                return data;
            }, cancellationToken).ConfigureAwait(false);
        }
        catch (TranslationException)
        {
            throw;
        }
        catch (OperationCanceledException)
        {
            throw new TranslationException(TranslationErrorKind.Cancelled);
        }
        catch (Exception ex)
        {
            throw new TranslationException(TranslationErrorKind.Service, ex.Message);
        }
    }

    internal static Uri AppendPath(Uri baseUri, string segment)
    {
        var raw = baseUri.AbsoluteUri.TrimEnd('/');
        return new Uri($"{raw}/{segment.TrimStart('/')}", UriKind.Absolute);
    }

    public static string BuildPrompt(string target)
    {
        var language = target.StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? "简体中文" : target;
        return $"你是英译中翻译器。只输出{language}译文，不要解释、不要加引号、不要重复原文。" +
               "保留人名、术语与代码的原文。若输入是一个单词，只给出最常用的释义。";
    }

    private static string? ExtractContent(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("choices", out var choices) ||
                choices.ValueKind != JsonValueKind.Array ||
                choices.GetArrayLength() == 0)
            {
                return null;
            }

            var first = choices[0];
            if (first.TryGetProperty("message", out var msg) &&
                msg.TryGetProperty("content", out var content) &&
                content.ValueKind == JsonValueKind.String)
            {
                return content.GetString();
            }
            return null;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// 剥离推理模型的思考段落并去除首尾包裹引号。
    /// </summary>
    public static string Clean(string raw)
    {
        var text = ThinkTagRegex().Replace(raw, string.Empty).Trim();
        (char Leading, char Trailing)[] wrappers = [('"', '"'), ('“', '”'), ('「', '」')];
        foreach (var (leading, trailing) in wrappers)
        {
            if (text.Length >= 2 && text[0] == leading && text[^1] == trailing)
            {
                text = text[1..^1];
                break;
            }
        }
        return text.Trim();
    }

    private static string ExtractErrorDetail(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("error", out var err) &&
                err.TryGetProperty("message", out var msg) &&
                msg.ValueKind == JsonValueKind.String)
            {
                var s = msg.GetString() ?? string.Empty;
                return "：" + (s.Length > 120 ? s[..120] : s);
            }

            if (doc.RootElement.TryGetProperty("message", out var topMsg) &&
                topMsg.ValueKind == JsonValueKind.String)
            {
                var s = topMsg.GetString() ?? string.Empty;
                return "：" + (s.Length > 120 ? s[..120] : s);
            }
        }
        catch
        {
            // 非 JSON 错误体直接忽略
        }
        return string.Empty;
    }
}
