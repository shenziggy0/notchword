using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using Englishwords.Core.Config;
using Englishwords.Core.Dictionary;
using Englishwords.Core.Translate;
using Englishwords.Win.Interop;
using Microsoft.Win32;

namespace Englishwords.Win.Views;

public partial class SettingsWindow : Window
{
    private const string RunRegPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string AppRunName = "Englishwords";

    private readonly Preferences _preferences;
    private readonly string _settingsPath;
    private readonly StarDictLibrary _starDictionaries;
    private readonly DpapiSecretStore _secretStore;
    private readonly TranslationCoordinator _translator;
    private readonly Action _onPreferencesChanged;
    private bool _isInitializing = true;

    public SettingsWindow(
        Preferences preferences,
        string settingsPath,
        StarDictLibrary starDictionaries,
        DpapiSecretStore secretStore,
        TranslationCoordinator translator,
        Action onPreferencesChanged)
    {
        _preferences = preferences;
        _settingsPath = settingsPath;
        _starDictionaries = starDictionaries;
        _secretStore = secretStore;
        _translator = translator;
        _onPreferencesChanged = onPreferencesChanged;

        InitializeComponent();
        LoadInitialState();
        _isInitializing = false;
    }

    private void LoadInitialState()
    {
        PanelStyleCombo.SelectedIndex = _preferences.PanelStyle == PanelStyle.Notch ? 0 : 1;
        SelectionToggle.IsChecked = _preferences.SelectionLookupEnabled;
        AutoHideToggle.IsChecked = _preferences.AutoHideEnabled;
        LaunchAtLoginToggle.IsChecked = _preferences.LaunchAtLogin;

        HotKeySummaryText.Text =
            $"查词：{_preferences.LookupHotKey.Display}   |   直接翻译：{_preferences.TranslateHotKey.Display}   |   区域 OCR：{_preferences.RegionOcrHotKey.Display}";

        OcrStatusText.Text = WindowsOcrEngine.IsEnglishOcrAvailable()
            ? "系统英文 (en-US) OCR 语言包：已就绪"
            : "系统英文 (en-US) OCR 语言包：未安装（请前往 Windows 设置 → 时间和语言添加英语）";

        RefreshDictList();

        PresetCombo.ItemsSource = Enum.GetValues<ProviderPreset>()
            .Select(p => new { Value = p, Name = p.GetDisplayName() })
            .ToArray();
        PresetCombo.DisplayMemberPath = "Name";
        PresetCombo.SelectedValuePath = "Value";
        PresetCombo.SelectedValue = _preferences.TranslationPreset;

        OnlineEnabledToggle.IsChecked = _preferences.OnlineEnabled;
        AddressBox.Text = _preferences.OnlineAddress;
        ModelBox.Text = _preferences.OnlineModel;
        RefreshOnlineStatus();
    }

    private void SaveAndNotify()
    {
        _preferences.Save(_settingsPath);
        _onPreferencesChanged();
    }

    private void PanelStyleCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_isInitializing) return;
        _preferences.PanelStyle = PanelStyleCombo.SelectedIndex == 0 ? PanelStyle.Notch : PanelStyle.Floating;
        SaveAndNotify();
    }

    private void GeneralOption_Changed(object sender, RoutedEventArgs e)
    {
        if (_isInitializing) return;
        _preferences.SelectionLookupEnabled = SelectionToggle.IsChecked == true;
        _preferences.AutoHideEnabled = AutoHideToggle.IsChecked == true;
        SaveAndNotify();
    }

    private void LaunchAtLoginToggle_Changed(object sender, RoutedEventArgs e)
    {
        if (_isInitializing) return;
        var enable = LaunchAtLoginToggle.IsChecked == true;
        _preferences.LaunchAtLogin = enable;
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunRegPath, writable: true);
            if (key is not null)
            {
                if (enable && Environment.ProcessPath is { } exePath)
                {
                    key.SetValue(AppRunName, $"\"{exePath}\"");
                }
                else
                {
                    key.DeleteValue(AppRunName, throwOnMissingValue: false);
                }
            }
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(this, $"修改开机启动项失败：{ex.Message}", "Englishwords");
        }
        SaveAndNotify();
    }

    private void OpenLogFolder_Click(object sender, RoutedEventArgs e)
    {
        var dir = Path.GetDirectoryName(FileLog.LogPath);
        if (!string.IsNullOrEmpty(dir))
        {
            Directory.CreateDirectory(dir);
            Process.Start(new ProcessStartInfo("explorer.exe", dir) { UseShellExecute = true });
        }
    }

    private void RefreshDictList()
    {
        DictSourcesList.ItemsSource = null;
        DictSourcesList.ItemsSource = _preferences.DictionarySources;
    }

    private void DictSource_Changed(object sender, RoutedEventArgs e)
    {
        if (_isInitializing) return;
        SaveAndNotify();
    }

    private async void ImportStarDict_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Filter = "StarDict 词典 (*.ifo)|*.ifo",
            Title = "选择 StarDict 词典 .ifo 文件"
        };
        if (dialog.ShowDialog(this) != true) return;

        try
        {
            var source = await _starDictionaries.ImportDictionaryAsync(dialog.FileName);
            _preferences.DictionarySources.Add(source);
            RefreshDictList();
            SaveAndNotify();
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(this, ex.Message, "导入失败", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void MoveUpDict_Click(object sender, RoutedEventArgs e)
    {
        var idx = DictSourcesList.SelectedIndex;
        if (idx <= 0) return;
        (_preferences.DictionarySources[idx - 1], _preferences.DictionarySources[idx]) =
            (_preferences.DictionarySources[idx], _preferences.DictionarySources[idx - 1]);
        RefreshDictList();
        DictSourcesList.SelectedIndex = idx - 1;
        SaveAndNotify();
    }

    private void MoveDownDict_Click(object sender, RoutedEventArgs e)
    {
        var idx = DictSourcesList.SelectedIndex;
        if (idx < 0 || idx >= _preferences.DictionarySources.Count - 1) return;
        (_preferences.DictionarySources[idx + 1], _preferences.DictionarySources[idx]) =
            (_preferences.DictionarySources[idx], _preferences.DictionarySources[idx + 1]);
        RefreshDictList();
        DictSourcesList.SelectedIndex = idx + 1;
        SaveAndNotify();
    }

    private async void RemoveDict_Click(object sender, RoutedEventArgs e)
    {
        if (DictSourcesList.SelectedItem is not DictionarySource source) return;
        if (source.Kind == DictionarySourceKind.Builtin)
        {
            System.Windows.MessageBox.Show(this, "内置词库不可移除，可取消勾选禁用。", "Englishwords");
            return;
        }

        try
        {
            await _starDictionaries.RemoveAsync(source);
            _preferences.DictionarySources.Remove(source);
            RefreshDictList();
            SaveAndNotify();
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(this, ex.Message, "移除失败");
        }
    }

    private void OnlineEnabled_Changed(object sender, RoutedEventArgs e)
    {
        if (_isInitializing) return;
        _preferences.OnlineEnabled = OnlineEnabledToggle.IsChecked == true;
        _translator.InvalidateCache();
        SaveAndNotify();
        RefreshOnlineStatus();
    }

    private void PresetCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_isInitializing || PresetCombo.SelectedValue is not ProviderPreset preset) return;
        _preferences.TranslationPreset = preset;
        _preferences.OnlineAddress = preset.GetDefaultAddress();
        _preferences.OnlineModel = preset.GetDefaultModel();
        AddressBox.Text = _preferences.OnlineAddress;
        ModelBox.Text = _preferences.OnlineModel;
        _translator.InvalidateCache();
        SaveAndNotify();
        RefreshOnlineStatus();
    }

    private void OnlineConfig_LostFocus(object sender, RoutedEventArgs e)
    {
        if (_isInitializing) return;
        _preferences.OnlineAddress = AddressBox.Text.Trim();
        _preferences.OnlineModel = ModelBox.Text.Trim();
        _translator.InvalidateCache();
        SaveAndNotify();
        RefreshOnlineStatus();
    }

    private void SaveKey_Click(object sender, RoutedEventArgs e)
    {
        var result = _secretStore.Save(_preferences.TranslationPreset.GetRawValue(), ApiKeyBox.Password);
        if (!result.IsSuccess)
        {
            OnlineStatusText.Text = result.ErrorMessage ?? "保存密钥失败";
            return;
        }
        ApiKeyBox.Clear();
        _translator.InvalidateCache();
        RefreshOnlineStatus();
        OnlineStatusText.Text = "密钥已安全保存";
    }

    private void ClearKey_Click(object sender, RoutedEventArgs e)
    {
        _secretStore.Delete(_preferences.TranslationPreset.GetRawValue());
        _translator.InvalidateCache();
        RefreshOnlineStatus();
    }

    private async void TestOnline_Click(object sender, RoutedEventArgs e)
    {
        OnlineStatusText.Text = "正在测试连接…";
        try
        {
            var res = await _translator.TestOnlineTranslationAsync();
            OnlineStatusText.Text = $"测试成功：{res.Text}";
        }
        catch (Exception ex)
        {
            OnlineStatusText.Text = ex.Message;
        }
    }

    private void RefreshOnlineStatus()
    {
        OnlineStatusText.Text = _translator.GetOnlineAvailability() switch
        {
            OnlineAvailability.Disabled => "联网翻译已关闭",
            OnlineAvailability.MissingCredentials => "缺少服务地址、模型或 API 密钥",
            OnlineAvailability.Ready => "联网翻译配置就绪",
            _ => string.Empty
        };
    }
}
