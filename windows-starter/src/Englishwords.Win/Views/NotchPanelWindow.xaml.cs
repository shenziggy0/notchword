using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Englishwords.Core.Config;
using Englishwords.Core.Dictionary;
using Englishwords.Core.Lookup;
using Englishwords.Win.Interop;

namespace Englishwords.Win.Views;

public sealed record SegmentChipVm(string Label, string GlossText, string RoleName, bool IsRoot);

public partial class NotchPanelWindow : Window
{
    private readonly Preferences _preferences;
    private readonly DispatcherTimer _autoHideTimer;
    private readonly DispatcherTimer _avoidanceTimer;

    private LookupState? _currentState;
    private bool _isExpanded = true;
    private bool _isPointerInside;
    private bool _isFavorite;
    private readonly HashSet<string> _pendingFavorites = new(StringComparer.OrdinalIgnoreCase);
    private IntPtr _hwnd;

    public Func<string, bool, Task>? SaveFavoriteAsync { get; set; }
    public event Action<string>? SpeakRequested;
    public event Action? Dismissed;

    public NotchPanelWindow(Preferences preferences)
    {
        _preferences = preferences;
        InitializeComponent();

        _autoHideTimer = new DispatcherTimer();
        _autoHideTimer.Tick += (_, _) => HidePanel(cancelActive: false);

        // 顶部避让检测定时器：当窗口最大化且鼠标进入顶部 36px 区域（不在面板内）时穿透避让
        _avoidanceTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
        _avoidanceTimer.Tick += (_, _) => UpdateTopBarAvoidance();

        MouseEnter += (_, _) =>
        {
            _isPointerInside = true;
            _autoHideTimer.Stop();
            if (_preferences.PanelStyle == PanelStyle.Notch && !_isExpanded)
            {
                _isExpanded = true;
                ApplyExpansionState();
            }
        };

        MouseLeave += (_, _) =>
        {
            _isPointerInside = false;
            RestartHideTimerIfEligible();
        };
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        _hwnd = new WindowInteropHelper(this).Handle;
        var exStyle = NativeMethods.GetWindowLongPtr(_hwnd, NativeMethods.GWL_EXSTYLE).ToInt64();
        exStyle |= NativeMethods.WS_EX_NOACTIVATE | NativeMethods.WS_EX_TOOLWINDOW | NativeMethods.WS_EX_TOPMOST;
        NativeMethods.SetWindowLongPtr(_hwnd, NativeMethods.GWL_EXSTYLE, new IntPtr(exStyle));

        var source = HwndSource.FromHwnd(_hwnd);
        source?.AddHook(WndProc);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == NativeMethods.WM_MOUSEACTIVATE)
        {
            handled = true;
            return new IntPtr(NativeMethods.MA_NOACTIVATE);
        }
        return IntPtr.Zero;
    }

    public void UpdateState(LookupState state, bool isFavorite = false)
    {
        var previous = _currentState;
        _currentState = state;
        _isFavorite = isFavorite;
        _autoHideTimer.Stop();

        switch (state)
        {
            case LookupState.Loading loading:
                _isExpanded = true;
                SourceLine.Visibility = Visibility.Visible;
                PhoneticText.Visibility = Visibility.Collapsed;
                TagsList.Visibility = Visibility.Collapsed;
                TitleText.FontSize = 24;
                TitleText.Text = loading.Request.Text.Length > 28
                    ? loading.Request.Text[..28] + "…"
                    : loading.Request.Text;
                PhoneticText.Text = string.Empty;
                SpeakButton.Visibility = Visibility.Collapsed;
                FavoriteButton.Visibility = Visibility.Collapsed;
                TagsList.ItemsSource = null;
                SegmentsList.ItemsSource = null;
                SegmentsList.Visibility = Visibility.Collapsed;
                OriginText.Visibility = Visibility.Collapsed;
                OriginalSentenceText.Visibility = Visibility.Collapsed;
                BodyText.Text = "正在查询…";
                NoteText.Visibility = Visibility.Collapsed;
                SourceText.Text = loading.Request.Mode == LookupMode.Translate ? "翻译" : "查词";
                CompactSummaryText.Visibility = Visibility.Collapsed;
                ExpandedContent.Visibility = Visibility.Visible;
                break;

            case LookupState.Result resultState:
                RenderResult(resultState.Value);
                break;

            case LookupState.Failure failure:
                _isExpanded = true;
                SourceLine.Visibility = Visibility.Visible;
                PhoneticText.Visibility = Visibility.Collapsed;
                TagsList.Visibility = Visibility.Collapsed;
                TitleText.FontSize = 24;
                TitleText.Text = "查词提示";
                PhoneticText.Text = string.Empty;
                SpeakButton.Visibility = Visibility.Collapsed;
                FavoriteButton.Visibility = Visibility.Collapsed;
                TagsList.ItemsSource = null;
                SegmentsList.ItemsSource = null;
                SegmentsList.Visibility = Visibility.Collapsed;
                OriginText.Visibility = Visibility.Collapsed;
                OriginalSentenceText.Visibility = Visibility.Collapsed;
                BodyText.Text = failure.Message;
                NoteText.Visibility = Visibility.Collapsed;
                SourceText.Text = _preferences.LookupHotKey.Display;
                ExpandedContent.Visibility = Visibility.Visible;
                CompactSummaryText.Visibility = Visibility.Collapsed;
                break;
        }

        ApplyPosition(state.Request);
        if (!IsVisible)
        {
            Show();
            DesktopAppearance.Reveal(PanelBody);
        }
        else if (previous is LookupState.Loading && state is LookupState.Result && _isExpanded)
        {
            DesktopAppearance.Reveal(ExpandedContent);
        }

        // Show() 之后才拿到真实的 SizeToContent 尺寸，需重算一次位置与居中。
        UpdateLayout();
        ApplyPosition(state.Request);

        SetTransparentPassThrough(false);
        _avoidanceTimer.Start();
        RestartHideTimerIfEligible();
    }

    public void HidePanel(bool cancelActive)
    {
        _autoHideTimer.Stop();
        _avoidanceTimer.Stop();
        _isPointerInside = false;
        SetTransparentPassThrough(false);
        if (IsVisible) Hide();
        if (cancelActive) Dismissed?.Invoke();
    }

    /// <summary>
    /// 判断物理屏幕坐标是否落在本面板内（供划词监听排除自家窗口）。
    /// </summary>
    public bool ContainsScreenPoint(int x, int y) => ContainsPhysicalPoint(x, y, margin: 0);

    private bool ContainsPhysicalPoint(int x, int y, double margin)
    {
        if (!IsVisible) return false;

        var (scaleX, scaleY) = GetScaleForPoint(new NativeMethods.POINT { X = x, Y = y });
        var left = Left * scaleX - margin;
        var top = Top * scaleY - margin;
        var right = left + ActualWidth * scaleX + margin * 2;
        var bottom = top + ActualHeight * scaleY + margin * 2;

        return x >= left && x <= right && y >= top && y <= bottom;
    }

    private void RenderResult(LookupResult res)
    {
        _isExpanded = _preferences.PanelStyle == PanelStyle.Floating
                      || res.Kind == TextKind.Sentence
                      || _isPointerInside;

        TitleText.Text = string.IsNullOrEmpty(res.Title) ? "翻译结果" : res.Title;

        // 词典里的音标可能已自带斜杠，先去掉再统一包一层，避免出现 //...//。
        var phonetic = (res.Phonetic ?? string.Empty).Trim().Trim('/').Trim();
        PhoneticText.Text = phonetic.Length == 0 ? string.Empty : $"/{phonetic}/";

        var hasWord = res.NotebookWord is not null;
        SpeakButton.Visibility = hasWord ? Visibility.Visible : Visibility.Collapsed;
        FavoriteButton.Visibility = hasWord ? Visibility.Visible : Visibility.Collapsed;
        FavoriteButton.IsEnabled = SaveFavoriteAsync is not null && res.NotebookWord is { } word && !_pendingFavorites.Contains(word);
        UpdateFavoriteButton();

        TagsList.ItemsSource = res.Tags.Count > 0 ? res.Tags : null;
        TagsList.Visibility = res.Tags.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        if (res.Segments.Count > 0)
        {
            SegmentsList.ItemsSource = res.Segments.Select(CreateChip).ToArray();
            SegmentsList.Visibility = Visibility.Visible;
        }
        else
        {
            SegmentsList.ItemsSource = null;
            SegmentsList.Visibility = Visibility.Collapsed;
        }

        if (!string.IsNullOrWhiteSpace(res.Origin))
        {
            OriginText.Text = $"词源：{res.Origin}";
            OriginText.Visibility = Visibility.Visible;
        }
        else
        {
            OriginText.Visibility = Visibility.Collapsed;
        }

        if (!string.IsNullOrWhiteSpace(res.OriginalText))
        {
            OriginalSentenceText.Text = res.OriginalText;
            OriginalSentenceText.Visibility = Visibility.Visible;
        }
        else
        {
            OriginalSentenceText.Visibility = Visibility.Collapsed;
        }

        BodyText.Text = res.Body;

        if (!string.IsNullOrWhiteSpace(res.Note))
        {
            NoteText.Text = res.Note;
            NoteText.Visibility = Visibility.Visible;
        }
        else
        {
            NoteText.Visibility = Visibility.Collapsed;
        }

        SourceText.Text = $"{res.Source} · {_preferences.LookupHotKey.Display}";

        var firstLine = res.Body.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? string.Empty;
        CompactSummaryText.Text = firstLine;
        ApplyExpansionState();
    }

    private void ApplyExpansionState()
    {
        var wasCompact = ExpandedContent.Visibility != Visibility.Visible;
        TitleText.FontSize = _isExpanded ? 30 : 19;
        SourceLine.Visibility = _isExpanded ? Visibility.Visible : Visibility.Collapsed;
        PhoneticText.Visibility = _isExpanded && !string.IsNullOrEmpty(PhoneticText.Text)
            ? Visibility.Visible : Visibility.Collapsed;
        if (_isExpanded)
        {
            ExpandedContent.Visibility = Visibility.Visible;
            CompactSummaryText.Visibility = Visibility.Collapsed;
            if (wasCompact && IsVisible) DesktopAppearance.Reveal(ExpandedContent);
        }
        else
        {
            ExpandedContent.Visibility = Visibility.Collapsed;
            CompactSummaryText.Visibility = Visibility.Visible;
        }

        if (IsVisible && _preferences.PanelStyle == PanelStyle.Notch)
        {
            // 展开/收起后宽度会变，需重新居中，否则顶部模拟刘海会偏到一边。
            UpdateLayout();
            CenterOnCurrentMonitorTop();
        }
    }

    private void CenterOnCurrentMonitorTop()
    {
        var (info, scaleX, scaleY) = GetMonitorMetrics(PanelCenterPoint());
        var workLeft = info.rcWork.Left / scaleX;
        var workTop = info.rcWork.Top / scaleY;
        var workRight = info.rcWork.Right / scaleX;
        var width = ActualWidth > 0 ? ActualWidth : 320;

        Left = workLeft + Math.Max(0, (workRight - workLeft - width) / 2.0);
        Top = workTop;
    }

    private NativeMethods.POINT PanelCenterPoint()
    {
        var centerX = Left + ActualWidth / 2.0;
        var centerY = Top + ActualHeight / 2.0;

        // 先按 1.0 比例粗定位找到显示器，再用该显示器真实 DPI 精确换算。
        var (scaleX, scaleY) = GetScaleForPoint(new NativeMethods.POINT
        {
            X = (int)Math.Round(centerX),
            Y = (int)Math.Round(centerY)
        });

        return new NativeMethods.POINT
        {
            X = (int)Math.Round(centerX * scaleX),
            Y = (int)Math.Round(centerY * scaleY)
        };
    }

    private void ApplyPosition(LookupRequest request)
    {
        NativeMethods.POINT pt;
        if (request.HasAnchor)
        {
            pt = new NativeMethods.POINT { X = request.AnchorX, Y = request.AnchorY };
        }
        else
        {
            NativeMethods.GetCursorPos(out pt);
        }

        // 用目标显示器的真实 DPI，而不是面板当前所在屏的 DPI，否则跨屏（混缩放）会算错。
        var (info, scaleX, scaleY) = GetMonitorMetrics(pt);
        var workLeft = info.rcWork.Left / scaleX;
        var workTop = info.rcWork.Top / scaleY;
        var workRight = info.rcWork.Right / scaleX;
        var workBottom = info.rcWork.Bottom / scaleY;

        // 高缩放或长释义时仍可滚动读完，并在测量后按实际尺寸定位。
        RootBorder.MaxWidth = Math.Clamp(workRight - workLeft - 16, 1, 500);
        RootBorder.MinWidth = Math.Min(258, RootBorder.MaxWidth);
        RootBorder.CornerRadius = _preferences.PanelStyle == PanelStyle.Notch
            ? new CornerRadius(0, 0, 23, 23) : new CornerRadius(22);
        PanelScroll.MaxHeight = Math.Max(1, workBottom - workTop - 44);
        UpdateLayout();

        var width = ActualWidth > 0 ? ActualWidth : 320;
        var height = ActualHeight > 0 ? ActualHeight : 140;

        if (_preferences.PanelStyle == PanelStyle.Notch)
        {
            Left = workLeft + Math.Max(0, (workRight - workLeft - width) / 2.0);
            Top = workTop;
        }
        else
        {
            var anchorX = pt.X / scaleX;
            var anchorY = pt.Y / scaleY;

            var targetLeft = anchorX + 16;
            var targetTop = anchorY + 16;

            if (targetLeft + width > workRight - 8) targetLeft = anchorX - width - 12;
            if (targetTop + height > workBottom - 8) targetTop = anchorY - height - 12;

            Left = Math.Max(workLeft + 8, targetLeft);
            Top = Math.Max(workTop + 8, targetTop);
        }
    }

    private static (NativeMethods.MONITORINFO Info, double ScaleX, double ScaleY) GetMonitorMetrics(NativeMethods.POINT point)
    {
        var info = new NativeMethods.MONITORINFO { cbSize = Marshal.SizeOf<NativeMethods.MONITORINFO>() };
        var monitor = NativeMethods.MonitorFromPoint(point, NativeMethods.MONITOR_DEFAULTTONEAREST);
        NativeMethods.GetMonitorInfo(monitor, ref info);

        var (scaleX, scaleY) = GetScaleForPoint(point);
        return (info, scaleX, scaleY);
    }

    private static (double ScaleX, double ScaleY) GetScaleForPoint(NativeMethods.POINT point)
    {
        var monitor = NativeMethods.MonitorFromPoint(point, NativeMethods.MONITOR_DEFAULTTONEAREST);
        if (NativeMethods.GetDpiForMonitor(monitor, NativeMethods.MDT_EFFECTIVE_DPI, out var dpiX, out var dpiY) == 0 &&
            dpiX > 0 && dpiY > 0)
        {
            return (dpiX / 96.0, dpiY / 96.0);
        }
        return (1.0, 1.0);
    }

    private void RestartHideTimerIfEligible()
    {
        _autoHideTimer.Stop();
        if (!_preferences.AutoHideEnabled || _isPointerInside) return;
        // Loading 态不启动自动收起计时，避免慢翻译被中断
        if (_currentState is LookupState.Loading or null) return;

        _autoHideTimer.Interval = TimeSpan.FromSeconds(Math.Clamp(_preferences.AutoHideSeconds, 2.0, 30.0));
        _autoHideTimer.Start();
    }

    private void UpdateTopBarAvoidance()
    {
        if (!IsVisible || _preferences.PanelStyle != PanelStyle.Notch || _isExpanded || _isPointerInside)
        {
            SetTransparentPassThrough(false);
            return;
        }

        var fg = NativeMethods.GetForegroundWindow();
        if (fg == IntPtr.Zero || !NativeMethods.IsZoomed(fg) || !NativeMethods.GetCursorPos(out var pt))
        {
            SetTransparentPassThrough(false);
            return;
        }

        // 光标必须与面板在同块显示器上，否则多屏下会在错误的屏上误判避让。
        var cursorMonitor = NativeMethods.MonitorFromPoint(pt, NativeMethods.MONITOR_DEFAULTTONEAREST);
        var panelMonitor = NativeMethods.MonitorFromPoint(PanelCenterPoint(), NativeMethods.MONITOR_DEFAULTTONEAREST);
        if (cursorMonitor != panelMonitor)
        {
            SetTransparentPassThrough(false);
            return;
        }

        var (scaleX, scaleY) = GetScaleForPoint(pt);
        var leftPhysical = Left * scaleX;
        var rightPhysical = leftPhysical + ActualWidth * scaleX;
        var insidePanelX = pt.X >= leftPhysical - 8 && pt.X <= rightPhysical + 8;
        var nearTopBar = pt.Y / scaleY <= Top + 36;

        // 关键在于「光标确实在面板水平范围之外」：一旦鼠标真的要碰面板，立即恢复可交互，
        // 避免进入避让后因为不再收到 MouseEnter 而把自己锁死。
        SetTransparentPassThrough(nearTopBar && !insidePanelX);
    }

    private void SetTransparentPassThrough(bool passThrough)
    {
        if (_hwnd == IntPtr.Zero) return;
        var exStyle = NativeMethods.GetWindowLongPtr(_hwnd, NativeMethods.GWL_EXSTYLE).ToInt64();
        var hasTransparent = (exStyle & NativeMethods.WS_EX_TRANSPARENT) != 0;
        if (passThrough == hasTransparent) return;

        if (passThrough)
        {
            exStyle |= NativeMethods.WS_EX_TRANSPARENT;
            Opacity = 0.25;
        }
        else
        {
            exStyle &= ~NativeMethods.WS_EX_TRANSPARENT;
            Opacity = 1.0;
        }
        NativeMethods.SetWindowLongPtr(_hwnd, NativeMethods.GWL_EXSTYLE, new IntPtr(exStyle));
    }

    private static SegmentChipVm CreateChip(Segment segment) => new(segment.Label, segment.Gloss,
        segment.Role switch { "prefix" => "前缀", "suffix" => "后缀", "root" => "词根", _ => "词素" },
        segment.Role == "root");

    private void UpdateFavoriteButton()
    {
        FavoriteButton.Content = _isFavorite ? "\uE523" : "\uE064";
        FavoriteButton.ToolTip = _isFavorite ? "取消收藏" : "收藏单词";
        FavoriteButton.Tag = _isFavorite ? "saved" : null;
        System.Windows.Automation.AutomationProperties.SetName(FavoriteButton, (string)FavoriteButton.ToolTip);
    }

    private void SpeakButton_Click(object sender, RoutedEventArgs e)
    {
        if (_currentState is LookupState.Result r && r.Value.NotebookWord is { } word)
        {
            SpeakRequested?.Invoke(word);
        }
    }

    private async void FavoriteButton_Click(object sender, RoutedEventArgs e)
    {
        var save = SaveFavoriteAsync;
        if (save is null || _currentState is not LookupState.Result result ||
            result.Value.NotebookWord is not { } word || !_pendingFavorites.Add(word)) return;

        var requested = !_isFavorite;
        FavoriteButton.IsEnabled = false;
        try
        {
            await save(word, requested);
            if (ShowingWord(word))
            {
                _isFavorite = requested;
                UpdateFavoriteButton();
                NoteText.Text = (_currentState as LookupState.Result)?.Value.Note ?? string.Empty;
                NoteText.Visibility = string.IsNullOrWhiteSpace(NoteText.Text) ? Visibility.Collapsed : Visibility.Visible;
            }
        }
        catch (Exception ex)
        {
            FileLog.Write($"收藏更新失败: {ex.Message}");
            if (ShowingWord(word))
            {
                NoteText.Text = "收藏更新失败，请重试。";
                NoteText.Visibility = Visibility.Visible;
                _isExpanded = true;
                ApplyExpansionState();
            }
        }
        finally
        {
            _pendingFavorites.Remove(word);
            if (ShowingWord(word)) FavoriteButton.IsEnabled = true;
        }
    }

    private bool ShowingWord(string word) =>
        _currentState is LookupState.Result current &&
        string.Equals(current.Value.NotebookWord, word, StringComparison.OrdinalIgnoreCase);

    private void CloseButton_Click(object sender, RoutedEventArgs e)
    {
        HidePanel(cancelActive: true);
    }
}
