using Englishwords.Core.Dictionary;
using Xunit;

namespace Englishwords.Core.Tests;

public sealed class DictionaryStoreTests
{
    private static (string DictPath, string PartsPath) LocateRepoResources()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var dict = Path.Combine(dir.FullName, "macos-starter", "Sources", "Englishwords", "Resources", "dictionary.sqlite");
            var parts = Path.Combine(dir.FullName, "macos-starter", "Sources", "Englishwords", "Resources", "wordparts.sqlite");
            if (File.Exists(dict) && File.Exists(parts))
            {
                return (dict, parts);
            }
            dir = dir.Parent;
        }
        throw new FileNotFoundException("未能定位 macos-starter/Sources/Englishwords/Resources/*.sqlite");
    }

    [Fact]
    public void Lookup_InflectedAndUnbelievable_ReturnsEntryMorphologyAndDistinguishesMiss()
    {
        var (dictPath, partsPath) = LocateRepoResources();
        using var store = new DictionaryStore(dictPath, partsPath);

        // 屈折还原：abandoned -> abandon
        var abandoned = store.Lookup("abandoned");
        Assert.Null(abandoned.Error);
        Assert.NotNull(abandoned.Entry);
        Assert.Equal("abandon", abandoned.Entry!.Word);
        Assert.NotEmpty(abandoned.Entry.Translation);
        Assert.NotEmpty(abandoned.Entry.Tags);

        // 词根词缀拆分：unbelievable -> un / believ / able
        var morphology = store.GetMorphology("unbelievable");
        Assert.NotNull(morphology);
        Assert.Equal(["un", "believ", "able"], morphology!.Segments.Select(s => s.Label).ToArray());

        // 正常未命中返回 Success(null)，而非异常
        var miss = store.Lookup("zzzznotaword");
        Assert.Null(miss.Error);
        Assert.Null(miss.Entry);
    }

    [Fact]
    public void Lookup_MissingDatabase_ReturnsUnavailableError()
    {
        using var store = new DictionaryStore("/nonexistent/dictionary.sqlite", null);
        var outcome = store.Lookup("test");
        Assert.Null(outcome.Entry);
        Assert.NotNull(outcome.Error);
        Assert.Equal(DictionaryErrorKind.Unavailable, outcome.Error!.Kind);
    }
}
