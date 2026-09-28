using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Offload.Core;

namespace Offload;

public partial class OverviewView : UserControl
{
    readonly AppModel app;
    bool subscribed;

    /// <summary>Шаг порядка работы. Каждый шаг — правда о текущем состоянии, а не заученная инструкция.</summary>
    enum StepState { Done, Todo, Warning }

    sealed record Step(int Id, StepState State, string Title, string Detail, (string Title, SidebarSection Section)? Action = null);

    public OverviewView(AppModel app)
    {
        this.app = app;
        InitializeComponent();
        DataContext = app;
        Loaded += (_, _) =>
        {
            Subscribe(true);
            app.Overview.Start();
            Update();
        };
        Unloaded += (_, _) => Subscribe(false);
    }

    void Subscribe(bool on)
    {
        if (on == subscribed) return;
        subscribed = on;
        if (on)
        {
            app.PropertyChanged += Changed;
            app.Overview.PropertyChanged += Changed;
            app.Safe.PropertyChanged += Changed;
            app.Backup.PropertyChanged += Changed;
            app.History.PropertyChanged += Changed;
            app.Updates.PropertyChanged += Changed;
        }
        else
        {
            app.PropertyChanged -= Changed;
            app.Overview.PropertyChanged -= Changed;
            app.Safe.PropertyChanged -= Changed;
            app.Backup.PropertyChanged -= Changed;
            app.History.PropertyChanged -= Changed;
            app.Updates.PropertyChanged -= Changed;
        }
    }

    void Changed(object? sender, PropertyChangedEventArgs e) => Update();

    void Update()
    {
        var model = app.Overview;
        UpdateConnected();
        UpdatesCard.Visibility = app.Updates.Enabled == null ? Visibility.Visible : Visibility.Collapsed;
        UpdateDisk(model.Disk);
        UpdateHost();
        UpdateMemory(model.Memory);
        UpdateSteps(model.Disk);
        UpdateAdvice(model.Advice);
        UpdateApps(model.Memory);
    }

    static Style Res(string key) => (Style)Application.Current.FindResource(key);

    // MARK: Подключили диск

    void UpdateConnected()
    {
        ConnectedCard.Visibility = app.ConnectedPrompt != null ? Visibility.Visible : Visibility.Collapsed;
        ConnectedTitle.Text = $"Подключён «{app.ConnectedPrompt}»";
    }

    void Cleanup_Click(object sender, RoutedEventArgs e)
    {
        app.ConnectedPrompt = null;
        app.Section = SidebarSection.Cleanup;
        app.Cleanup.Start(app);
    }

    void NotNow_Click(object sender, RoutedEventArgs e) => app.ConnectedPrompt = null;

    // MARK: Сообщать ли о новых версиях

    void UpdatesOn_Click(object sender, RoutedEventArgs e) => app.Updates.SetEnabled(true);

    void UpdatesOff_Click(object sender, RoutedEventArgs e) => app.Updates.SetEnabled(false);

    // MARK: Карточки

    void UpdateDisk(VolumeInfo? volume)
    {
        bool known = volume is { TotalBytes: > 0 };
        DiskSpinner.Visibility = known ? Visibility.Collapsed : Visibility.Visible;
        DiskBody.Visibility = DiskState.Visibility = known ? Visibility.Visible : Visibility.Collapsed;
        if (!known) return;
        double used = (double)(volume!.TotalBytes - volume.AvailableBytes) / volume.TotalBytes;
        // Те же пороги, что у шага «Освободите место» и у совета: меньше 15% свободно — мало.
        bool low = used > 0.85;
        // Красный — только когда места почти не осталось: это уже беда, а не состояние.
        Brush tint = used > 0.9 ? Theme.Bad : Theme.Ink;
        DiskRing.Fraction = used;
        DiskRing.Tint = tint;
        DiskPercent.Text = $"{(int)Math.Round(used * 100)}%";
        DiskFree.Text = Format.Bytes(volume.AvailableBytes);
        DiskTotal.Text = $"свободно из {Format.Bytes(volume.TotalBytes)}";
        DiskStateGlyph.Text = low ? Glyphs.Warning : Glyphs.CheckSeal;
        DiskStateText.Text = low ? "Мало места" : "Места достаточно";
        DiskStateGlyph.Foreground = DiskStateText.Foreground = low ? tint : Theme.Ink;
    }

    void UpdateHost()
    {
        var disk = app.Destination;
        HostBody.Visibility = HostSafe.Visibility = disk != null ? Visibility.Visible : Visibility.Collapsed;
        HostMissing.Visibility = disk == null ? Visibility.Visible : Visibility.Collapsed;
        if (disk == null) return;
        HostName.Text = disk.Name;
        HostBar.Visibility = disk.TotalBytes > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (disk.TotalBytes > 0) HostBar.Fraction = (double)(disk.TotalBytes - disk.AvailableBytes) / disk.TotalBytes;
        HostDetail.Text = $"{disk.FsDisplayName} · свободно {Format.Bytes(disk.AvailableBytes)} из {Format.Bytes(disk.TotalBytes)}";
        var safe = app.Safe;
        HostSafeGlyph.Text = safe.SummaryGlyph;
        HostSafeText.Text = safe.Summary;
        HostSafeGlyph.Foreground = HostSafeText.Foreground = Theme.ToneBrush(safe.SummaryTone);
    }

    void UpdateMemory(MemorySnapshot? snapshot)
    {
        MemorySpinner.Visibility = snapshot == null ? Visibility.Visible : Visibility.Collapsed;
        MemoryBody.Visibility = MemoryTotal.Visibility = snapshot != null ? Visibility.Visible : Visibility.Collapsed;
        if (snapshot == null) return;
        MemoryTotal.Text = Format.Memory(snapshot.PhysicalBytes);
        PressureDot.Fill = snapshot.Pressure switch
        {
            MemoryPressure.Critical => Theme.Bad,
            MemoryPressure.Unknown => Theme.Faint,
            _ => Theme.Ink,
        };
        PressureTitle.Text = snapshot.Pressure.Title();
        SwapValue.Text = $"{Format.Memory(snapshot.SwapUsedBytes)} из {Format.Memory(snapshot.SwapTotalBytes)}";
        CompressedValue.Text = Format.Memory(snapshot.CompressedBytes);
        FreeValue.Text = Format.Memory(snapshot.FreeBytes);
        UptimeValue.Text = Uptime(snapshot.Uptime);
    }

    static string Uptime(TimeSpan interval)
    {
        int days = (int)interval.TotalDays;
        int hours = interval.Hours;
        return days > 0 ? $"{days} дн. {hours} ч." : $"{hours} ч.";
    }

    // MARK: Порядок работы

    List<Step> Steps(VolumeInfo? systemDisk)
    {
        var steps = new List<Step>();
        var host = app.Destination;
        var safe = app.Safe;
        var state = safe.Current;
        steps.Add(host != null
            ? new Step(1, StepState.Done, $"Внешний диск «{host.Name}»",
                       $"{host.FsDisplayName} · свободно {Format.Bytes(host.AvailableBytes)}" + (state?.HostEncrypted == true ? " · зашифрован целиком" : ""))
            : new Step(1, StepState.Todo, "Подключите внешний диск",
                       "На него OffLoadAI переносит то, что не нужно держать на компьютере, и там же живёт сейф."));

        if (host != null)
        {
            if (state is { Exists: true, IsEncrypted: true, SizeLimit: { } limit } && limit < 20L << 30)
                steps.Add(new Step(2, StepState.Warning, "Сейф мал для переноса",
                    $"«{state.DisplayName}» ограничен {Format.Bytes(limit)}: для ключей хватит, для больших папок — нет. Предел можно увеличить без потери содержимого.",
                    ("Сейф", SidebarSection.Safe)));
            else if (state is { Exists: true, IsEncrypted: true })
                steps.Add(new Step(2, StepState.Done, safe.IsOpen ? "Сейф открыт" : "Сейф закрыт",
                    safe.IsOpen
                        ? "Перенос, бэкап и ключи идут в него. Закройте, когда закончите."
                        : "На диске только шифротекст. Откройте, чтобы класть в сейф или брать из него.",
                    ("Сейф", SidebarSection.Safe)));
            else
                steps.Add(new Step(2, StepState.Todo, "Заведите сейф",
                    "Зашифрованный образ на внешнем диске: без пароля его содержимое не прочтёт никто.",
                    ("Создать", SidebarSection.Safe)));
        }

        if (systemDisk is { TotalBytes: > 0 })
        {
            double free = (double)systemDisk.AvailableBytes / systemDisk.TotalBytes;
            bool low = free < 0.15;
            steps.Add(new Step(3, low ? StepState.Warning : StepState.Done,
                low ? "Освободите место на компьютере" : "Места на компьютере достаточно",
                $"Свободно {Format.Bytes(systemDisk.AvailableBytes)} из {Format.Bytes(systemDisk.TotalBytes)}."
                    + (low ? " Перенесите большое и редко нужное в сейф — вернуть можно в любой момент." : ""),
                ("Освободить место", SidebarSection.Space)));
        }

        if (host != null)
        {
            var plain = app.PlainRecords;
            if (plain.Count > 0)
            {
                long bytes = plain.Sum(r => r.Bytes);
                steps.Add(new Step(4, StepState.Warning, "Зашифруйте то, что уже лежит на диске открыто",
                    $"{plain.Count} {Plural.Ru(plain.Count, "объект", "объекта", "объектов")}, {Format.Bytes(bytes)} — прочтёт любой, у кого окажется диск.",
                    ("Зашифровать", SidebarSection.Safe)));
            }
        }

        int sources = app.Backup.Sources.Count;
        steps.Add(new Step(5, sources == 0 ? StepState.Todo : StepState.Done,
            sources == 0 ? "Настройте бэкап проектов и ключей" : $"Бэкап: папок {sources}",
            "Обновляемая копия проектов и ключи с токенами — в сейф.",
            ("Бэкап", SidebarSection.Backup)));
        return steps;
    }

    void UpdateSteps(VolumeInfo? systemDisk)
    {
        var list = Steps(systemDisk);
        int done = list.Count(s => s.State == StepState.Done);
        // Первый несделанный шаг — «следующий»: его кнопка главная, остальные спокойнее.
        int? next = list.FirstOrDefault(s => s.State != StepState.Done)?.Id;
        StepsDone.Text = $"готово {done} из {list.Count}";
        StepsBar.Fraction = (double)done / Math.Max(1, list.Count);
        StepsList.Children.Clear();
        for (int index = 0; index < list.Count; index++)
        {
            if (index > 0) StepsList.Children.Add(new Separator { Style = Res("RowDivider"), Margin = new Thickness(54, 0, 0, 0) });
            StepsList.Children.Add(StepRow(index + 1, list[index], list[index].Id == next, index == list.Count - 1));
        }
    }

    FrameworkElement StepRow(int number, Step step, bool isNext, bool last)
    {
        var grid = new Grid
        {
            Margin = new Thickness(18, 12, 18, 12),
        };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(26) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        FrameworkElement indicator = step.State switch
        {
            StepState.Done => new TextBlock { Text = Glyphs.CheckSeal, FontFamily = Glyphs.Font, FontSize = 21, Foreground = Theme.Ink },
            StepState.Warning => new TextBlock { Text = Glyphs.Warning, FontFamily = Glyphs.Font, FontSize = 17, Foreground = Theme.Ink },
            _ => new Border
            {
                Width = 22, Height = 22, CornerRadius = new CornerRadius(11), BorderThickness = new Thickness(1.5),
                BorderBrush = isNext ? Theme.Ink : new SolidColorBrush(Color.FromArgb(0x80, 0x6E, 0x6E, 0x73)),
                Child = new TextBlock
                {
                    Text = number.ToString(), FontSize = 12, FontWeight = FontWeights.SemiBold,
                    Foreground = isNext ? Theme.Ink : Theme.Faint,
                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                },
            },
        };
        indicator.HorizontalAlignment = HorizontalAlignment.Center;
        indicator.VerticalAlignment = VerticalAlignment.Top;
        indicator.Margin = new Thickness(0, 2, 0, 0);
        grid.Children.Add(indicator);

        var texts = new StackPanel { Margin = new Thickness(12, 3, 12, 0) };
        texts.Children.Add(new TextBlock { Text = step.Title, Style = Res("Body"), FontWeight = FontWeights.Medium });
        texts.Children.Add(new TextBlock { Text = step.Detail, Style = Res("Callout"), Margin = new Thickness(0, 2, 0, 0) });
        Grid.SetColumn(texts, 1);
        grid.Children.Add(texts);

        if (step.Action is { } action)
        {
            var button = new Button { Content = action.Title, VerticalAlignment = VerticalAlignment.Center };
            if (isNext) button.Style = Res("ProminentButton");
            button.Click += (_, _) => app.Section = action.Section;
            Grid.SetColumn(button, 2);
            grid.Children.Add(button);
        }

        // Следующий шаг — на лёгкой подложке; у последней строки нижние углы скруглены вместе с карточкой.
        return new Border
        {
            Background = isNext ? new SolidColorBrush(Color.FromArgb(0x0F, 0, 0, 0)) : Brushes.Transparent,
            CornerRadius = last ? new CornerRadius(0, 0, Theme.CardRadius, Theme.CardRadius) : new CornerRadius(0),
            Child = grid,
        };
    }

    // MARK: Советы и память по приложениям

    void UpdateAdvice(List<string> advice)
    {
        AdviceCard.Visibility = advice.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        AdviceList.Children.Clear();
        foreach (var tip in advice)
        {
            var row = new Grid { Margin = new Thickness(0, 12, 0, 0) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.Children.Add(new TextBlock
            {
                Text = Glyphs.Lightbulb, FontFamily = Glyphs.Font, FontSize = 14, Foreground = Theme.Ink,
                Width = 18, TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 1, 8, 0), VerticalAlignment = VerticalAlignment.Top,
            });
            var text = new TextBlock { Text = tip, Style = Res("Body") };
            Grid.SetColumn(text, 1);
            row.Children.Add(text);
            AdviceList.Children.Add(row);
        }
    }

    void UpdateApps(MemorySnapshot? memory)
    {
        var apps = memory?.Apps ?? [];
        AppsCard.Visibility = apps.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        AppsList.Children.Clear();
        if (memory == null) return;
        foreach (var item in apps)
        {
            var row = new Grid { Margin = new Thickness(0, 10, 0, 0) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(240) });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(80) });
            row.Children.Add(new TextBlock
            {
                Text = item.Name, Style = Res("Body"), TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis,
                Margin = new Thickness(0, 0, 12, 0), ToolTip = item.Processes > 1 ? $"Процессов: {item.Processes}" : null,
            });
            var bar = new CapacityBar
            {
                Fraction = memory.PhysicalBytes > 0 ? (double)item.Bytes / memory.PhysicalBytes : 0,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(bar, 1);
            row.Children.Add(bar);
            var value = new TextBlock { Text = Format.Memory(item.Bytes), Style = Res("Body"), TextAlignment = TextAlignment.Right };
            Grid.SetColumn(value, 2);
            row.Children.Add(value);
            AppsList.Children.Add(row);
        }
    }
}
