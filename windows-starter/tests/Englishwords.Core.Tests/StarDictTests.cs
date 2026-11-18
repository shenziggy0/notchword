using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;
using Englishwords.Core.Dictionary;
using Xunit;

namespace Englishwords.Core.Tests;

public sealed class StarDictTests : IDisposable
{
    private readonly string _tempDir = Path.Combine(Path.GetTempPath(), "ew-stardict-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public async Task ImportAndLookup_CompressedFiles_StripsHtmlAndFindsWord()
    {
        Directory.CreateDirectory(_tempDir);
        var sourceDir = Path.Combine(_tempDir, "source");
        var libDir = Path.Combine(_tempDir, "library");
        Directory.CreateDirectory(sourceDir);

        var dictBytes = Encoding.UTF8.GetBytes("n. <b>测试</b><br>释义");
        var wordBytes = Encoding.UTF8.GetBytes("probe");

        var idxStream = new MemoryStream();
        idxStream.Write(wordBytes);
        idxStream.WriteByte(0);
        var intBuf = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(intBuf, 0);
        idxStream.Write(intBuf);
        BinaryPrimitives.WriteUInt32BigEndian(intBuf, (uint)dictBytes.Length);
        idxStream.Write(intBuf);
        var idxBytes = idxStream.ToArray();

        var ifo = $"""
            StarDict's dict ifo file
            version=2.4.2
            bookname=Test Dict
            wordcount=1
            idxfilesize={idxBytes.Length}
            sametypesequence=h
            """;
        await File.WriteAllTextAsync(Path.Combine(sourceDir, "test.ifo"), ifo);

        await using (var fs = File.Create(Path.Combine(sourceDir, "test.idx.gz")))
        await using (var gz = new GZipStream(fs, CompressionMode.Compress))
        {
            await gz.WriteAsync(idxBytes);
        }

        await using (var fs = File.Create(Path.Combine(sourceDir, "test.dict.dz")))
        await using (var gz = new GZipStream(fs, CompressionMode.Compress))
        {
            await gz.WriteAsync(dictBytes);
        }

        var library = new StarDictLibrary(libDir);
        var source = await library.ImportDictionaryAsync(Path.Combine(sourceDir, "test.ifo"));
        Assert.Equal("Test Dict", source.Name);

        var entry = await library.LookupAsync("probe", source);
        Assert.NotNull(entry);
        Assert.Equal("n. 测试\n释义", entry!.Translation);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempDir)) Directory.Delete(_tempDir, recursive: true);
    }
}
