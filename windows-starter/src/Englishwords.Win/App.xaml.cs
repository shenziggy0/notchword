using System.Drawing;
using System.IO;
using System.Windows;
using Englishwords.Core.Config;
using Englishwords.Core.Dictionary;
using Englishwords.Core.Lookup;
using Englishwords.Core.Notebook;
using Englishwords.Core.Translate;
using Englishwords.Win.Interop;
using Englishwords.Win.Views;

namespace Englishwords.Win;

public partial class App : System.Windows.Application
{
    private Mutex? _singleInstanceMutex;
    private System.Windows.Forms.NotifyIcon? _trayIcon;

    private string _appDataDir = string.Empty;
    private string _settingsPath = string.Empty;
    private Preferences _preferences = new();

    private DictionaryStore? _dictionaryStore;
    private StarDictLibrary? _starDictionaries;
    private DpapiSecretStore? _secretStore;
    private TranslationCoordinator? _translator;
    private LookupCoordinator? _coordinator;
    private NotebookStore? _notebookStore;
    private SpeechSynthesizerService? _speech;

    private SelectionCapture? _selectionCapture;
    private SelectionMonitor? _selectionMonitor;
    private GlobalHotKeyManager? _hotKeys;
    private WindowsOcrEngine? _ocrEngine;
    private CancellationTokenSource? _regionCts;

    private NotchPanelWindow? _panel;
    private SettingsWindow? _settingsWindow;
    private NotebookWindow? _notebookWindow;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _appDataDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Englishwords");
        _settingsPath = Path.Combine(_appDataDir, "settings.json");

        // CLI 自检模式（无 GUI 退出）
        if (HandleCliIfRequested(e.Args))
        {
            return;
        }

        _singleInstanceMutex = new Mutex(initiallyOwned: true, "Global\\Englishwords.Win.Singleton", out var createdNew);
        if (!createdNew)
        {
            System.Windows.MessageBox.Show("Englishwords 已在后台运行，请查看系统托盘图标。", "Englishwords",
                MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        InitializeCoreServices();
        InitializeUiAndHooks();
        FileLog.Write("Englishwords Windows 客户端启动完成");
    }

    private bool HandleCliIfRequested(string[] args)
    {
        if (args.Length == 0) return false;

        if (args[0] == "--check-word" && args.Length >= 2)
        {
            var (dictPath, partsPath) = ResolveBundledResources();
            using var store = new DictionaryStore(dictPath, partsPath);
            var word = TextFilter.NormalizeWord(args[1]);
            var outcome = store.Lookup(word);
            if (outcome.Error is not null)
            {
                Console.Error.WriteLine(outcome.Error.Message);
                Environment.Exit(3);
                return true;
            }
            if (outcome.Entry is null)
            {
                Console.WriteLine($"未收录: {word}");
                Environment.Exit(2);
                return true;
            }

            Console.WriteLine($"{outcome.Entry.Word} [{outcome.Entry.Phonetic}]");
            Console.WriteLine(outcome.Entry.Translation);
            var morph = store.GetMorphology(word);
            if (morph is not null)
            {
                Console.WriteLine("词素: " + string.Join(" / ", morph.Segments.Select(s => s.Label)));
            }
            Environment.Exit(0);
            return true;
        }

        if (args[0] == "--diagnose")
        {
            var (dictPath, partsPath) = ResolveBundledResources();
            var prefs = Preferences.Load(_settingsPath);
            var secrets = new DpapiSecretStore(Path.Combine(_appDataDir, "secrets.bin"));
            var translator = new TranslationCoordinator(prefs, secrets);

            Console.WriteLine($"dictionary.sqlite: {(File.Exists(dictPath) ? "可用" : "缺失")} ({dictPath})");
            Console.WriteLine($"wordparts.sqlite: {(File.Exists(partsPath) ? "可用" : "缺失")} ({partsPath})");
            Console.WriteLine($"en-US OCR 语言包: {(WindowsOcrEngine.IsEnglishOcrAvailable() ? "可用" : "未安装")}");
            Console.WriteLine($"词典源数量: {prefs.DictionarySources.Count}");
            Console.WriteLine($"联网翻译状态: {translator.GetOnlineAvailability()}");
            Environment.Exit(0);
            return true;
        }

        return false;
    }

    private void InitializeCoreServices()
    {
        _preferences = Preferences.Load(_settingsPath);
        var (dictPath, partsPath) = ResolveBundledResources();

        _dictionaryStore = new DictionaryStore(dictPath, partsPath);
        _starDictionaries = new StarDictLibrary(Path.Combine(_appDataDir, "Dictionaries"));
        _secretStore = new DpapiSecretStore(Path.Combine(_appDataDir, "secrets.bin"));
        _translator = new TranslationCoordinator(_preferences, _secretStore);
        _coordinator = new LookupCoordinator(_dictionaryStore, _translator, _preferences, _starDictionaries);
        _notebookStore = new NotebookStore(Path.Combine(_appDataDir, "user.sqlite"));
        _speech = new SpeechSynthesizerService();
        _ocrEngine = new WindowsOcrEngine();
    }

    private void InitializeUiAndHooks()
    {
        _panel = new NotchPanelWindow(_preferences);
        _panel.SpeakRequested += word => _speech?.Speak(word);
        _panel.Dismissed += () =>
        {
            CancelAllRegionTasks();
            _coordinator?.Cancel();
        };
        _panel.FavoriteToggled += async (word, on) =>
        {
            if (_notebookStore is not null)
            {
                try { await _notebookStore.SetFavoriteAsync(word, on); }
                catch (Exception ex) { FileLog.Write($"收藏更新失败: {ex.Message}"); }
            }
        };

        _coordinator!.StateChanged += state =>
        {
            Dispatcher.BeginInvoke(async () =>
            {
                var isFav = false;
                if (state is LookupState.Result res && res.Value.NotebookWord is { } word && _notebookStore is not null)
                {
                    try
                    {
                        await _notebookStore.RecordLookupAsync(word, res.Value.Source, res.Request.Trigger);
                        var favs = await _notebookStore.GetFavoritesAsync();
                        isFav = favs.Contains(word, StringComparer.OrdinalIgnoreCase);
                    }
                    catch (Exception ex)
                    {
                        FileLog.Write($"笔记本记录失败: {ex.Message}");
                    }
                }
                _panel?.UpdateState(state, isFav);
            });
        };

        _selectionCapture = new SelectionCapture(_preferences);
        _selectionMonitor = new SelectionMonitor(_preferences, _selectionCapture)
        {
            OnSubmit = SubmitLookup
        };
        _selectionMonitor.Start();

        _hotKeys = new GlobalHotKeyManager
        {
            ShouldHandleEscape = () => _panel?.IsVisible == true
        };
        _hotKeys.EscapePressed += () => _panel?.HidePanel(cancelActive: true);
        _hotKeys.HotKeyPressed += action => Dispatcher.BeginInvoke(() => HandleHotKey(action));

        var conflicts = _hotKeys.ApplyPreferences(_preferences);
        if (conflicts.Count > 0)
        {
            FileLog.Write("热键冲突: " + string.Join("; ", conflicts));
        }

        SetupTrayIcon();
    }

    private bool SubmitLookup(LookupRequest request)
    {
        if (_coordinator is null) return false;
        var accepted = _coordinator.Submit(request);
        if (accepted && request.Trigger != LookupTrigger.Region)
        {
            CancelAllRegionTasks();
        }
        return accepted;
    }

    private async void HandleHotKey(HotKeyAction action)
    {
        if (action == HotKeyAction.RegionOcr)
        {
            await StartRegionOcrAsync();
            return;
        }

        if (_selectionCapture is null) return;
        var trigger = action == HotKeyAction.Translate ? LookupTrigger.Translate : LookupTrigger.Hotkey;
        var mode = action == HotKeyAction.Translate ? LookupMode.Translate : LookupMode.Lookup;
        var (text, note) = await _selectionCapture.CaptureAsync(trigger);
        SubmitLookup(new LookupRequest(text, trigger, mode, note));
    }

    private async Task StartRegionOcrAsync()
    {
        if (_ocrEngine is null || _coordinator is null) return;

        CancelAllRegionTasks();
        _coordinator.Cancel();

        // 框选期间暂停被动划词，避免拖选遮罩触发查词
        var prevSelectionState = _preferences.SelectionLookupEnabled;
        _preferences.SelectionLookupEnabled = false;
        Int32Rect? selectedRect = null;
        try
        {
            var picker = new RegionPickerWindow();
            if (picker.ShowDialog() == true)
            {
                selectedRect = picker.SelectedPhysicalRect;
            }
        }
        finally
        {
            _preferences.SelectionLookupEnabled = prevSelectionState;
        }

        if (selectedRect is not { } rect) return;

        var requestId = _ocrEngine.NextRequestId();
        _regionCts = new CancellationTokenSource();
        var token = _regionCts.Token;

        var loadingReq = new LookupRequest("区域识别中…", LookupTrigger.Region, LookupMode.Lookup);
        _panel?.UpdateState(new LookupState.Loading(loadingReq));

        try
        {
            var text = await _ocrEngine.RecognizeRegionAsync(rect, requestId, token);
            if (token.IsCancellationRequested || !_ocrEngine.IsCurrentRequest(requestId)) return;
            _regionCts = null;
            SubmitLookup(new LookupRequest(text, LookupTrigger.Region, LookupMode.Lookup));
        }
        catch (OperationCanceledException)
        {
            // 已取消
        }
        catch (Exception ex)
        {
            if (token.IsCancellationRequested || !_ocrEngine.IsCurrentRequest(requestId)) return;
            _panel?.UpdateState(new LookupState.Failure(loadingReq, ex.Message));
        }
    }

    private void CancelAllRegionTasks()
    {
        _ocrEngine?.InvalidatePending();
        _regionCts?.Cancel();
        _regionCts?.Dispose();
        _regionCts = null;
    }

    private void SetupTrayIcon()
    {
        _trayIcon = new System.Windows.Forms.NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "Englishwords",
            Visible = true
        };

        var menu = new System.Windows.Forms.ContextMenuStrip();
        menu.Items.Add("区域取词 (Alt+R)", null, (_, _) => Dispatcher.BeginInvoke(async () => await StartRegionOcrAsync()));
        menu.Items.Add("打开笔记本…", null, (_, _) => Dispatcher.BeginInvoke(OpenNotebookWindow));
        menu.Items.Add("设置…", null, (_, _) => Dispatcher.BeginInvoke(OpenSettingsWindow));
        menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => Shutdown());

        _trayIcon.ContextMenuStrip = menu;
        _trayIcon.DoubleClick += (_, _) => Dispatcher.BeginInvoke(OpenSettingsWindow);
    }

    private void OpenNotebookWindow()
    {
        if (_notebookStore is null) return;
        if (_notebookWindow is null || !_notebookWindow.IsLoaded)
        {
            _notebookWindow = new NotebookWindow(_notebookStore);
            _notebookWindow.WordSelected += word =>
                SubmitLookup(new LookupRequest(word, LookupTrigger.Notebook));
            _notebookWindow.Show();
        }
        else
        {
            _notebookWindow.Activate();
            _ = _notebookWindow.RefreshAsync();
        }
    }

    private void OpenSettingsWindow()
    {
        if (_starDictionaries is null || _secretStore is null || _translator is null) return;
        if (_settingsWindow is null || !_settingsWindow.IsLoaded)
        {
            _settingsWindow = new SettingsWindow(
                _preferences,
                _settingsPath,
                _starDictionaries,
                _secretStore,
                _translator,
                () => _hotKeys?.ApplyPreferences(_preferences));
            _settingsWindow.Show();
        }
        else
        {
            _settingsWindow.Activate();
        }
    }

    private static (string DictPath, string PartsPath) ResolveBundledResources()
    {
        var baseDir = AppContext.BaseDirectory;
        var dict = Path.Combine(baseDir, "Resources", "dictionary.sqlite");
        var parts = Path.Combine(baseDir, "Resources", "wordparts.sqlite");
        return (dict, parts);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        CancelAllRegionTasks();
        _coordinator?.Cancel();
        _selectionMonitor?.Dispose();
        _hotKeys?.Dispose();
        _trayIcon?.Dispose();
        _speech?.Dispose();
        _notebookStore?.Dispose();
        _dictionaryStore?.Dispose();
        _singleInstanceMutex?.Dispose();
        base.OnExit(e);
    }
}
