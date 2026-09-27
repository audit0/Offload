using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Offload.Core;

namespace Offload;

/// <summary>Несколько записей из одной папки (например, старые версии прошивки) показываются одной раскрываемой строкой.</summary>
public sealed class HistoryGroup(string id, List<MoveRecord> records)
{
    public const int MinimumSize = 3;

    public string Id { get; } = id;
    public List<MoveRecord> Records { get; } = records;
    public bool IsSingle => Records.Count == 1;
    public MoveRecord First => Records[0];
    public long Bytes => Records.Sum(r => r.Bytes);
    public long Files => Records.Sum(r => (long)r.Files);
    public DateTime Latest => Records.Max(r => r.Date);
    public string OriginalParent => HistoryDisplay.Parent(First.OriginalPath);
    /// <summary>Заметка, если она у всех записей одинаковая.</summary>
    public string? Note => Records.Select(r => r.Note ?? "").Distinct().Count() == 1 ? First.Note : null;

    public static List<HistoryGroup> Make(IEnumerable<MoveRecord> records)
    {
        var buckets = new Dictionary<string, List<MoveRecord>>(StringComparer.OrdinalIgnoreCase);
        foreach (var record in records)
        {
            var key = string.Join('\u0001', HistoryDisplay.Parent(record.OriginalPath), HistoryDisplay.Parent(record.ArchivedPath),
                                  record.Restored ? "restored" : "moved");
            if (!buckets.TryGetValue(key, out var list)) buckets[key] = list = [];
            list.Add(record);
        }
        var groups = new List<HistoryGroup>();
        foreach (var (key, items) in buckets)
        {
            if (items.Count >= MinimumSize)
                groups.Add(new HistoryGroup(key, items.OrderBy(r => r.OriginalPath, StringComparer.CurrentCultureIgnoreCase).ToList()));
            else groups.AddRange(items.Select(r => new HistoryGroup(r.Id.ToString(), [r])));
        }
        return groups.OrderByDescending(g => g.Latest).ThenByDescending(g => g.Id, StringComparer.Ordinal).ToList();
    }
}

/// <summary>«Перенесённое»: всё, что унесено на внешние диски, с возвратом на место со сверкой.</summary>
public partial class HistoryView : UserControl
{
    readonly AppModel app;
    HistoryModel Model => app.History;
    /// <summary>Раскрытые группы — между перечитываниями списка.</summary>
    readonly HashSet<string> expanded = [];

    public HistoryView(AppModel app)
    {
        this.app = app;
        InitializeComponent();
        DataContext = app;
        ToolTipService.SetShowOnDisabled(AddButton, true);
        Loaded += (_, _) =>
        {
            Model.PropertyChanged += Changed;
            app.PropertyChanged += Changed;
            Update();
        };
        Unloaded += (_, _) =>
        {
            Model.PropertyChanged -= Changed;
            app.PropertyChanged -= Changed;
        };
    }

    void Changed(object? sender, PropertyChangedEventArgs e)
    {
        // Прогресс приходит часто: список ради него не перестраиваем.
        if (e.PropertyName == nameof(HistoryModel.Progress)) UpdateBusy();
        else Update();
    }

    void Update()
    {
        var records = Model.Records;
        UpdateBusy();

        bool hasDisk = app.Destination != null;
        AddButton.IsEnabled = hasDisk;
        AddButton.ToolTip = hasDisk ? "Зарегистрировать папку или файл, уже перенесённые на внешний диск без Offload"
                                    : "Нужен подключённый внешний диск: выберите его внизу боковой панели";
        EmptyAddButton.IsEnabled = hasDisk;
        EmptyAddButton.ToolTip = hasDisk ? null : "Нужен подключённый внешний диск";

        bool empty = records.Count == 0;
        EmptyPage.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        ListPage.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        var notice = empty ? EmptyNotice : ListNotice;
        (empty ? ListNotice : EmptyNotice).Visibility = Visibility.Collapsed;
        notice.Message = Model.Message;
        notice.Visibility = Model.Message != null ? Visibility.Visible : Visibility.Collapsed;

        if (empty)
        {
            EmptyText.Text = !hasDisk
                ? "Перенесённые на внешний диск папки и файлы появятся здесь. Подключите диск и выберите его внизу боковой панели — тогда можно будет добавить в журнал и то, что вы перенесли раньше без Offload."
                : "Перенесённые на внешний диск папки и файлы появятся здесь. Вернуть их можно, пока диск подключён. То, что вы перенесли раньше без Offload, можно добавить вручную.";
            Rows.Children.Clear();
            return;
        }

        var onDisks = records.Where(r => !r.Restored).ToList();
        int open = onDisks.Count(r => !r.IsEncrypted);
        StoredValue.Text = Format.Bytes(onDisks.Sum(r => r.Bytes));
        CountValue.Text = onDisks.Count.ToString();
        CountTitle.Text = Plural.Ru(onDisks.Count, "перенесённый объект", "перенесённых объекта", "перенесённых объектов");
        CountDetail.Text = $"в сейфе {onDisks.Count - open} · открыто {open}";
        CountTile.Glyph = open > 0 ? Glyphs.Unlock : Glyphs.Lock;
        CountTile.Tone = open > 0 ? Tone.Caution : Tone.Good;
        RestoredValue.Text = (records.Count - onDisks.Count).ToString();

        BuildRows(records);
    }

    void UpdateBusy()
    {
        var record = Model.BusyId is { } busy ? Model.Records.FirstOrDefault(r => r.Id == busy) : null;
        BusyBar.Visibility = record != null ? Visibility.Visible : Visibility.Collapsed;
        if (record == null) return;
        BusyTitle.Text = $"Возвращаю «{record.OriginalName}»";
        BusyPhase.Text = Model.Progress?.Phase.Title() ?? "Подготовка";
        BusyProgress.Value = Model.Progress?.Fraction ?? 0;
    }

    void BuildRows(List<MoveRecord> records)
    {
        var home = app.Rules.Home;
        bool busy = Model.BusyId != null;
        var groups = HistoryGroup.Make(records);
        Rows.Children.Clear();
        foreach (var group in groups)
        {
            if (Rows.Children.Count > 0) Rows.Children.Add(new Separator { Style = (Style)FindResource("RowDivider") });
            if (group.IsSingle)
            {
                // Отступ под шеврон групп: значки всех строк стоят в одну колонку.
                var row = Row(group.First, home, busy);
                row.Margin = new Thickness(38, 0, 14, 0);
                Rows.Children.Add(row);
            }
            else Rows.Children.Add(GroupRow(group, home, busy));
        }
    }

    HistoryRow Row(MoveRecord record, string home, bool busy) =>
        new(record, home, Model.IsArchiveAvailable(record), Model.ArchiveExists(record), busy) { OnRestore = AskRestore };

    FrameworkElement GroupRow(HistoryGroup group, string home, bool busy)
    {
        var panel = new StackPanel();
        bool open = expanded.Contains(group.Id);
        var first = group.First;

        var header = new Grid { Margin = new Thickness(14, 10, 14, 10), Background = Brushes.Transparent, Cursor = Cursors.Hand };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new TextBlock
        {
            Text = open ? Glyphs.ChevronDown : Glyphs.ChevronRight, FontFamily = Glyphs.Font, FontSize = 10, Foreground = Theme.Muted,
            VerticalAlignment = VerticalAlignment.Center,
        });
        var tile = new IconTile
        {
            Glyph = first.Restored ? Glyphs.ArrowReturn : Glyphs.Copy, Tone = first.Restored ? Tone.Neutral : Tone.Brand, Size = 32,
            Margin = new Thickness(12, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(tile, 1);
        header.Children.Add(tile);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
        text.Children.Add(new TextBlock
        {
            Text = $"{HistoryDisplay.LastName(group.OriginalParent)} · {group.Records.Count} {Plural.Ru(group.Records.Count, "объект", "объекта", "объектов")}",
            FontWeight = FontWeights.Medium, FontSize = 13.5,
        });
        text.Children.Add(Caption(HistoryDisplay.Relative(group.OriginalParent, home), wrap: false));
        text.Children.Add(Caption($"{HistoryDisplay.Date(group.Latest)} · {Format.Bytes(group.Bytes)} · файлов {HistoryDisplay.Count(group.Files)} · {HistoryDisplay.Location(first)}", wrap: true));
        if (group.Note is { Length: > 0 } note)
        {
            var noteText = Caption(note, wrap: true);
            noteText.Foreground = Theme.Ink;
            text.Children.Add(noteText);
        }
        Grid.SetColumn(text, 2);
        header.Children.Add(text);
        StatusPill? pill = null;
        if (first.Restored) pill = new StatusPill { Text = "Возвращено", Glyph = Glyphs.Check, Tone = Tone.Good };
        else if (!group.Records.Any(Model.IsArchiveAvailable)) pill = new StatusPill { Text = HistoryDisplay.UnavailableReason(first), Tone = Tone.Neutral };
        if (pill != null)
        {
            pill.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(pill, 3);
            header.Children.Add(pill);
        }
        header.MouseLeftButtonUp += (_, _) =>
        {
            if (!expanded.Remove(group.Id)) expanded.Add(group.Id);
            Update();
        };
        panel.Children.Add(header);

        if (open)
        {
            foreach (var record in group.Records)
            {
                panel.Children.Add(new Separator { Style = (Style)FindResource("RowDivider"), Margin = new Thickness(82, 0, 0, 0) });
                var row = Row(record, home, busy);
                row.Margin = new Thickness(82, 0, 14, 0);
                panel.Children.Add(row);
            }
        }
        return panel;
    }

    TextBlock Caption(string text, bool wrap) => new()
    {
        Text = text, Style = (Style)FindResource("Caption"), Margin = new Thickness(0, 2, 0, 0),
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis,
    };

    /// <summary>Вернуть на место: оставить копию на диске или удалить её — решает человек.</summary>
    void AskRestore(MoveRecord record)
    {
        bool? deleteArchive = null;
        RestoreSheet(record, choice => deleteArchive = choice).ShowDialog();
        if (deleteArchive is { } remove) Model.Restore(record, remove, app);
    }

    SheetWindow RestoreSheet(MoveRecord record, Action<bool> choose)
    {
        var sheet = new SheetWindow
        {
            Heading = "Вернуть на компьютер?", Glyph = Glyphs.ArrowReturn, Width = 680, Owner = Window.GetWindow(this),
            Content = new TextBlock
            {
                Text = $"«{HistoryDisplay.Relative(record.OriginalPath, app.Rules.Home)}» будет скопирован обратно: каждый файл перечитывается с диска и сверяется по SHA-256 со списком, записанным при переносе. На компьютере понадобится {Format.Bytes(record.Bytes)}.",
                Style = (Style)FindResource("Body"), Foreground = Theme.Muted,
            },
        };
        var cancel = new Button { Content = "Отмена", IsCancel = true };
        var delete = new Button { Content = "Вернуть и удалить с диска", Margin = new Thickness(8, 0, 0, 0) };
        var keep = new Button { Content = "Вернуть и оставить копию на диске", Style = (Style)FindResource("ProminentButton"), IsDefault = true, Margin = new Thickness(8, 0, 0, 0) };
        cancel.Click += (_, _) => sheet.Close();
        delete.Click += (_, _) => { choose(true); sheet.Close(); };
        keep.Click += (_, _) => { choose(false); sheet.Close(); };
        sheet.Actions = new StackPanel { Orientation = Orientation.Horizontal, Children = { cancel, delete, keep } };
        return sheet;
    }

    void CancelRestore_Click(object sender, RoutedEventArgs e) => Model.Cancel();

    void Add_Click(object sender, RoutedEventArgs e)
    {
        if (app.Destination == null) return;
        new HistoryImportSheet(app) { Owner = Window.GetWindow(this) }.ShowDialog();
    }
}
