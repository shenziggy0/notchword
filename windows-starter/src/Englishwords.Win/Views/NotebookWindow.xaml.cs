using System.Windows;
using System.Windows.Input;
using Englishwords.Core.Notebook;

namespace Englishwords.Win.Views;

public sealed record HistoryRowVm(string Word, string Source, string DateText);
public sealed record DailyBarVm(string Label, int Count, double Fraction);

public partial class NotebookWindow : Window
{
    private readonly NotebookStore _store;

    public event Action<string>? WordSelected;

    public NotebookWindow(NotebookStore store)
    {
        _store = store;
        InitializeComponent();
        Pages.SelectionChanged += DesktopAppearance.PageChanged;
        SourceInitialized += (_, _) => (System.Windows.Application.Current as App)?.Appearance?.ApplyTitleBar(this);
        Loaded += async (_, _) => await RefreshAsync();
    }

    public async Task RefreshAsync()
    {
        try
        {
            var favs = await _store.GetFavoritesAsync();
            FavoritesList.ItemsSource = favs;

            var history = await _store.GetHistoryAsync(200);
            HistoryList.ItemsSource = history
                .Select(h => new HistoryRowVm(h.Word, h.Source, h.Date.ToLocalTime().ToString("MM-dd HH:mm")))
                .ToArray();

            var stats = await _store.GetStatsAsync();
            TotalCountText.Text = $"{stats.Total:N0} 次";

            var maxDaily = Math.Max(1, stats.Daily.Max(d => d.Count));
            DailyList.ItemsSource = stats.Daily
                .Select(d => new DailyBarVm(
                    d.Date.ToLocalTime().ToString("MM-dd"),
                    d.Count,
                    (double)d.Count / maxDaily))
                .ToArray();

            FrequentList.ItemsSource = stats.Frequent
                .Select(f => $"{f.Word}  ({f.Count} 次)")
                .ToArray();
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(this, $"读取笔记本失败：{ex.Message}", "Englishwords",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void LookupList_KeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        var word = (sender as System.Windows.Controls.ListBox)?.SelectedItem switch
        {
            string favorite => favorite,
            HistoryRowVm row => row.Word,
            _ => null
        };
        if (string.IsNullOrWhiteSpace(word)) return;
        e.Handled = true;
        WordSelected?.Invoke(word);
    }

    private void WordList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (FavoritesList.SelectedItem is string word && !string.IsNullOrWhiteSpace(word))
        {
            WordSelected?.Invoke(word);
        }
    }

    private void HistoryList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (HistoryList.SelectedItem is HistoryRowVm row)
        {
            WordSelected?.Invoke(row.Word);
        }
    }
}
