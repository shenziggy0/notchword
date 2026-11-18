using System.Diagnostics;
using System.Runtime.InteropServices;
using Englishwords.Core.Config;
using Englishwords.Core.Lookup;

namespace Englishwords.Win.Interop;

/// <summary>
/// 低开销鼠标拖选划词监听器。
/// <para>
/// 拆分 <c>_lastObserved</c> 与 <c>_lastSubmitted</c>，仅在实际发出查询后更新 4 秒同词去重锚点。
/// </para>
/// </summary>
public sealed class SelectionMonitor : IDisposable
{
    private const int DragThresholdPixels = 12;
    private static readonly TimeSpan DeduplicateWindow = TimeSpan.FromSeconds(4);

    private readonly Preferences _preferences;
    private readonly SelectionCapture _capture;
    private readonly NativeMethods.LowLevelHookProc _mouseProc;

    private IntPtr _mouseHook = IntPtr.Zero;
    private NativeMethods.POINT _downPoint;
    private bool _isMouseDown;
    private CancellationTokenSource? _pendingCts;

    private string? _lastSubmittedText;
    private DateTimeOffset _lastSubmittedAt;

    public Func<LookupRequest, bool>? OnSubmit { get; set; }

    public SelectionMonitor(Preferences preferences, SelectionCapture capture)
    {
        _preferences = preferences;
        _capture = capture;
        _mouseProc = MouseHookCallback;
    }

    public void Start()
    {
        if (_mouseHook != IntPtr.Zero) return;
        using var curProcess = Process.GetCurrentProcess();
        using var curModule = curProcess.MainModule;
        _mouseHook = NativeMethods.SetWindowsHookEx(
            NativeMethods.WH_MOUSE_LL,
            _mouseProc,
            NativeMethods.GetModuleHandle(curModule?.ModuleName),
            0);
    }

    public void Stop()
    {
        _pendingCts?.Cancel();
        _pendingCts?.Dispose();
        _pendingCts = null;

        if (_mouseHook != IntPtr.Zero)
        {
            NativeMethods.UnhookWindowsHookEx(_mouseHook);
            _mouseHook = IntPtr.Zero;
        }
    }

    private IntPtr MouseHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && _preferences.SelectionLookupEnabled)
        {
            var msg = wParam.ToInt32();
            var info = Marshal.PtrToStructure<NativeMethods.MSLLHOOKSTRUCT>(lParam);

            if (msg == NativeMethods.WM_LBUTTONDOWN)
            {
                _downPoint = info.pt;
                _isMouseDown = true;
            }
            else if (msg == NativeMethods.WM_LBUTTONUP && _isMouseDown)
            {
                _isMouseDown = false;
                var dx = Math.Abs(info.pt.X - _downPoint.X);
                var dy = Math.Abs(info.pt.Y - _downPoint.Y);
                if (dx > DragThresholdPixels || dy > DragThresholdPixels)
                {
                    var upPoint = info.pt;
                    System.Windows.Application.Current?.Dispatcher.BeginInvoke(() => ScheduleCapture(upPoint));
                }
            }
        }
        return NativeMethods.CallNextHookEx(_mouseHook, nCode, wParam, lParam);
    }

    private void ScheduleCapture(NativeMethods.POINT anchor)
    {
        if (!_preferences.SelectionLookupEnabled) return;

        _pendingCts?.Cancel();
        _pendingCts?.Dispose();
        _pendingCts = new CancellationTokenSource();
        var token = _pendingCts.Token;

        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(80, token).ConfigureAwait(false);
                if (token.IsCancellationRequested || !_preferences.SelectionLookupEnabled) return;

                var (text, note) = await _capture.CaptureAsync(LookupTrigger.Selection).ConfigureAwait(false);
                if (token.IsCancellationRequested || string.IsNullOrWhiteSpace(text)) return;

                var normalized = text.Trim();
                var now = DateTimeOffset.UtcNow;
                if (string.Equals(normalized, _lastSubmittedText, StringComparison.Ordinal) &&
                    now - _lastSubmittedAt < DeduplicateWindow)
                {
                    return;
                }

                var req = new LookupRequest(
                    normalized,
                    LookupTrigger.Selection,
                    LookupMode.Lookup,
                    note,
                    anchor.X,
                    anchor.Y,
                    HasAnchor: true);

                var accepted = OnSubmit?.Invoke(req) ?? false;
                if (accepted)
                {
                    _lastSubmittedText = normalized;
                    _lastSubmittedAt = now;
                }
            }
            catch (OperationCanceledException)
            {
                // 被新拖选或手动停止取消
            }
        }, token);
    }

    public void Dispose() => Stop();
}
