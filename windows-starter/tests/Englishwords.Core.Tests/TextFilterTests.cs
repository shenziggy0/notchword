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

    [Fact]
    public void Classify_KeepsSentencesWithDigitsAndPercentAsSentence()
    {
        // 不能再用「非单词字符」把数字/百分号裁掉，否则会误判成 off / chapter
        var percent = Assert.IsType<TextClassification.Sentence>(TextFilter.Classify("50% off"));
        Assert.Equal("50% off", percent.Value);

        var numbered = Assert.IsType<TextClassification.Sentence>(TextFilter.Classify("Chapter 3"));
        Assert.Equal("Chapter 3", numbered.Value);
    }

    [Fact]
    public void Classify_HandlesCjkBracketsPluralParensAndNfdAccents()
    {
        // CJK 标点区不能当成「不支持的语言」
        var bracketed = Assert.IsType<TextClassification.Word>(TextFilter.Classify("「serendipity」"));
        Assert.Equal("serendipity", bracketed.Value);

        // 英文单复数括号写法是单词，不是函数调用代码
        var plural = Assert.IsType<TextClassification.Word>(TextFilter.Classify("item(s)"));
        Assert.Equal("item", plural.Value);

        // NFD 组合变音符必须保留
        var nfd = Assert.IsType<TextClassification.Word>(TextFilter.Classify("nai\u0308ve"));
        Assert.Equal("nai\u0308ve", nfd.Value);
    }
}
