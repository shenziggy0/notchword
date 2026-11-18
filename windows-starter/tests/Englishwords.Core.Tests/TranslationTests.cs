using System.Net;
using System.Text;
using Englishwords.Core.Translate;
using Xunit;

namespace Englishwords.Core.Tests;

public sealed class TranslationTests
{
    private sealed class StubHttpMessageHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> handler)
        : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            => handler(request, cancellationToken);
    }

    [Fact]
    public async Task OpenAIProvider_SlowResponse_ThrowsTimedOutImmediately()
    {
        var handler = new StubHttpMessageHandler(async (_, _) =>
        {
            // 故意忽略取消令牌模拟底层挂起
            await Task.Delay(TimeSpan.FromSeconds(5));
            return new HttpResponseMessage(HttpStatusCode.OK);
        });

        using var client = new HttpClient(handler);
        var provider = new OpenAICompatProvider(
            new Uri("https://example.com/v1"),
            "gpt-4o-mini",
            "sk-test",
            httpClient: client,
            timeout: TimeSpan.FromMilliseconds(80));

        var ex = await Assert.ThrowsAsync<TranslationException>(() =>
            provider.TranslateAsync(new TranslationRequest("hello", "en", "zh-Hans")));
        Assert.Equal(TranslationErrorKind.TimedOut, ex.Kind);
    }

    [Fact]
    public async Task OpenAIAndAnthropicProviders_ParseAndCleanResponses()
    {
        var openAiHandler = new StubHttpMessageHandler((_, _) =>
        {
            const string json = """{"choices":[{"message":{"content":"<think>reasoning</think>\n“你好”"}}]}""";
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(json, Encoding.UTF8, "application/json")
            });
        });

        using var openAiClient = new HttpClient(openAiHandler);
        var openAi = new OpenAICompatProvider(new Uri("https://example.com/v1"), "m", "k", httpClient: openAiClient);
        var openAiRes = await openAi.TranslateAsync(new TranslationRequest("hello", "en", "zh-Hans"));
        Assert.Equal("你好", openAiRes.Text);

        var anthropicHandler = new StubHttpMessageHandler((_, _) =>
        {
            const string json = """{"content":[{"type":"text","text":"「世界」"}]}""";
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(json, Encoding.UTF8, "application/json")
            });
        });

        using var anthropicClient = new HttpClient(anthropicHandler);
        var anthropic = new AnthropicProvider(new Uri("https://api.anthropic.com/v1"), "claude", "k", httpClient: anthropicClient);
        var anthropicRes = await anthropic.TranslateAsync(new TranslationRequest("world", "en", "zh-Hans"));
        Assert.Equal("世界", anthropicRes.Text);
    }
}
