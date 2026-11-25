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
    internal DesktopAppearance? Appearance { get; private set; }

    private Mutex? _singleInstanceMutex;
    private System.Windows.Forms.NotifyIcon? _trayIcon;

    private string _appDataDir = string.Empty;
    private string _settingsPath = string.Empty;
    private Preferences _preferences = new();

    /// <summary>UI 状态序号：只有最后一次状态更新才能落到面板上。</summary>
    private long _uiStateSeq;

    /// <summary>用户主动关闭面板的次数，用于丢弃已过时的异步更新。</summary>
    private long _dismissSeq;

    private bool _isPickingRegion;

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
    private Window? _welcomeWindow;
    private string? _lastExternalProcess;
    private bool _newProfile;
    private System.Windows.Threading.DispatcherTimer? _foregroundTimer;

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

        // 单实例互斥改到 Local\ 命名空间：不同用户会话可各自运行，同时仍限制同会话多开。
        var createdNew = true;
        try
        {
            _singleInstanceMutex = new Mutex(initiallyOwned: true, @"Local\Englishwords.Win.Singleton", out createdNew);
        }
        catch (UnauthorizedAccessException ex)
        {
            // 权限受限时降级为允许多开，而不是直接启动失败
            FileLog.Write($"单实例互斥创建失败（权限受限，已允许继续启动）: {ex.Message}");
            _singleInstanceMutex = null;
        }
        catch (Exception ex)
        {
            FileLog.Write($"单实例互斥创建失败（已允许继续启动）: {ex.Message}");
            _singleInstanceMutex = null;
        }

        if (!createdNew)
        {
            System.Windows.MessageBox.Show("Englishwords 已在后台运行，请查看系统托盘图标。", "Englishwords",
                MessageBoxButton.OK, MessageBoxImage.Information);
            _singleInstanceMutex?.Dispose();
            _singleInstanceMutex = null;
            Shutdown();
            return;
        }

        InitializeCoreServices();
        Appearance = new DesktopAppearance(this, _preferences);
        InitializeUiAndHooks();
        FileLog.Write("Englishwords Windows 客户端启动完成");
    }

    private bool HandleCliIfRequested(string[] args)
    {
        if (args.Length == 0) return false;

        // WinExe 默认没有控制台：先附接到父进程控制台，--check-word / --diagnose 才能正常输出。
        // 必须在构造任何其它对象之前执行。
        _ = NativeMethods.AttachConsole(NativeMethods.ATTACH_PARENT_PROCESS);

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
        _newProfile = !File.Exists(_settingsPath);
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
            // 记录主动关闭次数，后续迟到的笔记本写入不能再把面板「诈尸」出来
            Interlocked.Increment(ref _dismissSeq);
            CancelAllRegionTasks();
            _coordinator?.Cancel();
        };
        if (_notebookStore is { } notebook)
        {
            _panel.SaveFavoriteAsync = (word, on) => notebook.SetFavoriteAsync(word, on);
            _panel.SaveExampleAsync = (word, context, meaning) => notebook.SaveExampleAsync(word, context, meaning);
            _panel.HasExamplesAsync = async word => (await notebook.GetExamplesAsync(word)).Count > 0;
        }
        _panel.RelatedWords = (part, current) => _dictionaryStore?.RelatedWords(part, current) ?? [];
        _panel.LookupRelated = word => SubmitLookup(new LookupRequest(word, LookupTrigger.Notebook));

        _coordinator!.StateChanged += state =>
        {
            var seq = Interlocked.Increment(ref _uiStateSeq);
            var dismissAtDispatch = Interlocked.Read(ref _dismissSeq);

            Dispatcher.BeginInvoke(async () =>
            {
                var isFav = false;
                if (state is LookupState.Result res && res.Request.Trigger != LookupTrigger.Example && res.Value.NotebookWord is { } word && _notebookStore is not null)
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

                // 等待笔记本 IO 期间可能已到达更新的状态，或用户已主动关窗：丢弃这次过时更新
                if (Interlocked.Read(ref _uiStateSeq) != seq) return;
                if (Interlocked.Read(ref _dismissSeq) != dismissAtDispatch) return;

                _panel?.UpdateState(state, isFav);
                if (state.Request.Trigger == LookupTrigger.Example) _panel?.ExpandForExample();
            });
        };

        _selectionCapture = new SelectionCapture(_preferences);
        _selectionMonitor = new SelectionMonitor(_preferences, _selectionCapture)
        {
            OnSubmit = SubmitLookup,
            IsInsideOwnWindow = IsScreenPointInsideOwnWindow
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
        if (_newProfile && !_preferences.SawWelcome) OpenWelcomeWindow();
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
        // async void 里的任何异常会直接弄崩 WPF 进程，必须全包。
        try
        {
            if (action == HotKeyAction.RegionOcr)
            {
                await StartRegionOcrAsync();
                return;
            }

            if (_selectionCapture is null) return;
            var trigger = action == HotKeyAction.Translate ? LookupTrigger.Translate : LookupTrigger.Hotkey;
            var mode = action == HotKeyAction.Translate ? LookupMode.Translate : LookupMode.Lookup;
            var (text, note, context) = await _selectionCapture.CaptureAsync(trigger);
            SubmitLookup(new LookupRequest(text, trigger, mode, note, Context: context));
        }
        catch (OperationCanceledException)
        {
            // 用户取消，静默
        }
        catch (Exception ex)
        {
            FileLog.Write($"热键 {action} 处理失败: {ex.Message}");
        }
    }

    private async Task StartRegionOcrAsync()
    {
        if (_ocrEngine is null || _coordinator is null) return;

        // 防重入：遮罩还在时就不要再开一层
        if (_isPickingRegion) return;
        _isPickingRegion = true;

        try
        {
            CancelAllRegionTasks();
            _coordinator.Cancel();

            // 框选期间暂停被动划词，避免拖选遮罩触发查词
            var prevSelectionState = _preferences.SelectionLookupEnabled;
            _preferences.SelectionLookupEnabled = false;
            Int32Rect? selectedRect = null;
            try
            {
                selectedRect = RegionPickerWindow.PickRegion();
            }
            finally
            {
                _preferences.SelectionLookupEnabled = prevSelectionState;
            }

            if (selectedRect is not { } rect) return;

            // 等 DWM 把暗色遮罩合成清除，否则截图会把自家遮罩一起截进去
            await Task.Delay(60);

            var requestId = _ocrEngine.NextRequestId();
            var cts = new CancellationTokenSource();
            _regionCts = cts;
            var token = cts.Token;

            var loadingReq = new LookupRequest("区域识别中…", LookupTrigger.Region, LookupMode.Lookup);
            var loadingShown = false;

            try
            {
                // 先把屏幕截好，再在 onCaptured 里展示 Loading，避免把 Loading 窗截入图内
                var text = await _ocrEngine.RecognizeRegionAsync(rect, requestId, token, onCaptured: () =>
                {
                    if (loadingShown) return;
                    loadingShown = true;
                    Dispatcher.Invoke(() => _panel?.UpdateState(new LookupState.Loading(loadingReq)));
                });

                if (token.IsCancellationRequested || !_ocrEngine.IsCurrentRequest(requestId)) return;
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
            finally
            {
                if (ReferenceEquals(_regionCts, cts))
                {
                    _regionCts = null;
                }
                cts.Dispose();
            }
        }
        catch (Exception ex)
        {
            FileLog.Write($"区域取词失败: {ex.Message}");
        }
        finally
        {
            _isPickingRegion = false;
        }
    }

    /// <summary>
    /// 判断物理屏幕坐标是否落在自家窗口内（面板 / 设置 / 笔记本），
    /// 用于排除在自家窗口上拖选时误触发划词。
    /// </summary>
    private bool IsScreenPointInsideOwnWindow(int x, int y)
    {
        if (_panel?.ContainsScreenPoint(x, y) == true) return true;
        return WindowContainsScreenPoint(_settingsWindow, x, y)
               || WindowContainsScreenPoint(_notebookWindow, x, y);
    }

    private static bool WindowContainsScreenPoint(Window? window, int x, int y)
    {
        if (window is null || !window.IsVisible) return false;

        var dpi = System.Windows.Media.VisualTreeHelper.GetDpi(window);
        var scaleX = dpi.DpiScaleX > 0 ? dpi.DpiScaleX : 1.0;
        var scaleY = dpi.DpiScaleY > 0 ? dpi.DpiScaleY : 1.0;

        var left = window.Left * scaleX;
        var top = window.Top * scaleY;
        var right = left + window.ActualWidth * scaleX;
        var bottom = top + window.ActualHeight * scaleY;

        return x >= left && x <= right && y >= top && y <= bottom;
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
            Icon = new Icon(typeof(App), "Assets.AppIcon.ico"),
            Text = "Englishwords",
            Visible = true
        };

        var menu = new System.Windows.Forms.ContextMenuStrip();
        menu.Items.Add("区域取词 (Alt+R)", null, (_, _) => Dispatcher.BeginInvoke(async () => await StartRegionOcrAsync()));
        var pause = menu.Items.Add("暂停当前应用自动取词");
        string? pauseTarget = null;
        _foregroundTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
        _foregroundTimer.Tick += (_, _) =>
        {
            if (_selectionCapture is not null && !_selectionCapture.IsForegroundExcluded(out var process) &&
                process.Length > 0 && !string.Equals(process, "explorer", StringComparison.OrdinalIgnoreCase))
                _lastExternalProcess = process;
        };
        _foregroundTimer.Start();
        menu.Opening += (_, _) =>
        {
            pauseTarget = _lastExternalProcess;
            if (_selectionCapture is not null && !_selectionCapture.IsForegroundExcluded(out var current) &&
                current.Length > 0 && !string.Equals(current, "explorer", StringComparison.OrdinalIgnoreCase))
                pauseTarget = current;
            pause.Enabled = pauseTarget is not null;
            pause.Text = pauseTarget is null ? "暂停当前应用自动取词" :
                _preferences.IsPaused(pauseTarget) ? $"在 {pauseTarget} 提前恢复自动取词" :
                $"在 {pauseTarget} 暂停自动取词 30 分钟";
        };
        pause.Click += (_, _) =>
        {
            if (pauseTarget is null) return;
            _preferences.TogglePause(pauseTarget);
            _preferences.Save(_settingsPath);
        };
        menu.Items.Add("使用引导…", null, (_, _) => Dispatcher.BeginInvoke(OpenWelcomeWindow));
        menu.Items.Add("打开笔记本…", null, (_, _) => Dispatcher.BeginInvoke(OpenNotebookWindow));
        menu.Items.Add("设置…", null, (_, _) => Dispatcher.BeginInvoke(OpenSettingsWindow));
        menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => Shutdown());

        _trayIcon.ContextMenuStrip = menu;
        _trayIcon.DoubleClick += (_, _) => Dispatcher.BeginInvoke(OpenSettingsWindow);
    }

    private void OpenWelcomeWindow()
    {
        if (_welcomeWindow is not null) { _welcomeWindow.Activate(); return; }
        var content = new System.Windows.Controls.StackPanel { Margin = new Thickness(24) };
        content.Children.Add(new System.Windows.Controls.TextBlock
        {
            Text = "The villagers foiled an attempt to abduct the young prince.",
            TextWrapping = TextWrapping.Wrap, FontSize = 20
        });
        var tryButton = new System.Windows.Controls.Button { Content = "查 abduct", Margin = new Thickness(0, 16, 0, 8) };
        tryButton.Click += (_, _) => SubmitLookup(new LookupRequest("abduct", LookupTrigger.Example));
        content.Children.Add(tryButton);
        content.Children.Add(new System.Windows.Controls.TextBlock
        {
            Text = "在其他应用里选中英文，按 Alt+D 查词。", TextWrapping = TextWrapping.Wrap
        });
        var done = new System.Windows.Controls.Button { Content = "完成", Margin = new Thickness(0, 12, 0, 0) };
        done.Click += (_, _) => _welcomeWindow?.Close();
        content.Children.Add(done);
        _welcomeWindow = new Window
        {
            Style = (Style)FindResource("PageWindow"), Title = "开始使用 Englishwords", Width = 460, SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterScreen, Content = content
        };
        _welcomeWindow.Closed += (_, _) =>
        {
            _welcomeWindow = null;
            _preferences.SawWelcome = true;
            _preferences.Save(_settingsPath);
        };
        _welcomeWindow.Show();
    }

    private void OpenNotebookWindow()
    {
        if (_notebookStore is null) return;
        if (_notebookWindow is null || !_notebookWindow.IsLoaded)
        {
            _notebookWindow = new NotebookWindow(_notebookStore, _dictionaryStore);
            _notebookWindow.WordSelected += word =>
                SubmitLookup(new LookupRequest(word, LookupTrigger.Notebook));
            _notebookWindow.Show();
        }
        else
        {
            if (_notebookWindow.WindowState == WindowState.Minimized)
            {
                _notebookWindow.WindowState = WindowState.Normal;
            }
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
                () =>
                {
                    var conflicts = _hotKeys?.ApplyPreferences(_preferences) ?? new List<string>();
                    if (conflicts.Count > 0)
                    {
                        FileLog.Write("热键冲突: " + string.Join("; ", conflicts));
                    }
                    return conflicts;
                });
            _settingsWindow.Show();
        }
        else
        {
            if (_settingsWindow.WindowState == WindowState.Minimized)
            {
                _settingsWindow.WindowState = WindowState.Normal;
            }
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
        _foregroundTimer?.Stop();
        CancelAllRegionTasks();
        _coordinator?.Cancel();
        _selectionMonitor?.Dispose();
        _hotKeys?.Dispose();
        _trayIcon?.ContextMenuStrip?.Dispose();
        using var trayImage = _trayIcon?.Icon;
        _trayIcon?.Dispose();
        _speech?.Dispose();
        _notebookStore?.Dispose();
        _dictionaryStore?.Dispose();
        _singleInstanceMutex?.Dispose();
        Appearance?.Dispose();
        base.OnExit(e);
    }
}
