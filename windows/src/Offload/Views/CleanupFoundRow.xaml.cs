using System.Windows;
using System.Windows.Controls;
using Offload.Core;

namespace Offload;

public partial class CleanupFoundRow : UserControl
{
    readonly CleanupSuggestion item;
    readonly Action? ignore;

    /// <param name="keeper">Для лишней копии — копия, которая остаётся.</param>
    /// <param name="ignore">null — просить не предлагать уже поздно (на вопрос ответили).</param>
    public CleanupFoundRow(CleanupSuggestion item, string home, CleanupSuggestion? keeper, Action? ignore)
    {
        this.item = item;
        this.ignore = ignore;
        InitializeComponent();
        Tile.Glyph = item.IsDirectory ? Glyphs.Folder : Glyphs.Document;
        NameText.Text = item.Name;
        NameText.ToolTip = item.Name;
        if (item.Learned)
        {
            Badge.Text = "как в прошлый раз";
            Badge.Glyph = Glyphs.History;
            Badge.Visibility = Visibility.Visible;
        }
        else if (item.Habit)
        {
            Badge.Text = "как вы обычно";
            Badge.Glyph = Glyphs.Sparkle;
            Badge.Visibility = Visibility.Visible;
        }
        PathText.Text = Ui.RelativeToHome(item.Path, home);
        PathText.ToolTip = item.Path;
        if (keeper != null)
        {
            ReasonText.Text = "Такая же остаётся: " + Ui.RelativeToHome(keeper.Path, home);
            ReasonText.TextWrapping = TextWrapping.NoWrap;
            ReasonText.TextTrimming = TextTrimming.CharacterEllipsis;
            ReasonText.ToolTip = keeper.Path;
        }
        else
        {
            ReasonText.Text = item.Reason;
            ReasonText.Visibility = item.Reason.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        Cautions.ItemsSource = item.Cautions;
        SizeText.Text = Format.Bytes(item.Bytes);
        DateText.Text = item.Modified is { } modified ? Format.Relative(modified) : "";
        DateText.Visibility = item.Modified != null ? Visibility.Visible : Visibility.Collapsed;
        IgnoreItem.Visibility = ignore != null ? Visibility.Visible : Visibility.Collapsed;
    }

    void Reveal_Click(object sender, RoutedEventArgs e) => Ui.Reveal(item.Path);

    void Ignore_Click(object sender, RoutedEventArgs e) => ignore?.Invoke();
}
