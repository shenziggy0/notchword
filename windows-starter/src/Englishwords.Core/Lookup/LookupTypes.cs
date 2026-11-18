using Englishwords.Core.Dictionary;

namespace Englishwords.Core.Lookup;

public enum LookupTrigger
{
    Hotkey,
    Translate,
    Menu,
    Clipboard,
    Selection,
    Region,
    Notebook
}

public static class LookupTriggerExtensions
{
    public static string ToRawValue(this LookupTrigger trigger) => trigger switch
    {
        LookupTrigger.Hotkey => "hotkey",
        LookupTrigger.Translate => "translate",
        LookupTrigger.Menu => "menu",
        LookupTrigger.Clipboard => "clipboard",
        LookupTrigger.Selection => "selection",
        LookupTrigger.Region => "region",
        LookupTrigger.Notebook => "notebook",
        _ => "hotkey"
    };

    public static bool IsPassive(this LookupTrigger trigger) => trigger == LookupTrigger.Selection;
}

public enum LookupMode
{
    /// <summary>
    /// 内置词库 / 导入 StarDict → 联网翻译。
    /// </summary>
    Lookup,
    /// <summary>
    /// 跳过词典，直接翻译。
    /// </summary>
    Translate
}

public sealed record LookupRequest(
    string Text,
    LookupTrigger Trigger,
    LookupMode Mode = LookupMode.Lookup,
    string? Note = null,
    int AnchorX = 0,
    int AnchorY = 0,
    bool HasAnchor = false);

/// <summary>
/// 面板展示用的标准化查询结果。
/// </summary>
public sealed class LookupResult
{
    public required string Input { get; init; }
    public required TextKind Kind { get; init; }
    public required string Title { get; init; }
    public string Phonetic { get; init; } = string.Empty;
    public string Pos { get; init; } = string.Empty;
    public IReadOnlyList<string> Tags { get; init; } = [];
    public required string Body { get; set; }
    public string? OriginalText { get; init; }
    public IReadOnlyList<Segment> Segments { get; init; } = [];
    public string Origin { get; init; } = string.Empty;
    public required string Source { get; init; }
    public string? Note { get; set; }

    public string? NotebookWord
    {
        get
        {
            if (Kind != TextKind.Word) return null;
            var word = TextFilter.NormalizeWord(string.IsNullOrEmpty(Title) ? Input : Title);
            return string.IsNullOrEmpty(word) ? null : word;
        }
    }

    public static LookupResult FromWord(string input, Entry entry, Morphology? morphology, string? note) => new()
    {
        Input = input,
        Kind = TextKind.Word,
        Title = entry.Word,
        Phonetic = entry.Phonetic,
        Pos = entry.Pos,
        Tags = entry.Tags,
        Body = entry.Translation,
        OriginalText = null,
        Segments = morphology?.Segments ?? [],
        Origin = morphology?.Origin ?? string.Empty,
        Source = entry.Dictionary,
        Note = note
    };

    public static LookupResult FromTranslation(
        string text,
        TextKind kind,
        string translation,
        string provider,
        Morphology? morphology = null,
        string? note = null) => new()
    {
        Input = text,
        Kind = kind,
        Title = kind == TextKind.Word ? text : string.Empty,
        Body = translation,
        OriginalText = kind == TextKind.Sentence ? text : null,
        Segments = morphology?.Segments ?? [],
        Origin = morphology?.Origin ?? string.Empty,
        Source = provider,
        Note = note
    };
}

public abstract record LookupState(LookupRequest Request)
{
    public sealed record Loading(LookupRequest Request) : LookupState(Request);
    public sealed record Result(LookupRequest Request, LookupResult Value) : LookupState(Request);
    public sealed record Failure(LookupRequest Request, string Message) : LookupState(Request);
}
