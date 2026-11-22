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

    /// <summary>
    /// 串行化「模拟 Ctrl+C → 读取 → 还原」的剪贴板路径，防止并发取词互相覆盖剪贴板。
    /// </summary>
    private static readonly SemaphoreSlim ClipboardGate = new(1, 1);

    private const int UiaTimeoutMilliseconds = 250;

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

        // 自身进程（面板 / 设置 / 笔记本）永远不取词，否则点击自家窗口会反复触发查询。
        if (pid == Environment.ProcessId)
        {
            processName = "Englishwords";
            return true;
        }

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
        var uiaText = await TryReadViaUIAutomationAsync().ConfigureAwait(false);
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

    /// <summary>
    /// 在独立 STA 线程上跨进程读取 UIA 选区，并限时 250ms。
    /// <para>
    /// 跨进程 UIA 是 COM 调用，在 WPF UI 线程同步调用会阻塞消息循环、
    /// 严重时可被系统摘掉低级钩子。
    /// </para>
    /// </summary>
    private static async Task<string?> TryReadViaUIAutomationAsync()
    {
        var completion = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);

        var thread = new Thread(() =>
        {
            try
            {
                completion.TrySetResult(ReadSelectionOnStaThread());
            }
            catch
            {
                completion.TrySetResult(null);
            }
        })
        {
            IsBackground = true,
            Name = "Englishwords.UIA"
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();

        var finished = await Task.WhenAny(completion.Task, Task.Delay(UiaTimeoutMilliseconds)).ConfigureAwait(false);
        return finished == completion.Task ? await completion.Task.ConfigureAwait(false) : null;
    }

    private static string? ReadSelectionOnStaThread()
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

        // 同一时刻只允许一个模拟剪贴板流程，避免两个入口同时 Ctrl+C 互相覆盖。
        if (!await ClipboardGate.WaitAsync(TimeSpan.FromMilliseconds(500)).ConfigureAwait(false))
        {
            return null;
        }

        try
        {
            string? previousText = null;
            System.Windows.IDataObject? previousData = null;
            var hadText = false;
            var hadNonTextContent = false;
            var readFailed = false;
            uint seqBefore = 0;

            await dispatcher.InvokeAsync(() =>
            {
                seqBefore = NativeMethods.GetClipboardSequenceNumber();
                try
                {
                    var data = System.Windows.Clipboard.GetDataObject();
                    previousData = data;
                    if (data is null) return;

                    hadText = data.GetDataPresent(System.Windows.DataFormats.Text)
                              || data.GetDataPresent(System.Windows.DataFormats.UnicodeText);

                    // 图片 / 文件等非文本内容必须整体保留，否则还原时会清掉用户的原剪贴板。
                    hadNonTextContent = data.GetFormats(false).Length > 0 && !hadText;

                    if (hadText) previousText = System.Windows.Clipboard.GetText();
                }
                catch
                {
                    // 剪贴板被其他进程占用时直接中止降级，不能盲着 Ctrl+C 覆盖别人内容
                    readFailed = true;
                }
            });

            if (readFailed) return null;

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

                    if (hadNonTextContent && previousData is not null)
                    {
                        // 原剪贴板带图片/文件：整体还原原 DataObject，绝不调用 Clipboard.Clear()
                        System.Windows.Clipboard.SetDataObject(previousData, true);
                    }
                    else if (hadText && previousText is not null)
                    {
                        var current = System.Windows.Clipboard.ContainsText()
                            ? System.Windows.Clipboard.GetText()
                            : null;

                        // 仅在剪贴板里仍是刚复制的文本时还原，不覆盖用户期间的新拷贝
                        if (captured is not null && string.Equals(current, captured, StringComparison.Ordinal))
                        {
                            System.Windows.Clipboard.SetText(previousText);
                        }
                    }
                    else if (!hadText && !hadNonTextContent && captured is not null)
                    {
                        // 仅当原剪贴板本来就完全为空时才允许清空
                        var current = System.Windows.Clipboard.ContainsText()
                            ? System.Windows.Clipboard.GetText()
                            : null;
                        if (string.Equals(current, captured, StringComparison.Ordinal))
                        {
                            System.Windows.Clipboard.Clear();
                        }
                    }
                }
                catch
                {
                    // 还原失败不阻断返回
                }
            });

            return captured;
        }
        finally
        {
            ClipboardGate.Release();
        }
    }

    private static void SendCtrlC()
    {
        var inputs = new List<NativeMethods.INPUT>();

        // 只对实际处于按下状态的修饰键补发 KEYUP，避免凭空构建 Alt/Ctrl 组合干扰前台应用。
        ushort[] modifiers =
        [
            NativeMethods.VK_LMENU, NativeMethods.VK_RMENU,
            NativeMethods.VK_LSHIFT, NativeMethods.VK_RSHIFT,
            NativeMethods.VK_LWIN, NativeMethods.VK_RWIN
        ];

        foreach (var vk in modifiers)
        {
            if (NativeMethods.GetAsyncKeyState(vk) < 0)
            {
                inputs.Add(KeyEvent(vk, keyUp: true));
            }
        }

        inputs.Add(KeyEvent(NativeMethods.VK_CONTROL, keyUp: false));
        inputs.Add(KeyEvent(NativeMethods.VK_C, keyUp: false));
        inputs.Add(KeyEvent(NativeMethods.VK_C, keyUp: true));
        inputs.Add(KeyEvent(NativeMethods.VK_CONTROL, keyUp: true));

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
