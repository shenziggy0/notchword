namespace Englishwords.Core.Dictionary;

/// <summary>
/// 词根词缀的一个片段。
/// <para>
/// <see cref="Label"/> 是该词中的实际拼写（如 <c>believ</c>），而非语素词典形态（<c>believe</c>）。
/// </para>
/// </summary>
public sealed record Segment(string Role, string Label, string Gloss);

/// <summary>
/// 词素元数据（对应 <c>wordparts.sqlite</c> 中 <c>parts</c> 表的一行）。
/// </summary>
public sealed record Morpheme(string Role, string Label, string Zh, string En, string Lemma);

/// <summary>
/// 一条词典释义。
/// </summary>
public sealed class Entry
{
    public required string Word { get; init; }
    public string Phonetic { get; set; } = string.Empty;
    public string Pos { get; set; } = string.Empty;
    public string Translation { get; set; } = string.Empty;
    public IReadOnlyList<string> Tags { get; set; } = [];
    public string Dictionary { get; set; } = string.Empty;
}

/// <summary>
/// 词素补充信息：与释义来源无关，命中其一即可展示。
/// </summary>
public sealed record Morphology(IReadOnlyList<Segment> Segments, string Origin);

public enum DictionaryErrorKind
{
    Unavailable,
    Schema,
    Query
}

/// <summary>
/// 词库访问异常：用于严格区分“正常未命中”与“词库故障”。
/// </summary>
public sealed class DictionaryException : Exception
{
    public DictionaryErrorKind Kind { get; }

    public DictionaryException(DictionaryErrorKind kind, string detail)
        : base(FormatMessage(kind, detail))
    {
        Kind = kind;
    }

    private static string FormatMessage(DictionaryErrorKind kind, string detail) => kind switch
    {
        DictionaryErrorKind.Unavailable => $"词库不可用：{detail}",
        DictionaryErrorKind.Schema => $"词库结构不符合约定：{detail}",
        DictionaryErrorKind.Query => $"词库查询失败：{detail}",
        _ => detail
    };
}

/// <summary>
/// 内置词库或导入 StarDict 词典的查找结果包装。
/// </summary>
public sealed record DictionaryLookupOutcome(Entry? Entry, DictionaryException? Error)
{
    public static DictionaryLookupOutcome Success(Entry? entry) => new(entry, null);
    public static DictionaryLookupOutcome Failure(DictionaryException error) => new(null, error);
}
