using Englishwords.Core.Lookup;
using Xunit;

namespace Englishwords.Core.Tests;

public sealed class TextFilterTests
{
    [Fact]
    public void Classify_HandlesWordsSentencesAndRejections()
    {
        var word = Assert.IsType<TextClassification.Word>(TextFilter.Classify("unbelievable!"));
        Assert.Equal("unbelievable", word.Value);

        var possessive = Assert.IsType<TextClassification.Word>(TextFilter.Classify("Apple's"));
        Assert.Equal("apple", possessive.Value);

        var sentence = Assert.IsType<TextClassification.Sentence>(TextFilter.Classify("The quick brown fox."));
        Assert.Equal("The quick brown fox.", sentence.Value);

        Assert.Equal(RejectReason.Code, Assert.IsType<TextClassification.Rejected>(TextFilter.Classify("const x = 1;")).Reason);
        Assert.Equal(RejectReason.Code, Assert.IsType<TextClassification.Rejected>(TextFilter.Classify("foo.bar(baz)")).Reason);
        Assert.Equal(RejectReason.Url, Assert.IsType<TextClassification.Rejected>(TextFilter.Classify("https://example.com")).Reason);
        Assert.Equal(RejectReason.UnsupportedScript, Assert.IsType<TextClassification.Rejected>(TextFilter.Classify("中文测试")).Reason);
    }
}
