using Englishwords.Core.Lookup;
using Englishwords.Core.Notebook;
using Xunit;

namespace Englishwords.Core.Tests;

public sealed class NotebookStoreTests : IDisposable
{
    private readonly string _dbPath = Path.Combine(Path.GetTempPath(), $"ew-notebook-{Guid.NewGuid():N}.sqlite");

    [Fact]
    public async Task NotebookStore_RecordsHistoryFavoritesAndStats()
    {
        using var store = new NotebookStore(_dbPath);
        var now = DateTimeOffset.Now;

        await store.RecordLookupAsync("abandon", "内置词库", LookupTrigger.Hotkey, now.AddDays(-1));
        await store.RecordLookupAsync("abandon", "内置词库", LookupTrigger.Selection, now);
        await store.RecordLookupAsync("probe", "内置词库", LookupTrigger.Region, now);

        await store.SetFavoriteAsync("abandon", true);
        Assert.Equal(["abandon"], await store.GetFavoritesAsync());
        await store.SetFavoriteAsync("abandon", false);
        Assert.Empty(await store.GetFavoritesAsync());

        var history = await store.GetHistoryAsync();
        Assert.Equal(3, history.Count);
        Assert.Equal("probe", history[0].Word);

        var stats = await store.GetStatsAsync(now);
        Assert.Equal(3, stats.Total);
        Assert.Equal(7, stats.Daily.Count);
        Assert.Equal("abandon", stats.Frequent[0].Word);
        Assert.Equal(2, stats.Frequent[0].Count);
    }

    public void Dispose()
    {
        if (File.Exists(_dbPath)) File.Delete(_dbPath);
    }
}
