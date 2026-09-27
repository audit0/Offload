using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using Offload.Core;

namespace Offload;

/// <summary>«Освободить место»: что занимает домашнюю папку, с пометками правил, переносом на внешний диск
/// и переходом внутрь папок. Docker и виртуальные машины освобождаются средствами самих программ.</summary>
public partial class SpaceView : UserControl
{
    readonly AppModel app;
    SpaceModel Model => app.Space;
    /// <summary>Строки переиспользуются: при подсчёте список обновляется несколько раз в секунду,
    /// и пересоздание сбрасывало бы наведение мыши.</summary>
    readonly Dictionary<string, SpaceRow> rows = new(Paths.Comparer);
    string? shownLocation = "\0";

    public SpaceView(AppModel app)
    {
        this.app = app;
        InitializeComponent();
        DataContext = app;
        Loaded += (_, _) =>
        {
            Model.PropertyChanged += Model_Changed;
            if (Model.Items.Count == 0 && !Model.IsScanning) Model.Open(Model.Location, app.Rules);
            Update();
        };
        Unloaded += (_, _) => Model.PropertyChanged -= Model_Changed;
    }

    void Model_Changed(object? sender, PropertyChangedEventArgs e) => Update();

    void Update()
    {
        var items = Model.Items;
        var measured = items.Where(i => i.IsMeasured).ToList();
        long total = measured.Sum(i => i.Bytes);
        long movable = measured.Where(i => i.Verdict.IsSafe).Sum(i => i.Bytes);
        long blocked = measured.Where(i => i.Verdict.IsBlocked).Sum(i => i.Bytes);
        long caution = total - movable - blocked;

        TitleText.Text = Model.Title(app.Rules.Home);
        TitleText.ToolTip = Model.Location;
        UpButton.IsEnabled = Model.Location != null;
        SubtitleText.Text = !Model.IsScanning ? $"{Format.Bytes(total)} · {items.Count} {Plural.Ru(items.Count, "объект", "объекта", "объектов")}"
            : items.Count == 0 ? "Считаю…" : $"Считаю: {measured.Count} из {items.Count}";
        ScanSpinner.Visibility = Model.IsScanning ? Visibility.Visible : Visibility.Collapsed;

        Breakdown.Visibility = total > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (total > 0)
        {
            Parts.Parts =
            [
                new StackedBar.Part((double)movable / total, Theme.Ink),
                new StackedBar.Part((double)caution / total, Theme.Faint),
                new StackedBar.Part((double)blocked / total, Theme.Line),
            ];
            MovableText.Text = Format.Bytes(movable);
            CautionText.Text = Format.Bytes(caution);
            BlockedText.Text = Format.Bytes(blocked);
        }

        UpdateRows();

        int hidden = Model.HiddenSmallCount;
        HiddenText.Visibility = hidden > 0 && !Model.IsScanning ? Visibility.Visible : Visibility.Collapsed;
        HiddenText.Text = $"И ещё {hidden} {Plural.Ru(hidden, "объект", "объекта", "объектов")} меньше 1 МБ";
        EmptyScanning.Visibility = items.Count == 0 && Model.IsScanning ? Visibility.Visible : Visibility.Collapsed;

        // В новой папке — с начала списка.
        if (shownLocation != Model.Location)
        {
            shownLocation = Model.Location;
            Scroller.ScrollToTop();
        }
    }

    void UpdateRows()
    {
        var visible = Model.VisibleItems;
        long largest = Model.Largest;
        var home = app.Rules.Home;
        var wanted = new List<UIElement>(visible.Count);
        var alive = new HashSet<string>(Paths.Comparer);
        foreach (var item in visible)
        {
            if (!rows.TryGetValue(item.Id, out var row))
            {
                row = new SpaceRow { OnOpen = OpenItem, OnMove = MoveItem, OnFree = FreeItem };
                rows[item.Id] = row;
            }
            row.Update(item, largest, AppDataKinds.Of(item.Path, home));
            wanted.Add(row);
            alive.Add(item.Id);
        }
        foreach (var gone in rows.Keys.Where(k => !alive.Contains(k)).ToList()) rows.Remove(gone);

        // Порядок меняется по мере подсчёта: перестраиваем детей, только если он и правда другой.
        var children = RowsPanel.Children;
        bool same = children.Count == wanted.Count;
        for (int i = 0; same && i < wanted.Count; i++) same = ReferenceEquals(children[i], wanted[i]);
        if (same) return;
        children.Clear();
        foreach (var row in wanted) children.Add(row);
    }

    void Up_Click(object sender, RoutedEventArgs e) => Model.GoUp(app.Rules);

    void Rescan_Click(object sender, RoutedEventArgs e) => Model.Rescan(app.Rules);

    void OpenItem(SpaceItem item)
    {
        if (item.IsDirectory) Model.Open(item.Path, app.Rules);
    }

    void MoveItem(SpaceItem item)
    {
        var sheet = new SpaceMoveSheet(app, item.Path) { Owner = Window.GetWindow(this) };
        sheet.ShowDialog();
        // Пересчитывать список имеет смысл, только если перенос был: иначе «посмотрел размер и закрыл»
        // стирало бы весь кеш и считало папку заново десятки секунд.
        if (!sheet.DidMove) return;
        Model.InvalidateAll();
        Model.Rescan(app.Rules);
        app.RefreshVolumes();
        app.History.Reload(app.HistoryVolumes);
    }

    /// <summary>Docker освобождается в своём разделе, виртуальные машины — в своих программах: лист объясняет, как.</summary>
    void FreeItem(SpaceItem item)
    {
        switch (AppDataKinds.Of(item.Path, app.Rules.Home))
        {
            case AppDataKind.Docker:
                app.Section = SidebarSection.Docker;
                break;
            case AppDataKind.VirtualMachines:
                new SpaceMachinesSheet(app, item) { Owner = Window.GetWindow(this) }.ShowDialog();
                break;
        }
    }
}
