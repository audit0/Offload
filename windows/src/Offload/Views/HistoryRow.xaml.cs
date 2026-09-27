using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using Offload.Core;

namespace Offload;

/// <summary>Как выглядит запись: в сейфе — замок, открыто на диске — диск, возвращённая — стрелка назад.</summary>
public static class HistoryDisplay
{
    static readonly CultureInfo Russian = CultureInfo.GetCultureInfo("ru-RU");

    public static string Glyph(MoveRecord record) => record.Restored ? Glyphs.ArrowReturn : record.IsEncrypted ? Glyphs.Lock : Glyphs.Drive;
    public static Tone Tone(MoveRecord record) => record.Restored ? Offload.Tone.Neutral : record.IsEncrypted ? Offload.Tone.Good : Offload.Tone.Caution;
    public static string Location(MoveRecord record) => record.IsEncrypted ? $"в сейфе «{record.VolumeName}»" : $"открыто на «{record.VolumeName}»";
    /// <summary>Почему вернуть сейчас нельзя.</summary>
    public static string UnavailableReason(MoveRecord record) => record.IsEncrypted ? "Сейф закрыт" : "Диск не подключён";

    /// <summary>«25 сент. 2026 г., 20:40».</summary>
    public static string Date(DateTime date) =>
        (date.Kind == DateTimeKind.Local ? date : date.ToLocalTime()).ToString("d MMM yyyy 'г.', HH:mm", Russian);

    public static string Count(long count) => count.ToString("N0", Russian);

    /// <summary>Папка, в которой лежал объект. Пути записей с Mac разделены «/».</summary>
    public static string Parent(string path)
    {
        int index = path.TrimEnd('\\', '/').LastIndexOfAny(['\\', '/']);
        return index <= 0 ? path : path[..index];
    }

    public static string LastName(string path) => path.TrimEnd('\\', '/') is var trimmed && trimmed.LastIndexOfAny(['\\', '/']) is var index and >= 0
        ? trimmed[(index + 1)..] : path;

    /// <summary>Путь относительно домашней папки; у записей с Mac — «~/…» от их домашней папки.</summary>
    public static string Relative(string path, string home)
    {
        if (!path.StartsWith('/')) return Ui.RelativeToHome(path, home);
        var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length >= 2 && parts[0] == "Users" ? "~/" + string.Join('/', parts.Skip(2)) : path;
    }
}

public partial class HistoryRow : UserControl
{
    readonly MoveRecord record;
    readonly bool archiveExists;

    public Action<MoveRecord>? OnRestore { get; set; }

    /// <summary>Есть ли архив на диске, считается один раз при перечитывании списка: опрос внешнего диска
    /// из каждой строки будил бы уснувший диск при каждой перерисовке.</summary>
    public HistoryRow(MoveRecord record, string home, bool available, bool archiveExists, bool busy)
    {
        this.record = record;
        this.archiveExists = archiveExists;
        InitializeComponent();
        Tile.Glyph = HistoryDisplay.Glyph(record);
        Tile.Tone = HistoryDisplay.Tone(record);
        NameText.Text = record.OriginalName;
        PathText.Text = HistoryDisplay.Relative(record.OriginalPath, home);
        PathText.ToolTip = record.OriginalPath;
        DetailText.Text = $"{HistoryDisplay.Date(record.Date)} · {Format.Bytes(record.Bytes)} · файлов {HistoryDisplay.Count(record.Files)} · {HistoryDisplay.Location(record)}";
        if (!string.IsNullOrEmpty(record.Note))
        {
            NoteText.Text = record.Note;
            NoteText.Visibility = Visibility.Visible;
        }
        bool fromMac = record.IsFromMac && !record.Restored;
        MacText.Visibility = fromMac ? Visibility.Visible : Visibility.Collapsed;

        if (record.Restored) Pill("Возвращено", Glyphs.Check, Offload.Tone.Good);
        else if (fromMac) Pill("Вернуть можно на Mac", Glyphs.Computer, Offload.Tone.Neutral);
        else if (available)
        {
            RestoreButton.Visibility = Visibility.Visible;
            RestoreButton.IsEnabled = !busy;
        }
        else Pill(HistoryDisplay.UnavailableReason(record), null, Offload.Tone.Neutral);

        RevealButton.Visibility = archiveExists ? Visibility.Visible : Visibility.Collapsed;
        MouseEnter += (_, _) => RevealButton.Opacity = 1;
        MouseLeave += (_, _) => RevealButton.Opacity = 0;

        var menu = new ContextMenu();
        if (archiveExists)
        {
            var reveal = new MenuItem { Header = "Показать на диске" };
            reveal.Click += (_, _) => Ui.Reveal(record.ArchivedPath);
            menu.Items.Add(reveal);
        }
        if (available && !record.Restored && !fromMac)
        {
            var restore = new MenuItem { Header = "Вернуть…", IsEnabled = !busy };
            restore.Click += (_, _) => OnRestore?.Invoke(record);
            menu.Items.Add(restore);
        }
        if (menu.Items.Count > 0) ContextMenu = menu;
    }

    void Pill(string text, string? glyph, Tone tone)
    {
        StatePill.Text = text;
        StatePill.Glyph = glyph;
        StatePill.Tone = tone;
        StatePill.Visibility = Visibility.Visible;
    }

    void Reveal_Click(object sender, RoutedEventArgs e)
    {
        if (archiveExists) Ui.Reveal(record.ArchivedPath);
    }

    void Restore_Click(object sender, RoutedEventArgs e) => OnRestore?.Invoke(record);
}
