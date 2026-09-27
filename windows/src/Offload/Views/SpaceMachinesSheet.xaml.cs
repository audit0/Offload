using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Offload.Core;

namespace Offload;

/// <summary>Виртуальные машины — дистрибутивы WSL, машины VirtualBox и VMware: сколько занимает каждая
/// и как освободить место, не потеряв их. Удаляют и переносят машины их собственные программы.</summary>
public partial class SpaceMachinesSheet : SheetWindow
{
    const long Gibibyte = 1L << 30;

    readonly AppModel app;
    /// <summary>Строка, из которой открыт лист: папка машин, папка внутри неё или сама машина.</summary>
    readonly SpaceItem item;
    List<VirtualMachine>? machines;

    public SpaceMachinesSheet(AppModel app, SpaceItem item)
    {
        this.app = app;
        this.item = item;
        InitializeComponent();
        Subtitle = "Считаю, сколько занимает каждая машина…";
        ShowSteps();
        Loaded += (_, _) => Load();
    }

    async void Load()
    {
        // В демонстрации настоящие машины не показываются.
        if (Demo.IsOn) machines = Demo.Machines;
        else
        {
            var home = app.Rules.Home;
            var focus = item.Path;
            machines = await Task.Run(() =>
            {
                var list = VirtualMachines.List(home);
                // Машину из другой папки в стандартных её не найти — покажем и её.
                if (VirtualMachines.IsMachineFile(focus) && !list.Any(m => Paths.IsWithin(focus, m.Path) || Paths.IsWithin(m.Path, focus)))
                {
                    try { list.Insert(0, Focused(focus)); }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
                }
                return list;
            });
        }
        if (!IsLoaded) return;
        long total = machines.Sum(m => m.Bytes);
        Subtitle = $"{machines.Count} {Plural.Ru(machines.Count, "машина", "машины", "машин")} · {Format.Bytes(total)}";
        ShowList();
        ShowSteps();
    }

    /// <summary>Файл машины, открытый из списка: у VirtualBox и VMware машина — вся папка с этим файлом.</summary>
    static VirtualMachine Focused(string path) => Paths.Extension(path).ToLowerInvariant() switch
    {
        "vbox" => VirtualMachines.Machine(Paths.Parent(path), MachineKind.VirtualBox),
        "vdi" => VirtualMachines.Machine(path, MachineKind.VirtualBox),
        "vmx" => VirtualMachines.Machine(Paths.Parent(path), MachineKind.VMware),
        "vmdk" => VirtualMachines.Machine(path, MachineKind.VMware),
        _ => VirtualMachines.Machine(path, MachineKind.Wsl),
    };

    // MARK: Список

    void ShowList()
    {
        LoadingRow.Visibility = Visibility.Collapsed;
        var list = machines ?? [];
        EmptyNotice.Visibility = list.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ListCard.Visibility = list.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        ListScroller.MaxHeight = list.Count > 5 ? 300 : double.PositiveInfinity;
        Rows.Children.Clear();
        foreach (var machine in list)
        {
            if (Rows.Children.Count > 0) Rows.Children.Add(Divider());
            Rows.Children.Add(MachineRow(machine));
        }
        if (Rest() is { } rest)
        {
            Rows.Children.Add(Divider());
            Rows.Children.Add(Row(Glyphs.Tray, Tone.Neutral, $"Прочее в папке «{item.Name}»", "Не машины: кеш и данные самих программ", rest, null));
        }
    }

    /// <summary>Сколько в строке занято не машинами: кеш и прочие данные программ.</summary>
    long? Rest()
    {
        if (machines == null || !item.IsMeasured || !item.IsDirectory) return null;
        var inside = machines.Where(m => Paths.IsInside(m.Path, item.Path)).ToList();
        if (inside.Count == 0) return null;
        long rest = item.Bytes - inside.Sum(m => m.Bytes);
        return rest >= 512L << 20 ? rest : null;
    }

    static Separator Divider() => new() { Style = (Style)Application.Current.FindResource("RowDivider"), Margin = new Thickness(56, 0, 0, 0) };

    FrameworkElement MachineRow(VirtualMachine machine)
    {
        var parts = new List<string> { machine.KindTitle };
        if (machine.Modified is { } modified) parts.Add($"менялась {Format.Relative(modified)}");
        // Диски машин растут по мере записи: где разрежённых файлов нет, машина займёт полный объём.
        if (machine.LogicalBytes > machine.Bytes + Gibibyte) parts.Add($"полный объём дисков {Format.Bytes(machine.LogicalBytes)}");
        return Row(Glyphs.Computer, Tone.Brand, machine.Name, string.Join(" · ", parts), machine.Bytes, machine.Path);
    }

    static FrameworkElement Row(string glyph, Tone tone, string title, string caption, long bytes, string? reveal)
    {
        var grid = new Grid { Margin = new Thickness(14, 10, 14, 10) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(34) });
        grid.Children.Add(new IconTile { Glyph = glyph, Tone = tone, Size = 30, VerticalAlignment = VerticalAlignment.Center });
        var text = new StackPanel { Margin = new Thickness(12, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.Medium, TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = reveal });
        text.Children.Add(new TextBlock
        {
            Text = caption, Style = (Style)Application.Current.FindResource("Caption"), TextWrapping = TextWrapping.NoWrap,
            TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 2, 0, 0),
        });
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        var size = new TextBlock { Text = Format.Bytes(bytes), FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(size, 2);
        grid.Children.Add(size);
        if (reveal != null)
        {
            var button = new Button
            {
                Style = (Style)Application.Current.FindResource("IconButton"), Content = Glyphs.Search, ToolTip = "Показать в Проводнике",
                HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center,
            };
            button.Click += (_, _) => Ui.Reveal(reveal);
            Grid.SetColumn(button, 3);
            grid.Children.Add(button);
        }
        return grid;
    }

    // MARK: Как освободить

    void ShowSteps()
    {
        // Пока список не готов или пуст — объясняем для всех трёх программ.
        HashSet<MachineKind> kinds = machines is { Count: > 0 } ? machines.Select(m => m.Kind).ToHashSet() : [MachineKind.Wsl, MachineKind.VirtualBox, MachineKind.VMware];
        bool wsl = kinds.Contains(MachineKind.Wsl), box = kinds.Contains(MachineKind.VirtualBox), vmware = kinds.Contains(MachineKind.VMware);
        var distros = (machines ?? []).Where(m => m.Kind == MachineKind.Wsl).ToList();
        string name = distros.Count == 1 ? Quote(distros[0].Name) : "<имя>";
        string folder = app.Target is { } target ? Quote(System.IO.Path.Combine(target.MountPoint, "WSL", distros.Count == 1 ? distros[0].Name : "<имя>")) : "<папка>";

        Steps.Children.Clear();

        var remove = new List<UIElement>();
        if (wsl)
        {
            remove.Add(Paragraph("WSL — в терминале. Дистрибутив удаляется вместе с диском сразу и безвозвратно: вернуть его будет нельзя. Нужное сначала сохраните (шаг 3)."));
            remove.Add(Code($"wsl --unregister {name}"));
        }
        if (box) remove.Add(Paragraph("VirtualBox: «Машина → Удалить…» (Machine → Remove…) → «Удалить все файлы». Место освободится сразу."));
        if (vmware) remove.Add(Paragraph("VMware: правый клик по машине → «Manage → Delete from Disk». Машина удаляется вместе с дисками."));
        Steps.Children.Add(Step(1, "Удалить ненужную", remove));

        var move = new List<UIElement>();
        if (wsl)
        {
            move.Add(Paragraph("WSL переносит диск дистрибутива сама и запоминает новое место (нужна WSL 2.0 или новее). Выберите папку в сейфе или на диске:"));
            move.Add(Code($"wsl --shutdown\nwsl --manage {name} --move {folder}"));
        }
        if (box) move.Add(Paragraph("VirtualBox: выключите машину, «Машина → Переместить…» (Machine → Move…) и выберите папку в сейфе или на диске. VirtualBox перенесёт её и запомнит новое место."));
        if (vmware) move.Add(Paragraph("VMware: выключите машину, перенесите её папку целиком и откройте файл .vmx из нового места («File → Open»); на вопрос ответьте «I Moved It»."));
        move.Add(Paragraph("Перед запуском такой машины подключите диск и откройте сейф — иначе программа покажет её недоступной, — а перед сном компьютера и закрытием сейфа выключите её: диск машины, у которой отключили сейф, может испортиться."));
        if (DestinationNote() is { } note) move.Add(new NoticeView { Kind = NoticeKind.Warning, Text = note, Margin = new Thickness(0, 8, 0, 0) });
        Steps.Children.Add(Step(2, "Перенести на внешний диск", move));

        var copy = new List<UIElement>();
        if (wsl)
        {
            copy.Add(Paragraph("WSL: архив дистрибутива, из которого он восстанавливается командой wsl --import. Положите его в сейф — и дистрибутив можно удалить."));
            copy.Add(Code($"wsl --export {name} {(app.Target is { } t ? Quote(System.IO.Path.Combine(t.MountPoint, (distros.Count == 1 ? distros[0].Name : "<имя>") + ".tar")) : "<файл.tar>")}"));
        }
        if (box) copy.Add(Paragraph("VirtualBox: «Файл → Экспорт конфигураций…» (Export Appliance) — машина целиком в одном файле .ova."));
        if (vmware) copy.Add(Paragraph("VMware: папку выключенной машины можно просто скопировать."));
        Steps.Children.Add(Step(3, "Сохранить копию", copy));
    }

    static string Quote(string text) => text.Contains(' ') ? $"\"{text}\"" : text;

    /// <summary>Оговорка про диск, выбранный для переноса: FAT32 машину не примет, exFAT раздует её диски.</summary>
    string? DestinationNote()
    {
        if (app.Destination is not { } disk) return null;
        var list = machines ?? [];
        if (disk.MaxFileSize is { } limit && list.Any(m => m.LargestFile > limit))
            return $"Диск «{disk.Name}» — {disk.FsDisplayName}: файлы больше 4 ГБ он не принимает, машину туда не перенести. Переносите в сейф.";
        if (disk.KeepsSparseFiles || !list.Any(m => m.LogicalBytes > m.Bytes + Gibibyte)) return null;
        return $"Диск «{disk.Name}» — {disk.FsDisplayName}: разрежённых файлов там нет, и машина займёт на нём полный объём дисков, а не нынешний размер. Сейф внутри — NTFS, он разрежённые файлы хранит.";
    }

    static FrameworkElement Step(int number, string title, IEnumerable<UIElement> body)
    {
        var grid = new Grid { Margin = new Thickness(0, 0, 0, 14) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var badge = new Border
        {
            Width = 18, Height = 18, CornerRadius = new CornerRadius(9), Background = Theme.Ink, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 1, 10, 0),
            Child = new TextBlock
            {
                Text = number.ToString(), Foreground = Brushes.White, FontSize = 10.5, FontWeight = FontWeights.Bold,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            },
        };
        grid.Children.Add(badge);
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.Medium });
        foreach (var element in body) stack.Children.Add(element);
        Grid.SetColumn(stack, 1);
        grid.Children.Add(stack);
        return grid;
    }

    static TextBlock Paragraph(string text) => new()
    {
        Text = text, Style = (Style)Application.Current.FindResource("Callout"), Margin = new Thickness(0, 3, 0, 0),
    };

    /// <summary>Команда, которую можно выделить и скопировать в терминал.</summary>
    static Border Code(string text) => new()
    {
        CornerRadius = new CornerRadius(7), Background = new SolidColorBrush(Color.FromArgb(0x0F, 0, 0, 0)), Padding = new Thickness(10, 6, 10, 6),
        Margin = new Thickness(0, 6, 0, 2),
        Child = new TextBox
        {
            Text = text, Style = (Style)Application.Current.FindResource("SelectableText"), FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = 12, TextWrapping = TextWrapping.Wrap,
        },
    };

    void Done_Click(object sender, RoutedEventArgs e) => Close();
}
