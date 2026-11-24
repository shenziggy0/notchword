using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Windows.UI.ViewManagement;
using TabControl = System.Windows.Controls.TabControl;
using WpfColor = System.Windows.Media.Color;
using WpfSystemColors = System.Windows.SystemColors;

namespace Englishwords.Win.Views;

/// <summary>在同一处把 Windows 的应用主题、对比度和透明效果映射到界面颜色。</summary>
internal sealed class DesktopAppearance : IDisposable
{
    private readonly System.Windows.Application _app;
    private readonly UISettings _settings = new();
    private bool _dark;

    public DesktopAppearance(System.Windows.Application app)
    {
        _app = app;
        Refresh();
        _settings.ColorValuesChanged += OnAppearanceChanged;
        _settings.AdvancedEffectsEnabledChanged += OnAppearanceChanged;
        SystemParameters.StaticPropertyChanged += OnSystemSettingChanged;
    }

    private void OnAppearanceChanged(UISettings sender, object args) => _app.Dispatcher.InvokeAsync(Refresh);

    private void OnSystemSettingChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(SystemParameters.HighContrast))
            _app.Dispatcher.InvokeAsync(Refresh);
    }

    private void Refresh()
    {
        var background = _settings.GetColorValue(UIColorType.Background);
        _dark = (background.R + background.G + background.B) < 3 * 128;
        var contrast = SystemParameters.HighContrast;
        var window = WpfSystemColors.WindowColor;
        var text = WpfSystemColors.WindowTextColor;
        var selected = WpfSystemColors.HighlightColor;
        var selectedText = WpfSystemColors.HighlightTextColor;

        void Set(string key, string light, string dark, WpfColor accessible)
        {
            var color = contrast ? accessible : (WpfColor)System.Windows.Media.ColorConverter.ConvertFromString(_dark ? dark : light);
            var brush = new SolidColorBrush(color);
            brush.Freeze();
            _app.Resources[key] = brush;
        }

        Set("CanvasBrush", "#F2F4F9", "#14161F", window);
        Set("SurfaceBrush", "#FFFFFF", "#212532", window);
        Set("TextBrush", "#151B2B", "#F4F6FF", text);
        Set("SecondaryBrush", "#505C73", "#BCC5DD", text);
        Set("RuleBrush", "#D9DEEA", "#3B4255", text);
        Set("AccentBrush", "#2458AD", "#A9C6FF", selected);
        Set("TintBrush", "#E5EDFF", "#2F405F", selected);
        Set("TintTextBrush", "#174C97", "#D2E1FF", selectedText);
        Set("ControlBrush", "#EBEFF7", "#323848", window);
        Set("HoverBrush", "#DFE7F6", "#3B4560", selected);
        Set("HoverTextBrush", "#151B2B", "#F4F6FF", selectedText);
        Set("SelectedBrush", "#FFFFFF", "#4C5875", selected);
        Set("SelectedTextBrush", "#183F85", "#FFFFFF", selectedText);
        Set("SwitchOffBrush", "#707D91", "#708098", text);
        Set("SwitchOnBrush", "#2860BD", "#4775D2", selected);
        Set("SwitchKnobBrush", "#FFFFFF", "#FFFFFF", window);
        Set("SwitchOnKnobBrush", "#FFFFFF", "#FFFFFF", selectedText);
        Set("FieldEdgeBrush", "#8590A6", "#758199", text);
        Set("PanelBrush", "#131722", "#131722", window);
        Set("PanelTextBrush", "#F4F6FF", "#F4F6FF", text);
        Set("PanelMutedBrush", "#C0C9DE", "#C0C9DE", text);
        Set("PanelAccentBrush", "#ACC9FF", "#ACC9FF", text);
        Set("PanelRuleBrush", "#465167", "#465167", text);
        Set("PanelControlBrush", "#2C3445", "#2C3445", window);
        Set("PanelTintBrush", "#2C426B", "#2C426B", selected);
        Set("PanelTintTextBrush", "#D7E5FF", "#D7E5FF", selectedText);
        Set("SelectionLineBrush", "#BCD5FF", "#BCD5FF", selected);
        Set("SelectionWashBrush", "#283775CC", "#283775CC", WpfColor.FromArgb(0, 0, 0, 0));

        void Material(string key, string solidKey, string lightTop, string lightBottom, string darkTop, string darkBottom)
        {
            if (contrast || !_settings.AdvancedEffectsEnabled)
            {
                _app.Resources[key] = _app.Resources[solidKey];
                return;
            }

            var top = (WpfColor)System.Windows.Media.ColorConverter.ConvertFromString(_dark ? darkTop : lightTop);
            var bottom = (WpfColor)System.Windows.Media.ColorConverter.ConvertFromString(_dark ? darkBottom : lightBottom);
            var material = new LinearGradientBrush(top, bottom, 78);
            material.Freeze();
            _app.Resources[key] = material;
        }

        Material("NavigationGlass", "ControlBrush", "#F5FFFFFF", "#C9D9E3F7", "#EB373E52", "#D2232634");
        Material("NotchGlass", "PanelControlBrush", "#F4394358", "#E4272E3C", "#F4394358", "#E4272E3C");
        foreach (Window openWindow in _app.Windows)
            ApplyTitleBar(openWindow);
    }

    public void ApplyTitleBar(Window window)
    {
        if (window.WindowStyle == WindowStyle.None) return;
        var handle = new WindowInteropHelper(window).Handle;
        if (handle == IntPtr.Zero) return;
        var dark = _dark && !SystemParameters.HighContrast ? 1 : 0;
        _ = DwmSetWindowAttribute(handle, 20, ref dark, sizeof(int)); // DWMWA_USE_IMMERSIVE_DARK_MODE
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr handle, int attribute, ref int value, int size);

    public void Dispose()
    {
        _settings.ColorValuesChanged -= OnAppearanceChanged;
        _settings.AdvancedEffectsEnabledChanged -= OnAppearanceChanged;
        SystemParameters.StaticPropertyChanged -= OnSystemSettingChanged;
    }

    public static void PageChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is not TabControl tabs || !tabs.IsLoaded || !ReferenceEquals(e.OriginalSource, tabs)) return;
        if (tabs.Template.FindName("PART_SelectedContentHost", tabs) is FrameworkElement content)
            Reveal(content);
        if (!MotionEnabled || e.RemovedItems.Count == 0 || e.AddedItems.Count == 0 ||
            e.RemovedItems[0] is not TabItem previous || e.AddedItems[0] is not TabItem selected ||
            selected.Template.FindName("SelectionPill", selected) is not FrameworkElement pill) return;

        // 标签文字留在原位。只移动选中底片，快速换页时从上一帧的位置接续。
        var previousPill = previous.Template.FindName("SelectionPill", previous) as FrameworkElement;
        var distance = previous.TranslatePoint(new System.Windows.Point(), selected).X
            + (previousPill?.RenderTransform.Value.OffsetX ?? 0);
        Slide(pill, distance);
    }

    public static void SwitchChanged(object sender, RoutedEventArgs e)
    {
        if (!MotionEnabled || e.OriginalSource is not System.Windows.Controls.CheckBox { IsLoaded: true } toggle ||
            toggle.Template.FindName("Knob", toggle) is not FrameworkElement knob) return;
        var distance = (toggle.IsChecked == true ? -17 : 17) + knob.RenderTransform.Value.OffsetX;
        Slide(knob, distance);
    }

    private static bool MotionEnabled => SystemParameters.ClientAreaAnimation && !SystemParameters.HighContrast;

    private static void Slide(UIElement element, double fromX)
    {
        var translate = new TranslateTransform();
        element.RenderTransform = translate;
        translate.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(fromX, 0, TimeSpan.FromMilliseconds(180))
        {
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }, FillBehavior = FillBehavior.Stop
        });
    }

    public static void Reveal(UIElement content)
    {
        if (!MotionEnabled)
        {
            content.BeginAnimation(UIElement.OpacityProperty, null);
            content.RenderTransform = Transform.Identity;
            return;
        }

        var duration = TimeSpan.FromMilliseconds(190);
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        var translate = new TranslateTransform();
        content.RenderTransform = translate;
        translate.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(5, 0, duration) { EasingFunction = ease, FillBehavior = FillBehavior.Stop });
        content.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0.45, 1, duration) { EasingFunction = ease, FillBehavior = FillBehavior.Stop });
    }
}
