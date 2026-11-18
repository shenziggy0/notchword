using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Englishwords.Core.Translate;

namespace Englishwords.Win.Interop;

public enum SecretStoreErrorKind
{
    EmptyValue,
    StorageFailure
}

public sealed record SecretStoreResult(bool IsSuccess, SecretStoreErrorKind? ErrorKind = null, string? ErrorMessage = null);

/// <summary>
/// 使用 Windows DPAPI (<see cref="DataProtectionScope.CurrentUser"/>) 加密保存 API 密钥。
/// <para>
/// 严格拦截空白密钥保存请求，防止误删用户已有密钥。
/// </para>
/// </summary>
public sealed class DpapiSecretStore : ISecretReader
{
    private readonly string _filePath;
    private readonly object _sync = new();

    public DpapiSecretStore(string filePath)
    {
        _filePath = filePath;
    }

    public SecretStoreResult Save(string account, string secret)
    {
        var trimmed = (secret ?? string.Empty).Trim();
        if (trimmed.Length == 0)
        {
            return new SecretStoreResult(false, SecretStoreErrorKind.EmptyValue, "密钥不能为空；如需清除请点击「清除密钥」。");
        }

        lock (_sync)
        {
            try
            {
                var map = ReadMapInternal();
                map[account] = trimmed;
                WriteMapInternal(map);
                return new SecretStoreResult(true);
            }
            catch (Exception ex)
            {
                return new SecretStoreResult(false, SecretStoreErrorKind.StorageFailure, $"保存密钥失败：{ex.Message}");
            }
        }
    }

    public string? ReadSecret(string account)
    {
        lock (_sync)
        {
            try
            {
                var map = ReadMapInternal();
                return map.TryGetValue(account, out var value) ? value : null;
            }
            catch
            {
                return null;
            }
        }
    }

    public SecretStoreResult Delete(string account)
    {
        lock (_sync)
        {
            try
            {
                var map = ReadMapInternal();
                if (map.Remove(account))
                {
                    WriteMapInternal(map);
                }
                return new SecretStoreResult(true);
            }
            catch (Exception ex)
            {
                return new SecretStoreResult(false, SecretStoreErrorKind.StorageFailure, $"清除密钥失败：{ex.Message}");
            }
        }
    }

    private Dictionary<string, string> ReadMapInternal()
    {
        if (!File.Exists(_filePath)) return new Dictionary<string, string>(StringComparer.Ordinal);
        var encrypted = File.ReadAllBytes(_filePath);
        if (encrypted.Length == 0) return new Dictionary<string, string>(StringComparer.Ordinal);

        var plain = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
        var json = Encoding.UTF8.GetString(plain);
        return JsonSerializer.Deserialize<Dictionary<string, string>>(json)
               ?? new Dictionary<string, string>(StringComparer.Ordinal);
    }

    private void WriteMapInternal(Dictionary<string, string> map)
    {
        var dir = Path.GetDirectoryName(_filePath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        var json = JsonSerializer.Serialize(map);
        var plain = Encoding.UTF8.GetBytes(json);
        var encrypted = ProtectedData.Protect(plain, null, DataProtectionScope.CurrentUser);
        File.WriteAllBytes(_filePath, encrypted);
    }
}
