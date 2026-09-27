using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Offload.Core;

namespace Offload;

public partial class SpaceRow : UserControl
{
    static readonly Brush HoverBrush = Freeze(new SolidColorBrush(Color.FromArgb(0x0D, 0, 0, 0)));

    SpaceItem item = null!;
    /// <summary>Данные Docker или виртуальных машин: место из-под них освобождается средствами самих программ.</summary>
    AppDataKind? appData;

    public Action<SpaceItem>? OnOpen { get; set; }
    public Action<SpaceItem>? OnMove { get; set; }
    public Action<SpaceItem>? OnFree { get; set; }

    public SpaceItem Item => item;

    public SpaceRow()
    {
        InitializeComponent();
        MouseEnter += (_, _) => SetHover(true);
        MouseLeave += (_, _) => SetHover(false);
        MouseLeftButtonDown += Row_MouseDown;
        ContextMenuOpening += (_, _) => ContextMenu = BuildMenu();
        // Пустое меню-заглушка: без него WPF не присылает ContextMenuOpening.
        ContextMenu = new ContextMenu();
    }

    static Brush Freeze(Brush brush)
    {
        brush.Freeze();
        return brush;
    }

    public void Update(SpaceItem item, long largest, AppDataKind? appData)
    {
        this.item = item;
        this.appData = appData;
        Tile.Glyph = appData switch
        {
            AppDataKind.Docker => Glyphs.Package,
            AppDataKind.VirtualMachines => Glyphs.Computer,
            _ => item.IsDirectory ? Glyphs.Folder : Glyphs.Document,
        };
        Tile.Tone = item.IsDirectory ? Tone.Brand : Tone.Neutral;
        NameText.Text = item.Name;
        NameText.ToolTip = item.Path;
        if (item.AccessDenied)
        {
            AccessPill.Text = item.Bytes > 0 ? "не всё доступно" : "нет доступа";
            AccessPill.Visibility = Visibility.Visible;
        }
        else AccessPill.Visibility = Visibility.Collapsed;
        Bar.Fraction = largest > 0 ? (double)item.Bytes / largest : 0;
        var note = !item.Verdict.IsSafe ? item.Verdict.Notes.FirstOrDefault() : null;
        NoteText.Text = note ?? "";
        NoteText.Visibility = string.IsNullOrEmpty(note) ? Visibility.Collapsed : Visibility.Visible;

        SizeText.Text = item.IsMeasured ? Format.Bytes(item.Bytes) : "";
        SizeText.Visibility = item.IsMeasured ? Visibility.Visible : Visibility.Collapsed;
        SizeSpinner.Visibility = item.IsMeasured ? Visibility.Collapsed : Visibility.Visible;
        DateText.Text = item.Modified is { } modified ? Format.Relative(modified) : "";
        DateText.Visibility = item.Modified == null ? Visibility.Collapsed : Visibility.Visible;

        VerdictPill.Verdict = item.Verdict;

        if (appData != null)
        {
            ActionButton.Content = "Как освободить…";
            ActionButton.ToolTip = appData == AppDataKind.Docker
                ? "Открыть раздел «Docker»: очистка образов и кеша сборки, архивация томов"
                : "Сколько занимает каждая машина и как освободить место её же средствами";
            ActionButton.Visibility = Visibility.Visible;
        }
        else if (!item.Verdict.IsBlocked)
        {
            ActionButton.Content = "Перенести…";
            ActionButton.ToolTip = null;
            ActionButton.Visibility = Visibility.Visible;
        }
        else ActionButton.Visibility = Visibility.Hidden;

        OpenButton.Opacity = item.IsDirectory ? 1 : 0;
        OpenButton.IsEnabled = item.IsDirectory;
    }

    void SetHover(bool hovering)
    {
        Back.Background = hovering ? HoverBrush : Brushes.Transparent;
        RevealButton.Opacity = hovering ? 1 : 0;
    }

    void Row_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2 && item.IsDirectory)
        {
            e.Handled = true;
            OnOpen?.Invoke(item);
        }
    }

    ContextMenu BuildMenu()
    {
        var menu = new ContextMenu();
        MenuItem Add(string title, Action action)
        {
            var entry = new MenuItem { Header = title };
            entry.Click += (_, _) => action();
            menu.Items.Add(entry);
            return entry;
        }
        if (item.IsDirectory) Add("Открыть", () => OnOpen?.Invoke(item));
        Add("Показать в Проводнике", () => Ui.Reveal(item.Path));
        if (appData != null)
        {
            menu.Items.Add(new Separator());
            Add("Как освободить…", () => OnFree?.Invoke(item));
        }
        else if (!item.Verdict.IsBlocked)
        {
            menu.Items.Add(new Separator());
            Add("Перенести…", () => OnMove?.Invoke(item));
        }
        return menu;
    }

    void Reveal_Click(object sender, RoutedEventArgs e) => Ui.Reveal(item.Path);

    void Action_Click(object sender, RoutedEventArgs e)
    {
        if (appData != null) OnFree?.Invoke(item);
        else OnMove?.Invoke(item);
    }

    void Open_Click(object sender, RoutedEventArgs e)
    {
        if (item.IsDirectory) OnOpen?.Invoke(item);
    }
}
