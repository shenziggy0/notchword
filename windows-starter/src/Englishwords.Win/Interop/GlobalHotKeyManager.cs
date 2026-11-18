using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Interop;
using Englishwords.Core.Config;

namespace Englishwords.Win.Interop;

/// <summary>
/// 全局热键与 Esc 键管理器。
/// </summary>
public sealed class GlobalHotKeyManager : IDisposable
{
    private readonly HwndSource _source;
    private readonly Dictionary<int, HotKeyAction> _registered = new();
    private readonly NativeMethods.LowLevelHookProc _kbdProc;
    private IntPtr _kbdHook = IntPtr.Zero;

    public event Action<HotKeyAction>? HotKeyPressed;
    public event Action? EscapePressed;

    /// <summary>
    /// 仅当面板处于显示状态时，才消费全局 Esc 通知关闭，避免干扰其他软件。
    /// </summary>
    public Func<bool>? ShouldHandleEscape { get; set; }

    public GlobalHotKeyManager()
    {
        var parameters = new HwndSourceParameters("EnglishwordsHotKeySink")
        {
            Width = 0,
            Height = 0,
            WindowStyle = 0
        };
        _source = new HwndSource(parameters);
        _source.AddHook(WndProc);

        _kbdProc = KeyboardHookCallback;
        using var curProcess = Process.GetCurrentProcess();
        using var curModule = curProcess.MainModule;
        _kbdHook = NativeMethods.SetWindowsHookEx(
            NativeMethods.WH_KEYBOARD_LL,
            _kbdProc,
            NativeMethods.GetModuleHandle(curModule?.ModuleName),
            0);
    }

    public List<string> ApplyPreferences(Preferences preferences)
    {
        UnregisterAll();
        var conflicts = new List<string>();

        TryRegister(HotKeyAction.Lookup, preferences.LookupHotKey, "查词热键", conflicts);
        TryRegister(HotKeyAction.Translate, preferences.TranslateHotKey, "翻译热键", conflicts);
        TryRegister(HotKeyAction.RegionOcr, preferences.RegionOcrHotKey, "区域取词热键", conflicts);

        return conflicts;
    }

    private void TryRegister(HotKeyAction action, HotKeySpec spec, string label, List<string> conflicts)
    {
        if (spec.VirtualKey == 0) return;
        var id = (int)action + 1;
        if (NativeMethods.RegisterHotKey(_source.Handle, id, spec.Modifiers, spec.VirtualKey))
        {
            _registered[id] = action;
        }
        else
        {
            conflicts.Add($"{label} ({spec.Display}) 已被其他程序占用");
        }
    }

    public void UnregisterAll()
    {
        foreach (var id in _registered.Keys)
        {
            NativeMethods.UnregisterHotKey(_source.Handle, id);
        }
        _registered.Clear();
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == NativeMethods.WM_HOTKEY && _registered.TryGetValue(wParam.ToInt32(), out var action))
        {
            handled = true;
            HotKeyPressed?.Invoke(action);
        }
        return IntPtr.Zero;
    }

    private IntPtr KeyboardHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && wParam == (IntPtr)NativeMethods.WM_KEYDOWN)
        {
            var kbd = Marshal.PtrToStructure<NativeMethods.KBDLLHOOKSTRUCT>(lParam);
            if (kbd.vkCode == NativeMethods.VK_ESCAPE && (ShouldHandleEscape?.Invoke() ?? false))
            {
                System.Windows.Application.Current?.Dispatcher.BeginInvoke(() => EscapePressed?.Invoke());
            }
        }
        return NativeMethods.CallNextHookEx(_kbdHook, nCode, wParam, lParam);
    }

    public void Dispose()
    {
        UnregisterAll();
        if (_kbdHook != IntPtr.Zero)
        {
            NativeMethods.UnhookWindowsHookEx(_kbdHook);
            _kbdHook = IntPtr.Zero;
        }
        _source.RemoveHook(WndProc);
        _source.Dispose();
    }
}
