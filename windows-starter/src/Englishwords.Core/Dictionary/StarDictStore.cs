using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Englishwords.Core.Dictionary;

public enum DictionarySourceKind
{
    Builtin,
    Stardict
}

/// <summary>
/// 词典源配置项（支持内置词库与用户导入的 StarDict 词典排序）。
/// </summary>
public sealed class DictionarySource
{
    public required string Id { get; init; }
    [JsonConverter(typeof(JsonStringEnumConverter))]
    public required DictionarySourceKind Kind { get; init; }
    public required string Name { get; init; }
    public bool Enabled { get; set; } = true;

    public static List<DictionarySource> CreateDefaults() =>
    [
        new() { Id = "builtin", Kind = DictionarySourceKind.Builtin, Name = "内置词库", Enabled = true }
    ];
}

public sealed class StarDictException(string message) : Exception($"StarDict：{message}");

/// <summary>
/// 单本 StarDict 词典解析器（支持 2.4.2 / 3.0.0、32/64 位索引偏移及 <c>.idx.gz</c> / <c>.dict.dz</c>）。
/// </summary>
internal sealed class StarDictStore
{
    private const int MaxIndexBytes = 32 * 1024 * 1024;
    private const int MaxDictBytes = 128 * 1024 * 1024;

    private readonly record struct IndexEntry(string Word, string Folded, int Offset, int Length);

    private static readonly Regex NumericEntityRegex = new(@"&#(x?)([0-9a-fA-F]+);",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public string Name { get; }
    public IReadOnlyList<string> Files { get; }
    private readonly char[] _types;
    private readonly byte[] _data;
    private readonly List<IndexEntry> _index;

    public StarDictStore(string ifoPath)
    {
        var fields = ReadMetadata(ifoPath);
        var (sequence, offsetBits) = ValidateFields(fields);
        var name = fields["bookname"];

        var dir = Path.GetDirectoryName(ifoPath) ?? ".";
        var stem = Path.GetFileNameWithoutExtension(ifoPath);
        var idxPath = FindResource(dir, stem, [".idx", ".idx.gz"]);
        var dictPath = FindResource(dir, stem, [".dict", ".dict.dz"]);
        var words = int.Parse(fields["wordcount"], CultureInfo.InvariantCulture);
        var idxSize = int.Parse(fields["idxfilesize"], CultureInfo.InvariantCulture);

        var indexData = ReadData(idxPath, idxPath.EndsWith(".gz", StringComparison.OrdinalIgnoreCase), MaxIndexBytes);
        if (indexData.Length != idxSize)
        {
            throw new StarDictException("索引大小与 .ifo 不一致");
        }

        var dictData = ReadData(dictPath, dictPath.EndsWith(".dz", StringComparison.OrdinalIgnoreCase), MaxDictBytes);

        var index = new List<IndexEntry>(words);
        var pos = 0;
        var offsetBytes = offsetBits == "64" ? 8 : 4;
        while (pos < indexData.Length)
        {
            var delimiter = Array.IndexOf(indexData, (byte)0, pos);
            if (delimiter <= pos || indexData.Length - delimiter - 1 < offsetBytes + 4)
            {
                throw new StarDictException("词头或索引记录损坏");
            }

            var word = Encoding.UTF8.GetString(indexData, pos, delimiter - pos);
            pos = delimiter + 1;
            var offset = ReadBigEndian(indexData, ref pos, offsetBytes);
            var length = ReadBigEndian(indexData, ref pos, 4);

            if (offset > (ulong)dictData.Length || length > (ulong)dictData.Length - offset)
            {
                throw new StarDictException("释义偏移超出正文");
            }

            index.Add(new IndexEntry(word, word.ToLowerInvariant(), (int)offset, (int)length));
        }

        if (index.Count != words)
        {
            throw new StarDictException("词条数与 .ifo 不一致");
        }

        index.Sort(static (a, b) =>
        {
            var cmp = string.CompareOrdinal(a.Folded, b.Folded);
            return cmp != 0 ? cmp : string.CompareOrdinal(a.Word, b.Word);
        });

        Name = name;
        Files = [ifoPath, idxPath, dictPath];
        _types = sequence.ToCharArray();
        _data = dictData;
        _index = index;
    }

    public Entry? Lookup(string word)
    {
        var query = word.ToLowerInvariant();
        var low = 0;
        var high = _index.Count;
        while (low < high)
        {
            var mid = (low + high) / 2;
            if (string.CompareOrdinal(_index[mid].Folded, query) < 0)
                low = mid + 1;
            else
                high = mid;
        }

        if (low >= _index.Count || !string.Equals(_index[low].Folded, query, StringComparison.Ordinal))
        {
            return null;
        }

        var first = _index[low];
        var translations = new List<string>();
        var phonetic = string.Empty;

        for (var i = low; i < _index.Count && string.Equals(_index[i].Folded, query, StringComparison.Ordinal); i++)
        {
            var hit = _index[i];
            var start = hit.Offset;
            var bound = hit.Offset + hit.Length;

            for (var t = 0; t < _types.Length; t++)
            {
                var type = _types[t];
                int end;
                if (t == _types.Length - 1)
                {
                    end = bound;
                }
                else
                {
                    var delim = Array.IndexOf(_data, (byte)0, start, bound - start);
                    if (delim < 0) throw new StarDictException("释义字段缺少分隔符");
                    end = delim;
                }

                var rawLen = end - start;
                if (rawLen > 0 && _data[end - 1] == 0) rawLen--;

                var text = Encoding.UTF8.GetString(_data, start, rawLen);
                start = end + 1;

                if (type == 't')
                {
                    if (string.IsNullOrEmpty(phonetic)) phonetic = text;
                }
                else
                {
                    var value = type == 'm' ? text : StripMarkup(text);
                    var trimmed = value.Trim();
                    if (!string.IsNullOrEmpty(trimmed) && !translations.Contains(trimmed))
                    {
                        translations.Add(trimmed);
                    }
                }
            }
        }

        if (translations.Count == 0) return null;

        return new Entry
        {
            Word = first.Word,
            Phonetic = phonetic,
            Translation = string.Join("\n", translations),
            Dictionary = Name
        };
    }

    /// <summary>
    /// 轻量校验：只读 <c>.ifo</c> 元数据，不加载索引与正文（供导入前的校验复用）。
    /// </summary>
    internal static string ValidateInfo(string ifoPath)
    {
        var fields = ReadMetadata(ifoPath);
        ValidateFields(fields);
        return fields["bookname"];
    }

    /// <summary>
    /// 列出该词典依赖的 <c>.ifo</c> / <c>.idx(.gz)</c> / <c>.dict(.dz)</c> 文件。
    /// </summary>
    internal static string[] ListFiles(string ifoPath)
    {
        var dir = Path.GetDirectoryName(ifoPath) ?? ".";
        var stem = Path.GetFileNameWithoutExtension(ifoPath);
        return
        [
            ifoPath,
            FindResource(dir, stem, [".idx", ".idx.gz"]),
            FindResource(dir, stem, [".dict", ".dict.dz"])
        ];
    }

    /// <summary>
    /// 校验 <c>.ifo</c> 必填字段，返回类型序列与索引偏移位数。
    /// </summary>
    private static (string Sequence, string OffsetBits) ValidateFields(Dictionary<string, string> fields)
    {
        if (!fields.TryGetValue("bookname", out var name) || string.IsNullOrEmpty(name) ||
            !fields.TryGetValue("wordcount", out var wordCountStr) || !int.TryParse(wordCountStr, out var words) || words <= 0 ||
            !fields.TryGetValue("idxfilesize", out var idxSizeStr) || !int.TryParse(idxSizeStr, out var idxSize) || idxSize <= 0)
        {
            throw new StarDictException("缺少词典名称、词条数或索引大小");
        }

        if (!fields.TryGetValue("version", out var version) || (version != "2.4.2" && version != "3.0.0"))
        {
            throw new StarDictException("只支持 2.4.2 或 3.0.0");
        }

        var offsetBits = fields.GetValueOrDefault("idxoffsetbits", "32");
        if (offsetBits != "32" && !(version == "3.0.0" && offsetBits == "64"))
        {
            throw new StarDictException("不支持的索引偏移格式");
        }

        if (!fields.TryGetValue("sametypesequence", out var sequence) || string.IsNullOrEmpty(sequence) ||
            !sequence.All(c => c is 'm' or 't' or 'h' or 'x'))
        {
            throw new StarDictException("只支持声明了 m、t、h 或 x 文本类型的词典");
        }

        return (sequence, offsetBits);
    }

    private static string StripMarkup(string text)
    {
        var result = Regex.Replace(text, @"<(script|style)\b[^>]*>.*?</\1\s*>", string.Empty,
            RegexOptions.IgnoreCase | RegexOptions.Singleline);
        // XDXF 块级结束标签也要换成换行，否则多个义项会粘成一长串。
        result = Regex.Replace(result, @"<br\b[^>]*>|</(?:p|div|li|k|tr|dtrn|def|ex)\s*>", "\n", RegexOptions.IgnoreCase);
        result = Regex.Replace(result, @"<[^>]+>", string.Empty);

        result = result
            .Replace("&nbsp;", " ", StringComparison.Ordinal)
            .Replace("&gt;", ">", StringComparison.Ordinal)
            .Replace("&lt;", "<", StringComparison.Ordinal)
            .Replace("&quot;", "\"", StringComparison.Ordinal)
            .Replace("&apos;", "'", StringComparison.Ordinal)
            .Replace("&#39;", "'", StringComparison.Ordinal)
            .Replace("&amp;", "&", StringComparison.Ordinal);

        // 十进制 / 十六进制数字实体（如 &#8217; / &#x2019;）。
        return NumericEntityRegex.Replace(result, DecodeNumericEntity);
    }

    private static string DecodeNumericEntity(Match match)
    {
        var digits = match.Groups[2].Value;
        var value = -1;
        if (match.Groups[1].Value.Length > 0)
        {
            if (int.TryParse(digits, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var hex)) value = hex;
        }
        else if (int.TryParse(digits, NumberStyles.Integer, CultureInfo.InvariantCulture, out var dec))
        {
            value = dec;
        }

        if (value <= 0 || value > 0x10FFFF) return match.Value;
        return char.ConvertFromUtf32(value);
    }

    private static Dictionary<string, string> ReadMetadata(string ifoPath)
    {
        var data = ReadData(ifoPath, compressed: false, MaxIndexBytes);
        var lines = Encoding.UTF8.GetString(data).Split(["\r\n", "\n", "\r"], StringSplitOptions.None);
        if (lines.Length == 0 || lines[0].TrimStart('\uFEFF').Trim() != "StarDict's dict ifo file")
        {
            throw new StarDictException(".ifo 文件头无效");
        }

        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var line in lines.Skip(1))
        {
            var eq = line.IndexOf('=');
            if (eq > 0)
            {
                result[line[..eq]] = line[(eq + 1)..].Trim();
            }
        }
        return result;
    }

    private static string FindResource(string dir, string stem, string[] extensions)
    {
        foreach (var ext in extensions)
        {
            var candidate = Path.Combine(dir, stem + ext);
            if (File.Exists(candidate)) return candidate;
        }
        throw new StarDictException($"缺少 {string.Join(" / ", extensions)} 文件");
    }

    private static ulong ReadBigEndian(byte[] data, ref int position, int bytes)
    {
        ulong result = 0;
        for (var i = 0; i < bytes; i++)
        {
            result = (result << 8) | data[position++];
        }
        return result;
    }

    private static byte[] ReadData(string path, bool compressed, int limit)
    {
        var info = new FileInfo(path);
        if (!info.Exists || info.Attributes.HasFlag(FileAttributes.ReparsePoint))
        {
            throw new StarDictException($"{Path.GetFileName(path)} 无法读取");
        }

        if (!compressed)
        {
            if (info.Length > limit)
            {
                throw new StarDictException($"{Path.GetFileName(path)} 超出大小限制");
            }
            return File.ReadAllBytes(path);
        }

        using var fs = File.OpenRead(path);
        using var gzip = new GZipStream(fs, CompressionMode.Decompress);
        using var ms = new MemoryStream();
        var buffer = new byte[64 * 1024];
        int read;
        while ((read = gzip.Read(buffer, 0, buffer.Length)) > 0)
        {
            if (ms.Length + read > limit)
            {
                throw new StarDictException("解压后超出大小限制");
            }
            ms.Write(buffer, 0, read);
        }
        return ms.ToArray();
    }
}

/// <summary>
/// 用户导入 StarDict 词典库管理器。
/// </summary>
public sealed class StarDictLibrary
{
    private readonly string _directory;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly Dictionary<string, StarDictStore> _loaded = new(StringComparer.Ordinal);

    public StarDictLibrary(string directory)
    {
        _directory = directory;
    }

    public async Task<DictionarySource> ImportDictionaryAsync(string selectionPath, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            // 解压、拷贝与解析全部落到后台线程，避免拿到锁后仍在 UI 线程上同步读 128MB 词典。
            return await Task.Run(() => ImportCore(selectionPath, cancellationToken), cancellationToken);
        }
        finally
        {
            _gate.Release();
        }
    }

    private DictionarySource ImportCore(string selectionPath, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        var ifo = ResolveInfoFile(selectionPath);
        // 只读 .ifo 做轻量校验，正文留到拷贝完成后只解析一次，避免大词典双份驻留内存。
        var name = StarDictStore.ValidateInfo(ifo);
        var id = Guid.NewGuid().ToString("D");
        var destination = Path.Combine(_directory, id);
        var staging = Path.Combine(_directory, "." + id);

        try
        {
            Directory.CreateDirectory(staging);
            foreach (var src in StarDictStore.ListFiles(ifo))
            {
                cancellationToken.ThrowIfCancellationRequested();
                var dest = Path.Combine(staging, Path.GetFileName(src));
                File.Copy(src, dest, overwrite: true);
            }

            Directory.Move(staging, destination);

            // 只在最终目录解析一次，不再额外保留暂存副本。
            var store = new StarDictStore(Path.Combine(destination, Path.GetFileName(ifo)));
            _loaded[id] = store;
            return new DictionarySource { Id = id, Kind = DictionarySourceKind.Stardict, Name = name, Enabled = true };
        }
        catch
        {
            if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
            if (Directory.Exists(destination)) Directory.Delete(destination, recursive: true);
            throw;
        }
    }

    public async Task<Entry?> LookupAsync(string word, DictionarySource source, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            // 首次加载会解压 .dict.dz 并建立索引，必须离开 UI 线程。
            return await Task.Run(() =>
            {
                cancellationToken.ThrowIfCancellationRequested();

                if (_loaded.TryGetValue(source.Id, out var cached))
                {
                    return cached.Lookup(word);
                }

                var dir = ResolveSourceDirectory(source);
                var store = new StarDictStore(ResolveInfoFile(dir));
                _loaded[source.Id] = store;
                return store.Lookup(word);
            }, cancellationToken);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task RemoveAsync(DictionarySource source, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            await Task.Run(() =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                var dir = ResolveSourceDirectory(source);
                _loaded.Remove(source.Id);
                if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
            }, cancellationToken);
        }
        finally
        {
            _gate.Release();
        }
    }

    private string ResolveSourceDirectory(DictionarySource source)
    {
        if (source.Kind != DictionarySourceKind.Stardict || !Guid.TryParse(source.Id, out _))
        {
            throw new StarDictException("导入词典编号无效");
        }
        return Path.Combine(_directory, source.Id);
    }

    private static string ResolveInfoFile(string selectionPath)
    {
        if (File.Exists(selectionPath) &&
            string.Equals(Path.GetExtension(selectionPath), ".ifo", StringComparison.OrdinalIgnoreCase))
        {
            return selectionPath;
        }

        if (Directory.Exists(selectionPath))
        {
            var matches = Directory.GetFiles(selectionPath, "*.ifo", SearchOption.TopDirectoryOnly);
            if (matches.Length == 1) return matches[0];
        }

        throw new StarDictException("请选择 .ifo 文件或仅包含一套字典的目录");
    }
}
