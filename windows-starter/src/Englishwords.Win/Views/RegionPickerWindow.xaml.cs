using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace Englishwords.Win.Views;

public partial class RegionPickerWindow : Window
{
    private System.Windows.Point _startPoint;
    private bool _isDragging;

    public Int32Rect? SelectedPhysicalRect { get; private set; }

    public RegionPickerWindow()
    {
        InitializeComponent();

        Left = SystemParameters.VirtualScreenLeft;
        Top = SystemParameters.VirtualScreenTop;
        Width = SystemParameters.VirtualScreenWidth;
        Height = SystemParameters.VirtualScreenHeight;

        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                SelectedPhysicalRect = null;
                DialogResult = false;
                Close();
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
            var w = Math.Abs(cur.X - _startPoint.X);
            var h = Math.Abs(cur.Y - _startPoint.Y);
            Canvas.SetLeft(SelectionRect, x);
            Canvas.SetTop(SelectionRect, y);
            SelectionRect.Width = w;
            SelectionRect.Height = h;
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
                var topLeftScreen = PointToScreen(new System.Windows.Point(x, y));
                var bottomRightScreen = PointToScreen(new System.Windows.Point(x + w, y + h));
                SelectedPhysicalRect = new Int32Rect(
                    (int)Math.Round(topLeftScreen.X),
                    (int)Math.Round(topLeftScreen.Y),
                    Math.Max(1, (int)Math.Round(bottomRightScreen.X - topLeftScreen.X)),
                    Math.Max(1, (int)Math.Round(bottomRightScreen.Y - topLeftScreen.Y)));
                DialogResult = true;
            }
            else
            {
                SelectedPhysicalRect = null;
                DialogResult = false;
            }
            Close();
        };
    }
}
