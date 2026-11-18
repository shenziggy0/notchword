using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Automation;
using Englishwords.Core.Config;
using Englishwords.Core.Lookup;

namespace Englishwords.Win.Interop;

/// <summary>
/// 选区采集器：优先通过 Windows UIAutomation 只读读取选区，
/// 失败时在进程安全校验后降级使用剪贴板模拟 <c>Ctrl+C</c> 并在 150ms 内还原原剪贴板文本。
/// </summary>
public sealed class SelectionCapture
{
    private readonly Preferences _preferences;

    public SelectionCapture(Preferences preferences)
    {
        _preferences = preferences;
    }

    public bool IsForegroundExcluded(out string processName)
    {
        processName = string.Empty;
        var hwnd = NativeMethods.GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return false;

        _ = NativeMethods.GetWindowThreadProcessId(hwnd, out var pid);
        if (pid == 0) return false;

        try
        {
            using var proc = Process.GetProcessById((int)pid);
            processName = proc.ProcessName;
            return _preferences.ExcludedProcesses.Any(
                ex => string.Equals(ex, proc.ProcessName, StringComparison.OrdinalIgnoreCase));
        }
        catch
        {
            return false;
        }
    }

    public async Task<(string Text, string? Note)> CaptureAsync(LookupTrigger trigger)
    {
        if (IsForegroundExcluded(out var procName))
        {
            if (trigger.IsPassive()) return (string.Empty, null);
            return (string.Empty, $"前台应用 {procName} 已加入排除名单，已跳过取词。");
        }

        // 1. 优先尝试 UIAutomation 只读读取选区
        var uiaText = TryReadViaUIAutomation();
        if (!string.IsNullOrWhiteSpace(uiaText))
        {
            return (uiaText, null);
        }

        // 2. 降级：模拟 Ctrl+C 并立即备份还原剪贴板
        var clipText = await TryReadViaClipboardFallbackAsync().ConfigureAwait(false);
        if (!string.IsNullOrWhiteSpace(clipText))
        {
            return (clipText, "当前控件未暴露选区，已改用剪贴板读取");
        }

        return (string.Empty, null);
    }

    private static string? TryReadViaUIAutomation()
    {
        try
        {
            var focused = AutomationElement.FocusedElement;
            if (focused is null) return null;

            if (focused.TryGetCurrentPattern(TextPattern.Pattern, out var patternObj) &&
                patternObj is TextPattern textPattern)
            {
                var ranges = textPattern.GetSelection();
                if (ranges is { Length: > 0 })
                {
                    var selected = ranges[0].GetText(500);
                    if (!string.IsNullOrWhiteSpace(selected)) return selected;
                }
            }
        }
        catch
        {
            // 部分 Electron / 画布应用不暴露 UIA TextPattern，静默回退
        }
        return null;
    }

    private static async Task<string?> TryReadViaClipboardFallbackAsync()
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher is null) return null;

        string? previousText = null;
        var hadText = false;
        uint seqBefore = 0;

        await dispatcher.InvokeAsync(() =>
        {
            seqBefore = NativeMethods.GetClipboardSequenceNumber();
            try
            {
                if (System.Windows.Clipboard.ContainsText())
                {
                    previousText = System.Windows.Clipboard.GetText();
                    hadText = true;
                }
            }
            catch
            {
                // 剪贴板暂时被其他进程占用
            }
        });

        SendCtrlC();

        // 最长等待 150ms 观察剪贴板序号变化
        var changed = false;
        for (var i = 0; i < 15; i++)
        {
            await Task.Delay(10).ConfigureAwait(false);
            if (NativeMethods.GetClipboardSequenceNumber() != seqBefore)
            {
                changed = true;
                break;
            }
        }

        if (!changed) return null;

        string? captured = null;
        await dispatcher.InvokeAsync(() =>
        {
            try
            {
                if (System.Windows.Clipboard.ContainsText())
                {
                    captured = System.Windows.Clipboard.GetText();
                }

                // 立即还原原剪贴板内容
                if (hadText && previousText is not null)
                {
                    System.Windows.Clipboard.SetText(previousText);
                }
                else
                {
                    System.Windows.Clipboard.Clear();
                }
            }
            catch
            {
                // 还原失败不阻断返回
            }
        });

        return captured;
    }

    private static void SendCtrlC()
    {
        // 先释放可能按住的 Alt/Shift/Win 修饰键，避免组合成 Alt+Ctrl+C
        var inputs = new List<NativeMethods.INPUT>
        {
            KeyEvent(NativeMethods.VK_MENU, keyUp: true),
            KeyEvent(NativeMethods.VK_SHIFT, keyUp: true),
            KeyEvent(NativeMethods.VK_LWIN, keyUp: true),
            KeyEvent(NativeMethods.VK_RWIN, keyUp: true),
            KeyEvent(NativeMethods.VK_CONTROL, keyUp: false),
            KeyEvent(NativeMethods.VK_C, keyUp: false),
            KeyEvent(NativeMethods.VK_C, keyUp: true),
            KeyEvent(NativeMethods.VK_CONTROL, keyUp: true)
        };

        var arr = inputs.ToArray();
        _ = NativeMethods.SendInput((uint)arr.Length, arr, Marshal.SizeOf<NativeMethods.INPUT>());
    }

    private static NativeMethods.INPUT KeyEvent(ushort vk, bool keyUp) => new()
    {
        type = NativeMethods.INPUT_KEYBOARD,
        U = new NativeMethods.INPUTUNION
        {
            ki = new NativeMethods.KEYBDINPUT
            {
                wVk = vk,
                dwFlags = keyUp ? NativeMethods.KEYEVENTF_KEYUP : 0
            }
        }
    };
}
