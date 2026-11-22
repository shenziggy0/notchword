using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Englishwords.Core.Lookup;

public enum TextKind
{
    Word,
    Sentence
}

public enum RejectReason
{
    Empty,
    TooLong,
    Url,
    Email,
    Domain,
    Code,
    NoLetters,
    UnsupportedScript
}

public static class RejectReasonExtensions
{
    /// <summary>
    /// 显式入口给用户的友好提示；被动入口（如划词）遇到拒绝则静默丢弃。
    /// </summary>
    public static string ToMessage(this RejectReason reason) => reason switch
    {
        RejectReason.Empty => "没有取到文字。\n先选中一个英文单词或短句，再试一次。",
        RejectReason.TooLong => "选中的内容太长，只支持单词或短句。",
        RejectReason.Url => "这是一个网址，不做翻译。",
        RejectReason.Email => "这是一个邮箱地址，不做翻译。",
        RejectReason.Domain => "这是一个域名，不做翻译。",
        RejectReason.Code => "选中的内容看起来是代码，不做翻译。",
        RejectReason.NoLetters => "没有找到英文内容。",
        RejectReason.UnsupportedScript => "目前只支持英文查词与英译中。",
        _ => "无法处理选中的内容。"
    };
}

public abstract record TextClassification
{
    public sealed record Word(string Value) : TextClassification;
    public sealed record Sentence(string Value) : TextClassification;
    public sealed record Rejected(RejectReason Reason) : TextClassification;
}

/// <summary>
/// 将采集到的原始文本分类为「单词 / 短句 / 拒绝」。
/// <para>
/// 原文永远保留给短句翻译，仅在识别为单词时才规范化词头。
/// </para>
/// </summary>
public static partial class TextFilter
{
    public const int MaxSentenceLength = 300;

    [GeneratedRegex(@"^[a-z][a-z0-9+.\-]*://", RegexOptions.CultureInvariant)]
    private static partial Regex UrlSchemeRegex();

    [GeneratedRegex(@"^[^\s@]+@[^\s@]+\.[a-z]{2,}$", RegexOptions.CultureInvariant)]
    private static partial Regex EmailRegex();

    [GeneratedRegex(@"^[a-z0-9\-]+(\.[a-z0-9\-]+)*\.(com|org|net|io|dev|app|co|cn|edu|gov|me|ai|xyz|info)(/\S*)?$", RegexOptions.CultureInvariant)]
    private static partial Regex DomainRegex();

    [GeneratedRegex(@"^(?:let|const|var)\s+[A-Za-z_$]\w*\s*(?::[^=\n]+)?\s*=", RegexOptions.CultureInvariant)]
    private static partial Regex CodeDeclarationRegex();

    [GeneratedRegex(@"^[A-Za-z_$][\w$.]*\([^()\n]*\)\s*;?$", RegexOptions.CultureInvariant)]
    private static partial Regex CodeCallRegex();

    /// <summary>
    /// 英文单复数括号写法：<c>item(s)</c> / <c>box(es)</c> / <c>city(ies)</c>。
    /// 它们是真实单词，不能当作函数调用代码拦截。
    /// </summary>
    [GeneratedRegex(@"^[A-Za-z][\w'’\-]*\((?:s|es|ies)\)$", RegexOptions.CultureInvariant)]
    private static partial Regex PluralSuffixRegex();

    /// <summary>
    /// 允许被剥离的首尾包裹标点/引号/括号。
    /// </summary>
    private const string EdgePunctuation = "'\"“”‘’()[]{},.!?;:「」『』【】《》";

    public static TextClassification Classify(string? raw)
    {
        var text = (raw ?? string.Empty).Trim();
        if (text.Length == 0) return new TextClassification.Rejected(RejectReason.Empty);
        if (text.Length > MaxSentenceLength) return new TextClassification.Rejected(RejectReason.TooLong);
        if (ContainsUnsupportedScript(text)) return new TextClassification.Rejected(RejectReason.UnsupportedScript);

        var lower = text.ToLowerInvariant();
        if (UrlSchemeRegex().IsMatch(lower)) return new TextClassification.Rejected(RejectReason.Url);
        if (EmailRegex().IsMatch(lower)) return new TextClassification.Rejected(RejectReason.Email);
        if (DomainRegex().IsMatch(lower)) return new TextClassification.Rejected(RejectReason.Domain);

        if (text.StartsWith("```", StringComparison.Ordinal) ||
            CodeDeclarationRegex().IsMatch(text) ||
            (!PluralSuffixRegex().IsMatch(text) && CodeCallRegex().IsMatch(text)))
        {
            return new TextClassification.Rejected(RejectReason.Code);
        }

        if (IsSingleWord(text))
        {
            var word = NormalizeWord(text);
            return string.IsNullOrEmpty(word)
                ? new TextClassification.Rejected(RejectReason.NoLetters)
                : new TextClassification.Word(word);
        }

        if (!ContainsLatinLetter(text)) return new TextClassification.Rejected(RejectReason.NoLetters);
        return new TextClassification.Sentence(text);
    }

    public static bool IsSingleWord(string text)
    {
        // 只剥离首尾常见标点/引号/括号，不再用「非单词字符」扫描裁剪正文，
        // 否则 "50% off"、"Chapter 3" 会被裁剪成 "off" / "chapter" 误判为单词。
        var candidate = text.Trim();
        while (candidate.Length > 0)
        {
            if (PluralSuffixRegex().IsMatch(candidate)) return true;
            if (AllWordRunes(candidate)) return true;

            if (EdgePunctuation.Contains(candidate[0]))
            {
                candidate = candidate[1..];
                continue;
            }

            if (EdgePunctuation.Contains(candidate[^1]))
            {
                candidate = candidate[..^1];
                continue;
            }

            return false;
        }

        return false;
    }

    /// <summary>
    /// 单词规范化：小写、去除所有格后缀与两端标点。短句不应经过此方法。
    /// </summary>
    public static string NormalizeWord(string raw)
    {
        var best = new StringBuilder();
        var current = new StringBuilder();

        void Consider()
        {
            if (current.Length > best.Length)
            {
                var candidate = current.ToString();
                if (ContainsLatinLetter(candidate))
                {
                    best.Clear().Append(candidate);
                }
            }
            current.Clear();
        }

        foreach (var rune in raw.EnumerateRunes())
        {
            if (IsWordChar(rune))
            {
                current.Append(rune.ToString());
            }
            else
            {
                Consider();
            }
        }
        Consider();

        var word = best.ToString().ToLowerInvariant();
        if (word.EndsWith("'s", StringComparison.Ordinal) || word.EndsWith("’s", StringComparison.Ordinal))
        {
            word = word[..^2];
        }

        return word.Trim('\'', '’', '-');
    }

    /// <summary>
    /// 判断整段文本是否全部由「单词字符」组成（按 <see cref="Rune"/> 逐个判定）。
    /// </summary>
    private static bool AllWordRunes(string text)
    {
        var hasRune = false;
        foreach (var rune in text.EnumerateRunes())
        {
            hasRune = true;
            if (!IsWordChar(rune)) return false;
        }
        return hasRune;
    }

    /// <summary>
    /// 单词字符：字母、连字符、撇号，以及组合用变音符（如 NFD 形式的 <c>nai\u0308ve</c>）。
    /// </summary>
    private static bool IsWordChar(Rune rune)
    {
        if (Rune.IsLetter(rune)) return true;
        if (rune.Value is '-' or '\'' or '’') return true;
        return Rune.GetUnicodeCategory(rune) == UnicodeCategory.NonSpacingMark;
    }

    private static bool ContainsLatinLetter(string text)
    {
        foreach (var ch in text)
        {
            if (ch is (>= 'A' and <= 'Z') or (>= 'a' and <= 'z')) return true;
        }
        return false;
    }

    /// <summary>
    /// 检测中日韩统一表意文字、假名、注音与韩文音节：当前版本只处理英译中。
    /// </summary>
    private static bool ContainsUnsupportedScript(string text)
    {
        foreach (var rune in text.EnumerateRunes())
        {
            var v = rune.Value;
            // 跳过 U+3000..U+303F（CJK 标点，如「」『』【】）：全角括号不应把英文单词判为不支持的语言。
            if (v is (>= 0x2E80 and <= 0x2FFF)
                or (>= 0x3040 and <= 0x9FFF)
                or (>= 0x3100 and <= 0x312F)
                or (>= 0x31A0 and <= 0x31BF)
                or (>= 0xAC00 and <= 0xD7AF)
                or (>= 0xF900 and <= 0xFAFF))
            {
                return true;
            }
        }
        return false;
    }
}
