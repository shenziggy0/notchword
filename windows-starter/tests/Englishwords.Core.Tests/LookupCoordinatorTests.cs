using Englishwords.Core.Config;
using Englishwords.Core.Dictionary;
using Englishwords.Core.Lookup;
using Englishwords.Core.Translate;
using Xunit;

namespace Englishwords.Core.Tests;

public sealed class LookupCoordinatorTests
{
    private sealed class FakeTranslator(Func<TranslationRequest, CancellationToken, Task<TranslationResult>> handler) : ITranslating
    {
        public Task<TranslationResult> TranslateAsync(TranslationRequest request, CancellationToken cancellationToken = default)
            => handler(request, cancellationToken);
    }

    [Fact]
    public async Task Submit_PassiveRejectDoesNotCancelActiveAndNewQueryCancelsOld()
    {
        using var store = new DictionaryStore(null, null);
        var prefs = new Preferences { DictionarySources = [] };
        var library = new StarDictLibrary(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N")));

        var firstStarted = new TaskCompletionSource();
        var secondCompleted = new TaskCompletionSource<LookupState>();

        var translator = new FakeTranslator(async (req, ct) =>
        {
            if (req.Text == "firstword")
            {
                firstStarted.TrySetResult();
                await Task.Delay(5000, ct);
            }
            return new TranslationResult($"译:{req.Text}", "fake", "Fake");
        });

        var coordinator = new LookupCoordinator(store, translator, prefs, library);
        var observed = new List<LookupState>();
        coordinator.StateChanged += state =>
        {
            observed.Add(state);
            if (state is LookupState.Result res && res.Request.Text == "secondword")
            {
                secondCompleted.TrySetResult(state);
            }
        };

        Assert.True(coordinator.Submit(new LookupRequest("firstword", LookupTrigger.Hotkey)));
        await firstStarted.Task;

        // 被动拒绝的请求返回 false，不得取消正在进行的查询
        Assert.False(coordinator.Submit(new LookupRequest("const x = 1;", LookupTrigger.Selection)));

        // 新的有效请求取消旧请求并最终输出新结果
        Assert.True(coordinator.Submit(new LookupRequest("secondword", LookupTrigger.Hotkey)));
        var finalState = await secondCompleted.Task.WaitAsync(TimeSpan.FromSeconds(2));

        var result = Assert.IsType<LookupState.Result>(finalState);
        Assert.Equal("译:secondword", result.Value.Body);
        Assert.DoesNotContain(observed, s => s is LookupState.Result r && r.Request.Text == "firstword");
    }
}
