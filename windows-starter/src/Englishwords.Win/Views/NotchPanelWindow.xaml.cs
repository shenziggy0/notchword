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

public sealed record SegmentChipVm(
    string Label,
    string GlossText,
    System.Windows.Media.Brush Background,
    System.Windows.Media.Brush BorderBrush,
    System.Windows.Media.Brush Foreground);

public partial class NotchPanelWindow : Window
{
    private readonly Preferences _preferences;
    private readonly DispatcherTimer _autoHideTimer;
    private readonly DispatcherTimer _avoidanceTimer;

    private LookupState? _currentState;
    private bool _isExpanded = true;
    private bool _isPointerInside;
    private bool _isFavorite;
    private IntPtr _hwnd;

    public event Action<string, bool>? FavoriteToggled;
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
        _currentState = state;
        _isFavorite = isFavorite;
        _autoHideTimer.Stop();

        switch (state)
        {
            case LookupState.Loading loading:
                _isExpanded = true;
                TitleText.Text = loading.Request.Text.Length > 28
                    ? loading.Request.Text[..28] + "…"
                    : loading.Request.Text;
                PhoneticText.Text = string.Empty;
                SpeakButton.Visibility = Visibility.Collapsed;
                FavoriteButton.Visibility = Visibility.Collapsed;
                TagsList.ItemsSource = null;
                SegmentsList.ItemsSource = null;
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
                TitleText.Text = "提示";
                PhoneticText.Text = string.Empty;
                SpeakButton.Visibility = Visibility.Collapsed;
                FavoriteButton.Visibility = Visibility.Collapsed;
                TagsList.ItemsSource = null;
                SegmentsList.ItemsSource = null;
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
        if (!IsVisible) Show();
        SetTransparentPassThrough(false);
        _avoidanceTimer.Start();
        RestartHideTimerIfEligible();
    }

    public void HidePanel(bool cancelActive)
    {
        _autoHideTimer.Stop();
        _avoidanceTimer.Stop();
        if (IsVisible) Hide();
        if (cancelActive) Dismissed?.Invoke();
    }

    private void RenderResult(LookupResult res)
    {
        _isExpanded = _preferences.PanelStyle == PanelStyle.Floating || res.Kind == TextKind.Sentence;

        TitleText.Text = string.IsNullOrEmpty(res.Title) ? "翻译结果" : res.Title;
        PhoneticText.Text = string.IsNullOrEmpty(res.Phonetic) ? string.Empty : $"/{res.Phonetic}/";

        var hasWord = res.NotebookWord is not null;
        SpeakButton.Visibility = hasWord ? Visibility.Visible : Visibility.Collapsed;
        FavoriteButton.Visibility = hasWord ? Visibility.Visible : Visibility.Collapsed;
        FavoriteButton.Content = _isFavorite ? "★" : "☆";

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
        if (_isExpanded)
        {
            ExpandedContent.Visibility = Visibility.Visible;
            CompactSummaryText.Visibility = Visibility.Collapsed;
        }
        else
        {
            ExpandedContent.Visibility = Visibility.Collapsed;
            CompactSummaryText.Visibility = Visibility.Visible;
        }
    }

    private void ApplyPosition(LookupRequest request)
    {
        UpdateLayout();

        NativeMethods.POINT pt;
        if (request.HasAnchor)
        {
            pt = new NativeMethods.POINT { X = request.AnchorX, Y = request.AnchorY };
        }
        else
        {
            NativeMethods.GetCursorPos(out pt);
        }

        var monitor = NativeMethods.MonitorFromPoint(pt, NativeMethods.MONITOR_DEFAULTTONEAREST);
        var info = new NativeMethods.MONITORINFO { cbSize = Marshal.SizeOf<NativeMethods.MONITORINFO>() };
        NativeMethods.GetMonitorInfo(monitor, ref info);

        var dpi = VisualTreeHelper.GetDpi(this);
        var workLeft = info.rcWork.Left / dpi.DpiScaleX;
        var workTop = info.rcWork.Top / dpi.DpiScaleY;
        var workRight = info.rcWork.Right / dpi.DpiScaleX;
        var workBottom = info.rcWork.Bottom / dpi.DpiScaleY;

        var width = ActualWidth > 0 ? ActualWidth : 320;
        var height = ActualHeight > 0 ? ActualHeight : 140;

        if (_preferences.PanelStyle == PanelStyle.Notch)
        {
            Left = workLeft + Math.Max(0, (workRight - workLeft - width) / 2.0);
            Top = workTop + 4;
        }
        else
        {
            var anchorX = pt.X / dpi.DpiScaleX;
            var anchorY = pt.Y / dpi.DpiScaleY;

            var targetLeft = anchorX + 16;
            var targetTop = anchorY + 16;

            if (targetLeft + width > workRight - 8) targetLeft = anchorX - width - 12;
            if (targetTop + height > workBottom - 8) targetTop = anchorY - height - 12;

            Left = Math.Max(workLeft + 8, targetLeft);
            Top = Math.Max(workTop + 8, targetTop);
        }
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
        if (fg != IntPtr.Zero && NativeMethods.IsZoomed(fg) && NativeMethods.GetCursorPos(out var pt))
        {
            var dpi = VisualTreeHelper.GetDpi(this);
            var logicalY = pt.Y / dpi.DpiScaleY;
            var nearTopBar = logicalY <= Top + 36;
            SetTransparentPassThrough(nearTopBar);
            return;
        }

        SetTransparentPassThrough(false);
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

    private static SegmentChipVm CreateChip(Segment seg)
    {
        var (bg, border, fg) = seg.Role switch
        {
            "prefix" => ("#172554", "#1D4ED8", "#93C5FD"),
            "root" => ("#2E1065", "#7E22CE", "#D8B4FE"),
            "suffix" => ("#064E3B", "#047857", "#6EE7B7"),
            _ => ("#18181B", "#3F3F46", "#E4E4E7")
        };

        var converter = new BrushConverter();
        return new SegmentChipVm(
            seg.Label,
            string.IsNullOrWhiteSpace(seg.Gloss) ? string.Empty : seg.Gloss,
            (System.Windows.Media.Brush)converter.ConvertFromString(bg)!,
            (System.Windows.Media.Brush)converter.ConvertFromString(border)!,
            (System.Windows.Media.Brush)converter.ConvertFromString(fg)!);
    }

    private void SpeakButton_Click(object sender, RoutedEventArgs e)
    {
        if (_currentState is LookupState.Result r && r.Value.NotebookWord is { } word)
        {
            SpeakRequested?.Invoke(word);
        }
    }

    private void FavoriteButton_Click(object sender, RoutedEventArgs e)
    {
        if (_currentState is LookupState.Result r && r.Value.NotebookWord is { } word)
        {
            _isFavorite = !_isFavorite;
            FavoriteButton.Content = _isFavorite ? "★" : "☆";
            FavoriteToggled?.Invoke(word, _isFavorite);
        }
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e)
    {
        HidePanel(cancelActive: true);
    }
}
