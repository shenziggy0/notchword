using System.Text.Json;
using System.Text.Json.Serialization;
using Englishwords.Core.Dictionary;
using Englishwords.Core.Translate;

namespace Englishwords.Core.Config;

public enum PanelStyle
{
    Notch,
    Floating
}

public enum HotKeyAction
{
    Lookup,
    Translate,
    RegionOcr
}

/// <summary>
/// 全局快捷键定义（使用 Win32 虚拟键码与修饰键位掩码）。
/// </summary>
public sealed class HotKeySpec
{
    public uint Modifiers { get; set; }
    public uint VirtualKey { get; set; }
    public string Display { get; set; } = string.Empty;

    // MOD_ALT = 0x0001, VK_D = 0x44, VK_T = 0x54, VK_R = 0x52
    public static HotKeySpec DefaultLookup() => new() { Modifiers = 0x0001, VirtualKey = 0x44, Display = "Alt+D" };
    public static HotKeySpec DefaultTranslate() => new() { Modifiers = 0x0001, VirtualKey = 0x54, Display = "Alt+T" };
    public static HotKeySpec DefaultRegionOcr() => new() { Modifiers = 0x0001, VirtualKey = 0x52, Display = "Alt+R" };
}

/// <summary>
/// 应用偏好设置模型，持久化至 <c>%LOCALAPPDATA%\Englishwords\settings.json</c>。
/// </summary>
public sealed class Preferences
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };

    public PanelStyle PanelStyle { get; set; } = PanelStyle.Notch;
    public bool SelectionLookupEnabled { get; set; } = true;
    public bool AutoHideEnabled { get; set; } = true;
    public double AutoHideSeconds { get; set; } = 5.0;
    public bool LaunchAtLogin { get; set; } = false;
    public string TargetLanguage { get; set; } = "zh-Hans";

    public HotKeySpec LookupHotKey { get; set; } = HotKeySpec.DefaultLookup();
    public HotKeySpec TranslateHotKey { get; set; } = HotKeySpec.DefaultTranslate();
    public HotKeySpec RegionOcrHotKey { get; set; } = HotKeySpec.DefaultRegionOcr();

    public List<DictionarySource> DictionarySources { get; set; } = DictionarySource.CreateDefaults();

    public bool OnlineEnabled { get; set; } = false;
    public ProviderPreset TranslationPreset { get; set; } = ProviderPreset.OpenAI;
    public string OnlineAddress { get; set; } = ProviderPreset.OpenAI.GetDefaultAddress();
    public string OnlineModel { get; set; } = ProviderPreset.OpenAI.GetDefaultModel();

    public List<string> ExcludedProcesses { get; set; } =
    [
        "WindowsTerminal", "cmd", "powershell", "pwsh", "mintty", "wt",
        "1Password", "Bitwarden", "KeePass", "KeePassXC"
    ];

    public static Preferences Load(string filePath)
    {
        try
        {
            if (!File.Exists(filePath)) return new Preferences();
            var json = File.ReadAllText(filePath);
            var loaded = JsonSerializer.Deserialize<Preferences>(json, JsonOptions);
            if (loaded is null) return new Preferences();
            if (loaded.DictionarySources.Count == 0)
            {
                loaded.DictionarySources = DictionarySource.CreateDefaults();
            }
            return loaded;
        }
        catch
        {
            return new Preferences();
        }
    }

    public void Save(string filePath)
    {
        var dir = Path.GetDirectoryName(filePath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        File.WriteAllText(filePath, JsonSerializer.Serialize(this, JsonOptions));
    }
}
