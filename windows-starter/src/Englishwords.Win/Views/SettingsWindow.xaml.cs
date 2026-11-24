using System.ComponentModel;
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
    private readonly Func<IReadOnlyList<string>> _onPreferencesChanged;
    private bool _isInitializing = true;
    private bool _isRefreshingList;
    private string _lastConflictSignature = string.Empty;

    public SettingsWindow(
        Preferences preferences,
        string settingsPath,
        StarDictLibrary starDictionaries,
        DpapiSecretStore secretStore,
        TranslationCoordinator translator,
        Func<IReadOnlyList<string>> onPreferencesChanged)
    {
        _preferences = preferences;
        _settingsPath = settingsPath;
        _starDictionaries = starDictionaries;
        _secretStore = secretStore;
        _translator = translator;
        _onPreferencesChanged = onPreferencesChanged;

        InitializeComponent();
        Pages.SelectionChanged += DesktopAppearance.PageChanged;
        AddHandler(System.Windows.Controls.Primitives.ToggleButton.CheckedEvent, new RoutedEventHandler(DesktopAppearance.SwitchChanged));
        AddHandler(System.Windows.Controls.Primitives.ToggleButton.UncheckedEvent, new RoutedEventHandler(DesktopAppearance.SwitchChanged));
        SourceInitialized += (_, _) => (System.Windows.Application.Current as App)?.Appearance?.ApplyTitleBar(this);
        LoadInitialState();
        _isInitializing = false;
    }

    private void LoadInitialState()
    {
        PanelStyleCombo.SelectedIndex = _preferences.PanelStyle == PanelStyle.Notch ? 0 : 1;
        SelectionToggle.IsChecked = _preferences.SelectionLookupEnabled;
        AutoHideToggle.Content = $"展示 {Math.Clamp(_preferences.AutoHideSeconds, 2, 30):0.#} 秒后自动收起";
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

        var conflicts = _onPreferencesChanged?.Invoke() ?? Array.Empty<string>();
        if (conflicts.Count == 0)
        {
            _lastConflictSignature = string.Empty;
            return;
        }

        // 只在冲突集合发生变化时弹窗，避免每次改设置都重复提示。
        var signature = string.Join("|", conflicts);
        if (signature == _lastConflictSignature) return;
        _lastConflictSignature = signature;

        System.Windows.MessageBox.Show(
            this,
            "以下热键已被其他程序占用，当前无法生效：\n\n" + string.Join("\n", conflicts),
            "热键冲突",
            MessageBoxButton.OK,
            MessageBoxImage.Warning);
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

        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunRegPath, writable: true)
                ?? throw new InvalidOperationException("无法打开注册表启动项目录");

            if (enable)
            {
                var exePath = Environment.ProcessPath
                    ?? throw new InvalidOperationException("无法获取当前程序路径");
                key.SetValue(AppRunName, $"\"{exePath}\"");
            }
            else
            {
                key.DeleteValue(AppRunName, throwOnMissingValue: false);
            }
        }
        catch (Exception ex)
        {
            // 失败必须把勾选状态和偏好一起回滚，否则界面会骗用户说已开启
            System.Windows.MessageBox.Show(this, $"修改开机启动项失败：{ex.Message}", "Englishwords",
                MessageBoxButton.OK, MessageBoxImage.Error);

            _isInitializing = true;
            try
            {
                LaunchAtLoginToggle.IsChecked = !enable;
            }
            finally
            {
                _isInitializing = false;
            }

            return;
        }

        _preferences.LaunchAtLogin = enable;
        SaveAndNotify();
    }

    private void OpenLogFolder_Click(object sender, RoutedEventArgs e)
    {
        var dir = Path.GetDirectoryName(FileLog.LogPath);
        if (string.IsNullOrEmpty(dir)) return;

        Directory.CreateDirectory(dir);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{dir}\"") { UseShellExecute = true });
    }

    private void RefreshDictList()
    {
        // 重建容器会触发 Checked/Unchecked，此时不能写入设置
        _isRefreshingList = true;
        try
        {
            DictSourcesList.ItemsSource = null;
            DictSourcesList.ItemsSource = _preferences.DictionarySources;
        }
        finally
        {
            _isRefreshingList = false;
        }
    }

    private void DictSource_Changed(object sender, RoutedEventArgs e)
    {
        if (_isInitializing || _isRefreshingList) return;
        if (sender is not System.Windows.Controls.CheckBox checkBox) return;
        if (checkBox.DataContext is not DictionarySource source) return;

        // Click 只由用户点击触发：列表容器生成、切换 Tab、绑定刷新都不会误写入设置。
        // 以 CheckBox 的实际状态为准写回数据对象，避免依赖绑定更新顺序。
        source.Enabled = checkBox.IsChecked == true;
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
        CommitOnlineConfig();
    }

    /// <summary>
    /// 把地址/模型输入框里尚未失焦的内容提交到设置，窗口关闭时也会兜底调一次。
    /// </summary>
    private void CommitOnlineConfig()
    {
        if (_isInitializing) return;

        var address = AddressBox.Text.Trim();
        var model = ModelBox.Text.Trim();
        if (string.Equals(address, _preferences.OnlineAddress, StringComparison.Ordinal) &&
            string.Equals(model, _preferences.OnlineModel, StringComparison.Ordinal))
        {
            return;
        }

        _preferences.OnlineAddress = address;
        _preferences.OnlineModel = model;
        _translator.InvalidateCache();
        SaveAndNotify();
        RefreshOnlineStatus();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        // 用户可能直接在输入框里改完就关窗，不经过 LostKeyboardFocus
        CommitOnlineConfig();
        base.OnClosing(e);
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
        var result = _secretStore.Delete(_preferences.TranslationPreset.GetRawValue());
        if (!result.IsSuccess)
        {
            // 删除失败时必须明确提示，并保留原密钥不动
            System.Windows.MessageBox.Show(this, result.ErrorMessage ?? "清除密钥失败", "Englishwords",
                MessageBoxButton.OK, MessageBoxImage.Error);
            return;
        }

        _translator.InvalidateCache();
        RefreshOnlineStatus();
        OnlineStatusText.Text = "密钥已清除";
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
