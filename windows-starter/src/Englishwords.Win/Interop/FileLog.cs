using System.IO;

namespace Englishwords.Win.Interop;

/// <summary>
/// 本地诊断日志：仅记录来源、耗时与降级原因，严禁记录查询文本或 API 密钥。
/// </summary>
public static class FileLog
{
    private static readonly object Sync = new();

    public static string LogPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Englishwords",
        "Logs",
        "app.log");

    public static void Write(string message)
    {
        try
        {
            lock (Sync)
            {
                var dir = Path.GetDirectoryName(LogPath);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                var line = $"[{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff}] {message}{Environment.NewLine}";
                File.AppendAllText(LogPath, line);
            }
        }
        catch
        {
            // 日志写入失败不影响主流程
        }
    }
}
