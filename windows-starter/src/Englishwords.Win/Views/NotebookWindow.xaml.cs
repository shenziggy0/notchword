using System.Windows;
using System.Windows.Input;
using Englishwords.Core.Notebook;
using Englishwords.Core.Dictionary;
using System.Windows.Documents;
using StackPanel = System.Windows.Controls.StackPanel;
using TextBlock = System.Windows.Controls.TextBlock;
using Button = System.Windows.Controls.Button;

namespace Englishwords.Win.Views;

public sealed record HistoryRowVm(string Word, string Source, string DateText);
public sealed record FavoriteRowVm(string Word);
public sealed record DailyBarVm(string Label, int Count, double Fraction);

public partial class NotebookWindow : Window
{
    private readonly NotebookStore _store;
    private readonly DictionaryStore? _dictionary;

    public event Action<string>? WordSelected;

    public NotebookWindow(NotebookStore store, DictionaryStore? dictionary)
    {
        _store = store;
        _dictionary = dictionary;
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
            FavoritesList.ItemsSource = favs.Select(word => new FavoriteRowVm(word)).ToArray();

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
            FavoriteRowVm favorite => favorite.Word,
            HistoryRowVm row => row.Word,
            _ => null
        };
        if (string.IsNullOrWhiteSpace(word)) return;
        e.Handled = true;
        WordSelected?.Invoke(word);
    }

    private void WordList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (FavoritesList.SelectedItem is FavoriteRowVm favorite)
        {
            WordSelected?.Invoke(favorite.Word);
        }
    }

    private async void FavoriteDetails_Loaded(object sender, RoutedEventArgs e)
    {
        if (sender is not StackPanel panel || panel.DataContext is not FavoriteRowVm favorite ||
            panel.Children[1] is not StackPanel details) return;
        try
        {
            var examples = await _store.GetExamplesAsync(favorite.Word);
            if (!ReferenceEquals(panel.DataContext, favorite)) return;
            details.Children.Clear();
            if (examples.Count == 0)
            {
                if (_dictionary is null) return;
                var result = await _dictionary.LookupAsync(favorite.Word);
                if (ReferenceEquals(panel.DataContext, favorite) && result.Entry is { } entry)
                    details.Children.Add(new TextBlock
                    {
                        Text = entry.Translation.Split('\n')[0], FontSize = 13, TextWrapping = TextWrapping.Wrap
                    });
                return;
            }
            details.Children.Add(ExampleText(examples[0]));
            if (examples.Count > 1)
            {
                var extra = new StackPanel();
                foreach (var example in examples.Skip(1)) extra.Children.Add(ExampleText(example));
                details.Children.Add(new System.Windows.Controls.Expander { Header = "更多原句", Content = extra });
            }
        }
        catch (Exception ex) { details.Children.Add(new TextBlock { Text = ex.Message, FontSize = 13 }); }
    }

    private static TextBlock ExampleText(FavoriteExample example)
    {
        var text = new TextBlock { FontSize = 13, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) };
        text.Inlines.Add(new Run(example.Meaning));
        text.Inlines.Add(new LineBreak());
        var context = example.Context;
        if (context.Selected is { } selected)
        {
            text.Inlines.Add(new Run(context.Sentence[..context.Start]));
            text.Inlines.Add(new Bold(new Run(selected)));
            text.Inlines.Add(new Run(context.Sentence[(context.Start + context.Length)..]));
        }
        else text.Inlines.Add(new Run(context.Sentence));
        return text;
    }

    private async void Review_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button start) return;
        start.IsEnabled = false;
        try
        {
            var content = new StackPanel { Margin = new Thickness(20) };
            var words = await _store.GetReviewWordsAsync();
            if (words.Count == 0)
                content.Children.Add(new TextBlock
                {
                    Text = "最近七天在不同日期主动查过的词会出现在这里。", TextWrapping = TextWrapping.Wrap
                });
            foreach (var word in words)
            {
                var examples = await _store.GetExamplesAsync(word);
                var example = examples.FirstOrDefault();
                var meaning = example?.Meaning ?? _dictionary?.Lookup(word).Entry?.Translation;
                content.Children.Add(new TextBlock
                {
                    Text = example?.Prompt ?? meaning ?? word, TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(0, 8, 0, 0)
                });
                var answer = new Button { Content = "显示答案", HorizontalAlignment = System.Windows.HorizontalAlignment.Left };
                answer.Click += (_, _) =>
                {
                    answer.Content = example is null ? word : $"{word} · {meaning}";
                    answer.IsEnabled = false;
                };
                content.Children.Add(answer);
            }
            new Window
            {
                Style = (Style)FindResource("PageWindow"), Owner = this, Title = "复习", Width = 475, SizeToContent = SizeToContent.Height,
                WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
                Content = content
            }.ShowDialog();
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(this, ex.Message, "读取复习词失败");
        }
        finally { start.IsEnabled = true; }
    }

    private void HistoryList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (HistoryList.SelectedItem is HistoryRowVm row)
        {
            WordSelected?.Invoke(row.Word);
        }
    }
}
