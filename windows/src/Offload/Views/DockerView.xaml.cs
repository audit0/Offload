using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Offload.Core;

namespace Offload;

/// <summary>Docker: сколько места занято внутри, очистка того, что Docker пересоздаст сам, и упаковка
/// ненужных томов на внешний диск (в сейф или открыто) со сверкой.</summary>
public partial class DockerView : UserControl
{
    readonly AppModel app;
    string? lastTargetId;
    bool started;

    /// <summary>Оттенки частей шкалы: чёрно-белая гамма, как всё окно.</summary>
    static readonly Brush ImagesBrush = Frozen(0x11, 0x11, 0x11);
    static readonly Brush CacheBrush = Frozen(0x55, 0x55, 0x5A);
    static readonly Brush ContainersBrush = Frozen(0x8E, 0x8E, 0x93);
    static readonly Brush VolumesBrush = Frozen(0xC0, 0xC0, 0xC6);

    static Brush Frozen(byte r, byte g, byte b)
    {
        var brush = new SolidColorBrush(Color.FromRgb(r, g, b));
        brush.Freeze();
        return brush;
    }

    public sealed record FigureRow(string Title, Brush Brush, string Value, string? Note, Brush NoteBrush);

    public sealed record VolumeRow(string Name, bool Selected, string Size, Brush SizeBrush, bool Sizing, string Created, string? Activity,
                                   bool Checking, bool CanCheck, string? UsedBy, bool NotLast);

    public sealed record ArchiveRow(string Path, string Display, string Place, string Glyph, Tone Tone, bool Enabled, bool NotLast);

    public DockerView(AppModel app)
    {
        this.app = app;
        InitializeComponent();
        DataContext = app;
        ReadyHost.Content = null;
        var scroll = Pages.Scroll(ReadyState);
        if (scroll.Content is Border page) page.Padding = new Thickness(Theme.PagePadding, 4, Theme.PagePadding, Theme.PagePadding);
        ReadyHost.Content = scroll;
        Loaded += (_, _) =>
        {
            app.PropertyChanged += AppChanged;
            Model.PropertyChanged += Changed;
            if (!started)
            {
                started = true;
                lastTargetId = app.Target?.Id;
                if (Model.Status == DockerStatus.Unknown) Model.Reload(app);
            }
            Update();
        };
        Unloaded += (_, _) =>
        {
            app.PropertyChanged -= AppChanged;
            Model.PropertyChanged -= Changed;
        };
    }

    DockerModel Model => app.Docker;

    void Changed(object? sender, PropertyChangedEventArgs e) => Update();

    /// <summary>Сменилось, куда класть (другой диск, сейф открыли или закрыли), — архивы ищутся заново.</summary>
    void AppChanged(object? sender, PropertyChangedEventArgs e)
    {
        var id = app.Target?.Id;
        if (id != lastTargetId)
        {
            lastTargetId = id;
            Model.Reload(app);
        }
        Update();
    }

    static Visibility Show(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

    void Update()
    {
        var model = Model;
        bool busy = model.Busy != null;

        // Шапка
        Subtitle.Text = model.Sizing ? "Docker считает размеры томов — это может занять минуту"
            : model.RawBytes is { } raw ? $"Диск Docker на компьютере (docker_data.vhdx) занимает {Format.Bytes(raw)}" : "";
        Subtitle.Visibility = Show(Subtitle.Text.Length > 0);
        BusyPanel.Visibility = Show(busy);
        BusyText.Text = model.Busy ?? "";
        BusyText.ToolTip = model.Busy;
        CancelButton.Visibility = Show(!model.Pruning);
        ReloadButton.IsEnabled = !busy;
        bool ready = model.Status == DockerStatus.Ready;
        ArchiveButton.Visibility = Show(ready);
        ArchiveButton.IsEnabled = model.Selection.Count > 0 && !busy && app.Target != null;
        ArchiveButton.ToolTip = app.TargetProblem ?? "Упаковать выбранные тома и убрать их из Docker";

        // Состояние Docker
        CheckingState.Visibility = Show(model.Status is DockerStatus.Unknown or DockerStatus.Checking);
        UnavailableState.Visibility = Show(model.Status is DockerStatus.NotInstalled or DockerStatus.NotRunning);
        ReadyHost.Visibility = Show(ready);
        if (model.Status == DockerStatus.NotInstalled)
        {
            UnavailableTitle.Text = "Docker не установлен";
            UnavailableText.Text = "Этот раздел нужен, только если вы пользуетесь Docker.";
            UnavailableReload.Visibility = Visibility.Collapsed;
        }
        else
        {
            UnavailableTitle.Text = "Docker не запущен";
            UnavailableText.Text = "Откройте Docker Desktop и обновите список.";
            UnavailableReload.Visibility = Visibility.Visible;
        }
        if (!ready) return;

        UpdateUsage();
        UpdateVolumes();

        MessageList.ItemsSource = model.Messages.Select(Notice).ToList();
        MessageList.Visibility = Show(model.Messages.Count > 0);

        var archives = model.Archives;
        ArchivesSection.Visibility = Show(archives.Count > 0);
        ArchiveList.ItemsSource = archives.Select((path, index) =>
        {
            var (inSafe, display) = Location(path);
            return new ArchiveRow(path, display, inSafe ? "в сейфе" : "открыто на диске", inSafe ? Glyphs.Lock : Glyphs.Package,
                                  inSafe ? Tone.Good : Tone.Neutral, !busy, index < archives.Count - 1);
        }).ToList();
    }

    /// <summary>Что занимает место внутри Docker — и сколько из этого Docker пересоздаст сам.</summary>
    void UpdateUsage()
    {
        var model = Model;
        var usage = model.Usage;
        Figures.Visibility = Show(usage != null);
        MeasuringRow.Visibility = Show(usage == null && model.MeasuringUsage);
        NoUsageText.Visibility = Show(usage == null && !model.MeasuringUsage);
        RemeasureSpinner.Visibility = Show(usage != null && model.MeasuringUsage);
        PruneButton.IsEnabled = usage != null && model.Busy == null;
        BarBlock.Visibility = Show(usage != null);
        if (usage == null) return;

        FigureRow Figure(string title, Brush brush, DockerUsage.PartInfo? part, string note, bool neutral = false) =>
            new(title, brush, part is { } p ? Format.Bytes(p.Bytes) : "—",
                part is { Reclaimable: > 0 } r ? $"{note} {Format.Bytes(r.Reclaimable)}" : null, neutral ? Theme.Faint : Theme.Ink);
        Figures.ItemsSource = new List<FigureRow>
        {
            Figure("Образы", ImagesBrush, usage.Images, "можно убрать"),
            Figure("Кеш сборки", CacheBrush, usage.BuildCache, "можно убрать"),
            Figure("Контейнеры", ContainersBrush, usage.Containers, "можно убрать"),
            // Тома очистка не трогает: неподключённые можно только упаковать на диск.
            Figure("Тома", VolumesBrush, usage.Volumes, "не подключены", neutral: true),
        };

        var parts = new (DockerUsage.PartInfo? Part, Brush Brush)[]
        {
            (usage.Images, ImagesBrush), (usage.BuildCache, CacheBrush), (usage.Containers, ContainersBrush), (usage.Volumes, VolumesBrush),
        };
        long inside = parts.Sum(p => p.Part?.Bytes ?? 0);
        long raw = model.RawBytes ?? 0;
        // Шкала — весь диск Docker на компьютере, если он известен: незанятое внутри него видно пустым хвостом.
        double whole = Math.Max(inside, raw);
        UsageBar.Parts = whole <= 0 ? [] : parts.Select(p => new StackedBar.Part((p.Part?.Bytes ?? 0) / whole, p.Brush)).ToList();
        BarCaption.Text = raw >= inside && raw > 0
            ? $"Занято внутри {Format.Bytes(inside)} из {Format.Bytes(raw)} — столько диск Docker занимает на компьютере"
            : $"Занято внутри Docker: {Format.Bytes(inside)}";
    }

    void UpdateVolumes()
    {
        var model = Model;
        var volumes = model.Volumes;
        NoVolumesText.Visibility = Show(volumes.Count == 0);
        VolumeList.ItemsSource = volumes.Select((volume, index) =>
        {
            bool known = model.Activity.TryGetValue(volume.Name, out var date);
            bool checking = !known && model.Checking.Contains(volume.Name);
            return new VolumeRow(
                volume.Name,
                model.Selection.Contains(volume.Name),
                volume.SizeBytes is { } bytes ? Format.Bytes(bytes) : "—",
                volume.SizeBytes != null ? Theme.Ink : Theme.Faint,
                volume.SizeBytes == null && model.Sizing,
                volume.CreatedAt is { } created ? Format.Relative(created) : "—",
                known ? Format.Relative(date) : null,
                checking,
                !known && !checking,
                volume.UsedBy.Count > 0 ? string.Join(", ", volume.UsedBy) : null,
                index < volumes.Count - 1);
        }).ToList();
    }

    /// <summary>Итоги упаковки приходят строками с отметкой в начале: «✓» — удалось, «✗» — нет.
    /// Отметка становится видом сообщения, а из текста уходит.</summary>
    static NoticeMessage Notice(string message)
    {
        if (message.StartsWith("✓ ")) return new NoticeMessage(NoticeKind.Success, message[2..]);
        if (message.StartsWith("✗ ")) return new NoticeMessage(NoticeKind.Error, message[2..]);
        return new NoticeMessage(NoticeKind.Info, message);
    }

    /// <summary>Архив лежит в сейфе или открыто на диске — и путь к нему, понятный человеку.</summary>
    (bool InSafe, string Display) Location(string path)
    {
        if (app.SafeVolume is { } safe && Paths.IsInside(path, safe.MountPoint)) return (true, Paths.Name(path));
        if (app.Destination is { } disk && Paths.Relative(path, disk.MountPoint) is { } relative) return (false, relative);
        return (false, Paths.Name(path));
    }

    // MARK: Действия

    void Reload_Click(object sender, RoutedEventArgs e) => Model.Reload(app);

    void Cancel_Click(object sender, RoutedEventArgs e) => Model.Cancel();

    void Volume_Click(object sender, RoutedEventArgs e)
    {
        if (sender is CheckBox { Tag: string name } box) Model.Toggle(name, box.IsChecked == true);
    }

    void Check_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string name }) Model.CheckActivity([name]);
    }

    void Prune_Click(object sender, RoutedEventArgs e) => new DockerPruneSheet(app).ShowDialog();

    void Archive_Click(object sender, RoutedEventArgs e)
    {
        if (app.Target is not { } target || Model.Selection.Count == 0) return;
        var sheet = new SheetWindow { Heading = "Архивировать выбранные тома?", Glyph = Glyphs.Package, Owner = Window.GetWindow(this) };
        var body = new StackPanel();
        body.Children.Add(new TextBlock
        {
            Style = (Style)FindResource("Body"), Foreground = Theme.Muted,
            Text = $"Выбрано {Model.Selection.Count}, около {Format.Bytes(Model.SelectedBytes)}. Каждый том упаковывается в архив, список всех его файлов " +
                   "сверяется с архивом, и только потом том удаляется из Docker. Тома, подключённые к контейнерам, не трогаются.",
        });
        body.Children.Add(new TargetSummary { Margin = new Thickness(0, 14, 0, 0) });
        sheet.Content = body;
        bool confirmed = false;
        var yes = new Button
        {
            Content = target.IsEncryptedImage ? "Упаковать в сейф и убрать из Docker" : $"Упаковать на «{target.Name}» открыто и убрать из Docker",
            Style = (Style)FindResource("ProminentButton"), IsDefault = true,
        };
        var no = new Button { Content = "Отмена", IsCancel = true, Margin = new Thickness(0, 0, 8, 0) };
        yes.Click += (_, _) => { confirmed = true; sheet.Close(); };
        no.Click += (_, _) => sheet.Close();
        sheet.Actions = new StackPanel { Orientation = Orientation.Horizontal, Children = { no, yes } };
        sheet.ShowDialog();
        // Пока лист был открыт, сейф могли закрыть: класть только туда, куда сейчас можно.
        if (confirmed && app.Target is { } current) Model.ArchiveSelected(current, app);
    }

    void RestoreArchive_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: ArchiveRow row }) return;
        var sheet = new SheetWindow
        {
            Heading = "Вернуть том в Docker",
            Subtitle = "Будет создан новый том и заполнен из архива со сверкой. Существующий том с таким именем не перезаписывается.",
            Glyph = Glyphs.ArrowReturn, Owner = Window.GetWindow(this),
        };
        var name = new TextBox { Text = DockerService.VolumeNameFromArchive(row.Path) ?? "", Tag = "Имя тома" };
        var body = new StackPanel();
        body.Children.Add(new TextBlock { Text = "Имя тома", Style = (Style)FindResource("Caption"), Margin = new Thickness(0, 0, 0, 6) });
        body.Children.Add(name);
        sheet.Content = body;
        bool confirmed = false;
        var yes = new Button { Content = "Вернуть", Style = (Style)FindResource("ProminentButton"), IsDefault = true, IsEnabled = name.Text.Trim().Length > 0 };
        var no = new Button { Content = "Отмена", IsCancel = true, Margin = new Thickness(0, 0, 8, 0) };
        name.TextChanged += (_, _) => yes.IsEnabled = name.Text.Trim().Length > 0;
        yes.Click += (_, _) => { confirmed = true; sheet.Close(); };
        no.Click += (_, _) => sheet.Close();
        sheet.Actions = new StackPanel { Orientation = Orientation.Horizontal, Children = { no, yes } };
        sheet.Loaded += (_, _) => { name.Focus(); name.SelectAll(); };
        sheet.ShowDialog();
        if (confirmed) Model.Restore(row.Path, name.Text.Trim(), app);
    }
}
