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

        var body = await SendAsync(_httpClient, () =>
        {
            var message = new HttpRequestMessage(HttpMethod.Post, endpoint)
            {
                Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json")
            };
            message.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ApiKey);
            return message;
        }, Timeout, cancellationToken).ConfigureAwait(false);
        var content = ExtractContent(body)
            ?? throw new TranslationException(TranslationErrorKind.Service, "响应格式无法解析");

        var cleaned = Clean(content);
        if (cleaned.Length == 0) throw new TranslationException(TranslationErrorKind.Service, "服务返回空译文");

        return new TranslationResult(cleaned, Id, DisplayName);
    }

    public async Task<IReadOnlyList<string>> FetchModelsAsync(CancellationToken cancellationToken = default)
    {
        var endpoint = AppendPath(BaseUrl, "models");

        var body = await SendAsync(_httpClient, () =>
        {
            var message = new HttpRequestMessage(HttpMethod.Get, endpoint);
            message.Headers.Authorization = new AuthenticationHeaderValue("Bearer", ApiKey);
            return message;
        }, Timeout, cancellationToken).ConfigureAwait(false);
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

    /// <summary>
    /// 发出请求并读取响应体。请求对象在 <c>workTask</c> 内部创建与释放，
    /// 超时返回时不会提前 Dispose 仍在飞的 <see cref="HttpRequestMessage"/>。
    /// </summary>
    internal static async Task<string> SendAsync(
        HttpClient client,
        Func<HttpRequestMessage> createRequest,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        try
        {
            return await TimeoutHelper.RunWithTimeoutAsync(timeout, async ct =>
            {
                using var request = createRequest();
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
            // 只有调用方主动取消才算 Cancelled；HttpClient 自身超时也要报 TimedOut。
            throw new TranslationException(cancellationToken.IsCancellationRequested
                ? TranslationErrorKind.Cancelled
                : TranslationErrorKind.TimedOut);
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
                var inner = text[1..^1];
                // 仅当外层成对引号且内部无同种引号时才剥离：
                // “苹果”和“橘子” 这种内部带引号的译文不能被削掉一层。
                if (inner.Contains(leading) || inner.Contains(trailing)) continue;

                text = inner;
                break;
            }
        }
        return text.Trim();
    }

    private static string Clip(string? detail)
    {
        var s = (detail ?? string.Empty).Trim();
        return s.Length == 0 ? string.Empty : "：" + (s.Length > 120 ? s[..120] : s);
    }

    private static string ExtractErrorDetail(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);

            if (doc.RootElement.TryGetProperty("error", out var err))
            {
                if (err.ValueKind == JsonValueKind.String) return Clip(err.GetString());

                if (err.ValueKind == JsonValueKind.Object &&
                    err.TryGetProperty("message", out var msg) &&
                    msg.ValueKind == JsonValueKind.String)
                {
                    return Clip(msg.GetString());
                }
            }

            if (doc.RootElement.TryGetProperty("detail", out var detail) &&
                detail.ValueKind == JsonValueKind.String)
            {
                return Clip(detail.GetString());
            }

            if (doc.RootElement.TryGetProperty("message", out var topMsg) &&
                topMsg.ValueKind == JsonValueKind.String)
            {
                return Clip(topMsg.GetString());
            }
        }
        catch
        {
            // 非 JSON 错误体直接忽略
        }
        return string.Empty;
    }
}
