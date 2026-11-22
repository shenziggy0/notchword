using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using Englishwords.Win.Interop;

namespace Englishwords.Win.Views;

/// <summary>
/// 区域框选遮罩。多屏（含混合 DPI）时为每块显示器各建一个窗口，
/// 任一屏完成拖选或按 <c>Esc</c> 会同步关闭全部遮罩并返回真实物理像素矩形。
/// </summary>
public partial class RegionPickerWindow : Window
{
    private readonly System.Drawing.Rectangle _physicalBounds;
    private readonly Action<Int32Rect?> _onCompleted;

    private System.Windows.Point _startPoint;
    private bool _isDragging;
    private bool _completed;

    public Int32Rect? SelectedPhysicalRect { get; private set; }

    public RegionPickerWindow()
        : this(System.Windows.Forms.Screen.PrimaryScreen?.Bounds ?? new System.Drawing.Rectangle(0, 0, 1920, 1080), null)
    {
    }

    internal RegionPickerWindow(System.Drawing.Rectangle physicalBounds, Action<Int32Rect?>? onCompleted)
    {
        _physicalBounds = physicalBounds;
        _onCompleted = onCompleted ?? (_ => { });

        InitializeComponent();

        WindowStartupLocation = WindowStartupLocation.Manual;
        ShowInTaskbar = false;

        // 先用 DIP 近似把窗口放到目标屏，Loaded 后再用 SetWindowPos 按物理像素精确铺满。
        var (scaleX, scaleY) = GetScaleForBounds(physicalBounds);
        Left = physicalBounds.Left / scaleX;
        Top = physicalBounds.Top / scaleY;
        Width = Math.Max(1, physicalBounds.Width / scaleX);
        Height = Math.Max(1, physicalBounds.Height / scaleY);

        Loaded += OnLoaded;

        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                e.Handled = true;
                Finish(null);
            }
        };

        MouseLeftButtonDown += (_, e) =>
        {
            _startPoint = e.GetPosition(OverlayCanvas);
            _isDragging = true;
            Canvas.SetLeft(SelectionRect, _startPoint.X);
            Canvas.SetTop(SelectionRect, _startPoint.Y);
            SelectionRect.Width = 0;
            SelectionRect.Height = 0;
            SelectionRect.Visibility = Visibility.Visible;
            OverlayCanvas.CaptureMouse();
        };

        MouseMove += (_, e) =>
        {
            if (!_isDragging) return;
            var cur = e.GetPosition(OverlayCanvas);
            var x = Math.Min(_startPoint.X, cur.X);
            var y = Math.Min(_startPoint.Y, cur.Y);
            Canvas.SetLeft(SelectionRect, x);
            Canvas.SetTop(SelectionRect, y);
            SelectionRect.Width = Math.Abs(cur.X - _startPoint.X);
            SelectionRect.Height = Math.Abs(cur.Y - _startPoint.Y);
        };

        MouseLeftButtonUp += (_, e) =>
        {
            if (!_isDragging) return;
            _isDragging = false;
            OverlayCanvas.ReleaseMouseCapture();

            var cur = e.GetPosition(OverlayCanvas);
            var x = Math.Min(_startPoint.X, cur.X);
            var y = Math.Min(_startPoint.Y, cur.Y);
            var w = Math.Abs(cur.X - _startPoint.X);
            var h = Math.Abs(cur.Y - _startPoint.Y);

            if (w >= 8 && h >= 8)
            {
                // PerMonitorV2 下 PointToScreen 返回的就是物理像素
                var topLeftScreen = PointToScreen(new System.Windows.Point(x, y));
                var bottomRightScreen = PointToScreen(new System.Windows.Point(x + w, y + h));
                Finish(new Int32Rect(
                    (int)Math.Round(topLeftScreen.X),
                    (int)Math.Round(topLeftScreen.Y),
                    Math.Max(1, (int)Math.Round(bottomRightScreen.X - topLeftScreen.X)),
                    Math.Max(1, (int)Math.Round(bottomRightScreen.Y - topLeftScreen.Y))));
            }
            else
            {
                Finish(null);
            }
        };
    }

    /// <summary>
    /// 为每块显示器创建一个遮罩并阻塞等待用户框选，返回物理像素矩形（取消时为 <c>null</c>）。
    /// </summary>
    public static Int32Rect? PickRegion()
    {
        var screens = System.Windows.Forms.Screen.AllScreens;
        if (screens.Length == 0) return null;

        var result = new Int32Rect?();
        var sync = new object();
        var finished = false;
        var windows = new List<RegionPickerWindow>(screens.Length);

        void Complete(Int32Rect? rect)
        {
            lock (sync)
            {
                if (finished) return;
                finished = true;
                result = rect;
            }

            foreach (var window in windows)
            {
                try
                {
                    if (window.IsVisible) window.Close();
                }
                catch
                {
                    // 已关闭的窗口忽略
                }
            }
        }

        foreach (var screen in screens)
        {
            windows.Add(new RegionPickerWindow(screen.Bounds, Complete));
        }

        // 除首个窗口外先非模态显示，首个用 ShowDialog 承担消息循环
        for (var i = 1; i < windows.Count; i++)
        {
            windows[i].Show();
        }

        windows[0].ShowDialog();

        // 兜底：确保所有遮罩都已关闭
        foreach (var window in windows)
        {
            try
            {
                if (window.IsVisible) window.Close();
            }
            catch
            {
                // 忽略
            }
        }

        return result;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        NativeMethods.SetWindowPos(
            hwnd,
            NativeMethods.HWND_TOPMOST,
            _physicalBounds.Left,
            _physicalBounds.Top,
            _physicalBounds.Width,
            _physicalBounds.Height,
            NativeMethods.SWP_SHOWWINDOW);

        UpdateLayout();
        OverlayCanvas.Width = ActualWidth;
        OverlayCanvas.Height = ActualHeight;

        Activate();
        Focus();
    }

    private void Finish(Int32Rect? rect)
    {
        if (_completed) return;
        _completed = true;

        SelectedPhysicalRect = rect;
        try
        {
            _onCompleted(rect);
        }
        finally
        {
            if (IsVisible) Close();
        }
    }

    private static (double ScaleX, double ScaleY) GetScaleForBounds(System.Drawing.Rectangle bounds)
    {
        var point = new NativeMethods.POINT
        {
            X = bounds.Left + Math.Max(1, bounds.Width / 2),
            Y = bounds.Top + Math.Max(1, bounds.Height / 2)
        };

        var monitor = NativeMethods.MonitorFromPoint(point, NativeMethods.MONITOR_DEFAULTTONEAREST);
        if (NativeMethods.GetDpiForMonitor(monitor, NativeMethods.MDT_EFFECTIVE_DPI, out var dpiX, out var dpiY) == 0 &&
            dpiX > 0 && dpiY > 0)
        {
            return (dpiX / 96.0, dpiY / 96.0);
        }

        return (1.0, 1.0);
    }
}
