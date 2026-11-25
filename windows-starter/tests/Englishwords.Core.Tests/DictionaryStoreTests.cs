using Englishwords.Core.Dictionary;
using Englishwords.Core.Lookup;
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

        // 屈折还原：abandoning -> abandon
        var abandoning = store.Lookup("abandoning");
        Assert.Null(abandoning.Error);
        Assert.NotNull(abandoning.Entry);
        Assert.Equal("abandon", abandoning.Entry!.Word);
        Assert.NotEmpty(abandoning.Entry.Translation);
        Assert.NotEmpty(abandoning.Entry.Tags);

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
    public void Lookup_UppercaseAndInflections_ResolveToSameResultsAsLowercase()
    {
        var (dictPath, partsPath) = LocateRepoResources();
        using var store = new DictionaryStore(dictPath, partsPath);

        // 入口统一小写化：大写输入必须与 macOS 版一致
        var upper = store.Lookup("UNBELIEVABLE");
        Assert.Null(upper.Error);
        Assert.NotNull(upper.Entry);
        Assert.Equal("unbelievable", upper.Entry!.Word);

        var upperFounded = store.Lookup("FOUNDED");
        Assert.Null(upperFounded.Error);
        Assert.NotNull(upperFounded.Entry);
        Assert.Equal("found", upperFounded.Entry!.Word);

        // 屈折还原回归：founded → found、roses → rose、wounds → wound
        Assert.Equal("found", store.GetLemma("founded"));
        Assert.Equal("rose", store.GetLemma("roses"));
        Assert.Equal("wound", store.GetLemma("wounds"));

        // 大写词素查询与词素库缺失时均不应抛异常
        Assert.NotNull(store.GetMorphology("UNBELIEVABLE"));
        using var missingParts = new DictionaryStore(dictPath, null);
        Assert.Null(missingParts.GetMorphology("unbelievable"));
    }

    [Fact]
    public void Lookup_ProductionResourcesPreserveReadingsPhrasesAndRootIdentity()
    {
        var (dictionary, parts) = LocateRepoResources();
        using var store = new DictionaryStore(dictionary, parts);
        Assert.Contains("有叶形装饰", store.Lookup("foiled").Entry!.Translation);
        Assert.Equal(["foil 的过去式／过去分词 · 挫败、阻止"], store.ReadingHints("foiled", "foiled"));
        var sentence = "Let me walk you through what actually happened.";
        Assert.Equal("walk you through · 带某人逐步了解", store.FindPhrase(new LookupContext(sentence, 16, 7)));
        var punctuation = new LookupContext("I will walk you through.", 16, 8);
        Assert.Equal("through", punctuation.Selected);
        Assert.Equal("walk you through · 带某人逐步了解", store.FindPhrase(punctuation));
        Assert.Null(store.FindPhrase(new LookupContext("I walk to school.", 2, 4)));
        var root = store.GetMorphology("abduct")!.Segments.Last().PartId!.Value;
        Assert.Equal(3, store.RelatedWords(root, "abduct").Count);
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
