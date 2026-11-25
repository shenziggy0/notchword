using Englishwords.Core.Lookup;
using Englishwords.Core.Notebook;
using Xunit;
using Microsoft.Data.Sqlite;

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

    [Fact]
    public async Task NotebookStore_MigratesV1AndReopensExamplesAndReview()
    {
        using (var v1 = new SqliteConnection($"Data Source={_dbPath};Pooling=false"))
        {
            v1.Open();
            using var cmd = v1.CreateCommand();
            cmd.CommandText = """
                CREATE TABLE lookups(id INTEGER PRIMARY KEY, word TEXT NOT NULL,
                  source TEXT NOT NULL, trigger TEXT NOT NULL, created_at INTEGER NOT NULL);
                CREATE INDEX lookups_created_at ON lookups(created_at);
                CREATE INDEX lookups_word ON lookups(word);
                CREATE TABLE favorites(word TEXT PRIMARY KEY, created_at INTEGER NOT NULL) WITHOUT ROWID;
                INSERT INTO favorites VALUES ('abduct', 1);
                INSERT INTO lookups VALUES (1, 'abduct', '内置词库', 'hotkey', 1);
                PRAGMA user_version = 1;
                """;
            cmd.ExecuteNonQuery();
        }
        using var store = new NotebookStore(_dbPath);
        Assert.Equal(["abduct"], await store.GetFavoritesAsync());
        Assert.Single(await store.GetHistoryAsync());
        var context = new LookupContext("They foiled it, then foiled it again.", 21, 6);
        await store.SaveExampleAsync("foil", context, "挫败");
        await store.SaveExampleAsync("foil", context, "阻止");
        using var reopened = new NotebookStore(_dbPath);
        var example = Assert.Single(await reopened.GetExamplesAsync("foil"));
        Assert.Equal("They foiled it, then _____ it again.", example.Prompt);
        Assert.Equal("阻止", example.Meaning);
        var date = DateTimeOffset.Now;
        foreach (var day in new[] { date, date.AddDays(-1) })
        {
            await store.RecordLookupAsync("foil", "内置词库", LookupTrigger.Hotkey, day);
            await store.RecordLookupAsync("noise", "内置词库", LookupTrigger.Selection, day);
        }
        Assert.Equal(["foil"], await reopened.GetReviewWordsAsync(date));
        Assert.Equal(5, (await reopened.GetStatsAsync(date)).Total);
        await store.SetFavoriteAsync("foil", false);
        Assert.Empty(await reopened.GetExamplesAsync("foil"));
    }

    public void Dispose()
    {
        if (File.Exists(_dbPath)) File.Delete(_dbPath);
    }
}
