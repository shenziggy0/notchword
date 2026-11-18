using Microsoft.Data.Sqlite;

namespace Englishwords.Core.Dictionary;

/// <summary>
/// 内置词库与词素库只读访问器。
/// <para>
/// 严格区分正常未命中（返回 <c>Entry == null</c>）与数据库故障（返回 <see cref="DictionaryException"/>）。
/// 所有 SQLite 访问通过串行锁保护，确保线程安全。
/// </para>
/// </summary>
public sealed class DictionaryStore : IDisposable
{
    private readonly SqliteConnection? _db;
    private readonly SqliteConnection? _partsDb;
    private readonly DictionaryException? _openError;
    private readonly DictionaryException? _partsError;

    private readonly object _sync = new();
    private readonly Dictionary<int, Morpheme> _parts = new();
    private readonly Dictionary<string, Morphology> _morphologyCache = new(StringComparer.Ordinal);
    private bool _partsLoaded;

    public DictionaryStore(string? dictionaryPath, string? wordpartsPath)
    {
        if (string.IsNullOrWhiteSpace(dictionaryPath) || !File.Exists(dictionaryPath))
        {
            _openError = new DictionaryException(DictionaryErrorKind.Unavailable, "未找到 dictionary.sqlite");
        }
        else
        {
            (_db, _openError) = OpenReadOnly(dictionaryPath, ["words", "forms"]);
        }

        if (string.IsNullOrWhiteSpace(wordpartsPath) || !File.Exists(wordpartsPath))
        {
            _partsError = new DictionaryException(DictionaryErrorKind.Unavailable, "未找到 wordparts.sqlite");
        }
        else
        {
            (_partsDb, _partsError) = OpenReadOnly(wordpartsPath, ["parts", "words"]);
        }
    }

    /// <summary>
    /// 同步查询单词释义。
    /// </summary>
    public DictionaryLookupOutcome Lookup(string word)
    {
        lock (_sync)
        {
            try
            {
                return DictionaryLookupOutcome.Success(FindEntry(word));
            }
            catch (DictionaryException ex)
            {
                return DictionaryLookupOutcome.Failure(ex);
            }
            catch (Exception ex)
            {
                return DictionaryLookupOutcome.Failure(new DictionaryException(DictionaryErrorKind.Query, ex.Message));
            }
        }
    }

    /// <summary>
    /// 异步查询单词释义。
    /// </summary>
    public Task<DictionaryLookupOutcome> LookupAsync(string word, CancellationToken cancellationToken = default)
        => Task.Run(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Lookup(word);
        }, cancellationToken);

    /// <summary>
    /// 词素补充查询。缺失或故障时返回 <c>null</c>，不阻断主释义展示。
    /// </summary>
    public Morphology? GetMorphology(string word)
    {
        lock (_sync)
        {
            if (_morphologyCache.TryGetValue(word, out var cached))
            {
                return cached;
            }

            var resolved = ResolveMorphology(word);
            if (resolved is not null)
            {
                _morphologyCache[word] = resolved;
            }
            return resolved;
        }
    }

    /// <summary>
    /// 异步查询词素拆解。
    /// </summary>
    public Task<Morphology?> GetMorphologyAsync(string word, CancellationToken cancellationToken = default)
        => Task.Run(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            return GetMorphology(word);
        }, cancellationToken);

    /// <summary>
    /// 屈折还原：<c>abandoned</c> → <c>abandon</c>。未查到时返回 <c>null</c>。
    /// </summary>
    public string? GetLemma(string form)
    {
        lock (_sync)
        {
            if (_db is null || _openError is not null)
            {
                return null;
            }

            try
            {
                return QuerySingleString(_db, "SELECT lemma FROM forms WHERE form = $form LIMIT 1", "$form", form);
            }
            catch
            {
                return null;
            }
        }
    }

    private Entry? FindEntry(string word)
    {
        if (_openError is not null) throw _openError;
        if (_db is null) throw new DictionaryException(DictionaryErrorKind.Unavailable, "词库未打开");

        var headword = QuerySingleString(_db, "SELECT lemma FROM forms WHERE form = $form LIMIT 1", "$form", word) ?? word;
        return QueryWord(_db, headword);
    }

    private static Entry? QueryWord(SqliteConnection db, string headword)
    {
        using var cmd = db.CreateCommand();
        cmd.CommandText = "SELECT word, phonetic, translation, pos, tag FROM words WHERE word = $word LIMIT 1";
        cmd.Parameters.AddWithValue("$word", headword);

        using var reader = cmd.ExecuteReader();
        if (!reader.Read()) return null;

        var wordText = reader.IsDBNull(0) ? string.Empty : reader.GetString(0);
        var phonetic = reader.IsDBNull(1) ? string.Empty : reader.GetString(1);
        var translation = reader.IsDBNull(2) ? string.Empty : reader.GetString(2);
        var pos = reader.IsDBNull(3) ? string.Empty : reader.GetString(3);
        var rawTags = reader.IsDBNull(4) ? string.Empty : reader.GetString(4);

        var tags = rawTags
            .Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Select(PrettyTag)
            .ToArray();

        return new Entry
        {
            Word = wordText,
            Phonetic = phonetic,
            Translation = translation,
            Pos = pos,
            Tags = tags,
            Dictionary = "内置词库"
        };
    }

    private Morphology? ResolveMorphology(string word)
    {
        if (_partsDb is null || _partsError is not null) return null;

        var exact = QueryMorphologyExact(word);
        if (exact is not null) return exact;

        var lemma = GetLemma(word);
        if (!string.IsNullOrEmpty(lemma) && !string.Equals(lemma, word, StringComparison.Ordinal))
        {
            return QueryMorphologyExact(lemma);
        }

        return null;
    }

    private Morphology? QueryMorphologyExact(string word)
    {
        if (_partsDb is null) return null;

        using var cmd = _partsDb.CreateCommand();
        cmd.CommandText = "SELECT segments, origin FROM words WHERE word = $word LIMIT 1";
        cmd.Parameters.AddWithValue("$word", word);

        using var reader = cmd.ExecuteReader();
        if (!reader.Read() || reader.IsDBNull(0)) return null;

        var rawSegments = reader.GetString(0);
        var origin = reader.IsDBNull(1) ? string.Empty : reader.GetString(1);

        if (!EnsurePartsLoaded()) return null;

        var segments = ParseSegments(rawSegments, id => _parts.TryGetValue(id, out var m) ? m : null);
        return segments.Count == 0 ? null : new Morphology(segments, origin);
    }

    private bool EnsurePartsLoaded()
    {
        if (_partsLoaded) return _parts.Count > 0;
        if (_partsDb is null) return false;

        using var cmd = _partsDb.CreateCommand();
        cmd.CommandText = "SELECT id, role, label, zh, en, lemma FROM parts";
        using var reader = cmd.ExecuteReader();

        while (reader.Read())
        {
            var id = reader.GetInt32(0);
            var role = reader.IsDBNull(1) ? string.Empty : reader.GetString(1);
            var label = reader.IsDBNull(2) ? string.Empty : reader.GetString(2);
            var zh = reader.IsDBNull(3) ? string.Empty : reader.GetString(3);
            var en = reader.IsDBNull(4) ? string.Empty : reader.GetString(4);
            var lemma = reader.IsDBNull(5) ? string.Empty : reader.GetString(5);
            _parts[id] = new Morpheme(role, label, zh, en, lemma);
        }

        _partsLoaded = true;
        return _parts.Count > 0;
    }

    private static (SqliteConnection? Connection, DictionaryException? Error) OpenReadOnly(
        string path,
        IEnumerable<string> requiredTables)
    {
        try
        {
            var builder = new SqliteConnectionStringBuilder
            {
                DataSource = path,
                Mode = SqliteOpenMode.ReadOnly,
                Pooling = false
            };
            var conn = new SqliteConnection(builder.ToString());
            conn.Open();

            foreach (var table in requiredTables)
            {
                if (!TableExists(conn, table))
                {
                    conn.Dispose();
                    return (null, new DictionaryException(DictionaryErrorKind.Schema, $"缺少表 {table}"));
                }
            }

            return (conn, null);
        }
        catch (Exception ex)
        {
            return (null, new DictionaryException(DictionaryErrorKind.Unavailable, ex.Message));
        }
    }

    private static bool TableExists(SqliteConnection conn, string tableName)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = $name LIMIT 1";
        cmd.Parameters.AddWithValue("$name", tableName);
        return cmd.ExecuteScalar() is not null;
    }

    private static string? QuerySingleString(SqliteConnection conn, string sql, string paramName, string paramValue)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = sql;
        cmd.Parameters.AddWithValue(paramName, paramValue);
        return cmd.ExecuteScalar() as string;
    }

    /// <summary>
    /// 解析 <c>"un:12 believ:34 able:56"</c> 格式的语素编码。
    /// </summary>
    public static IReadOnlyList<Segment> ParseSegments(string raw, Func<int, Morpheme?> resolve)
    {
        var result = new List<Segment>();
        foreach (var piece in raw.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            var colonIndex = piece.IndexOf(':');
            if (colonIndex < 0) continue;

            var spelling = piece[..colonIndex].Trim();
            if (!int.TryParse(piece[(colonIndex + 1)..], out var id)) continue;

            var morpheme = resolve(id);
            if (morpheme is null) continue;

            result.Add(new Segment(
                morpheme.Role,
                string.IsNullOrEmpty(spelling) ? morpheme.Label : spelling,
                morpheme.Zh));
        }
        return result;
    }

    /// <summary>
    /// 将考试标签缩写转为中文展示标签。
    /// </summary>
    public static string PrettyTag(string tag) => tag switch
    {
        "zk" => "中考",
        "gk" => "高考",
        "cet4" => "四级",
        "cet6" => "六级",
        "ky" => "考研",
        "toefl" => "托福",
        "ielts" => "雅思",
        "gre" => "GRE",
        _ => tag.ToUpperInvariant()
    };

    public void Dispose()
    {
        _db?.Dispose();
        _partsDb?.Dispose();
    }
}
