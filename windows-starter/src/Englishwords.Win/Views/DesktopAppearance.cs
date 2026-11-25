using System.ComponentModel;
using Englishwords.Core.Config;
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
    private readonly Preferences _preferences;
    private bool _dark;

    public DesktopAppearance(System.Windows.Application app, Preferences preferences)
    {
        _app = app;
        _preferences = preferences;
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

    public void Refresh()
    {
        var background = _settings.GetColorValue(UIColorType.Background);
        _dark = _preferences.Theme switch
        {
            AppTheme.Dark => true,
            AppTheme.Light => false,
            _ => background.R + background.G + background.B < 3 * 128
        };
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

        Set("CanvasBrush", "#FBFBFB", "#101011", window);
        Set("SurfaceBrush", "#FFFFFF", "#141416", window);
        Set("TextBrush", "#1D1D1F", "#F0EFED", text);
        Set("SecondaryBrush", "#3C3C43", "#CFCECC", text);
        Set("RuleBrush", "#EAEAEA", "#2C2C2F", text);
        Set("FieldEdgeBrush", "#D6D6DA", "#414145", text);
        Set("AccentBrush", "#2F6FEB", "#3672D6", selected);
        Set("AccentHoverBrush", "#2560D6", "#326AC6", selected);
        Set("OnAccentBrush", "#FFFFFF", "#FFFFFF", selectedText);
        Set("FocusBrush", "#3B82F6", "#88B3FF", selected);
        Set("TintBrush", "#E8F0FE", "#203451", selected);
        Set("TintTextBrush", "#255BC1", "#A4C6FF", selectedText);
        Set("LinkBrush", "#255BC1", "#A4C6FF", text);
        Set("ControlBrush", "#F3F3F4", "#222224", window);
        Set("HoverBrush", "#EBEBED", "#29292D", selected);
        Set("HoverTextBrush", "#1D1D1F", "#F0EFED", selectedText);
        Set("SwitchOffBrush", "#737378", "#74747C", text);
        Set("SwitchOnBrush", "#2F6FEB", "#3672D6", selected);
        Set("SwitchKnobBrush", "#FFFFFF", "#FFFFFF", window);
        Set("SwitchOnKnobBrush", "#FFFFFF", "#FFFFFF", selectedText);
        Set("GlassInkBrush", "#3C3C43", "#3C3C43", text);
        Set("GlassSurfaceBrush", "#FFFFFF", "#FFFFFF", window);
        Set("GlassSelectionBrush", "#EBEBED", "#EBEBED", selected);
        Set("GlassSelectedTextBrush", "#1D1D1F", "#1D1D1F", selectedText);
        Set("SelectionLineBrush", "#BCD5FF", "#BCD5FF", selected);
        Set("SelectionWashBrush", "#283775CC", "#283775CC", WpfColor.FromArgb(0, 0, 0, 0));

        // WPF 的这两个区域没有系统背景模糊，用中性磨砂底模拟表面高光。
        if (contrast || !_settings.AdvancedEffectsEnabled)
            _app.Resources["NavigationGlass"] = _app.Resources["GlassSurfaceBrush"];
        else
        {
            var material = new LinearGradientBrush(WpfColor.FromRgb(255, 255, 255), WpfColor.FromRgb(243, 243, 244), 90);
            material.Freeze();
            _app.Resources["NavigationGlass"] = material;
        }
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
        translate.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(fromX, 0, TimeSpan.FromMilliseconds(140))
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

        var duration = TimeSpan.FromMilliseconds(180);
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        var translate = new TranslateTransform();
        content.RenderTransform = translate;
        translate.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(4, 0, duration) { EasingFunction = ease, FillBehavior = FillBehavior.Stop });
        content.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0.45, 1, duration) { EasingFunction = ease, FillBehavior = FillBehavior.Stop });
    }
}
