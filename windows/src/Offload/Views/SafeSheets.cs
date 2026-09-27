using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using Offload.Core;

namespace Offload;

/// <summary>Общее у листов сейфа: колонка содержимого, кнопки «Отмена» и главная справа внизу.
/// Пароли стираются из полей, как только лист закрыт.</summary>
public abstract class SafeSheet : SheetWindow
{
    protected readonly AppModel Model;
    protected readonly StackPanel Body = new();
    protected readonly Button Primary;
    readonly List<PasswordBox> secrets = [];

    protected SafeSheet(AppModel app, string heading, string glyph, string primary, Tone tone = Tone.Brand, string? subtitle = null)
    {
        Model = app;
        Heading = heading;
        Glyph = glyph;
        Tone = tone;
        Subtitle = subtitle;
        Content = Body;
        Primary = new Button { Content = primary, Style = Res("ProminentButton"), IsDefault = true, IsEnabled = false };
        Primary.Click += (_, _) =>
        {
            if (!Primary.IsEnabled) return;
            Perform();
            Close();
        };
        var cancel = new Button { Content = "Отмена", IsCancel = true, Margin = new Thickness(0, 0, 8, 0) };
        cancel.Click += (_, _) => Close();
        Actions = new StackPanel { Orientation = Orientation.Horizontal, Children = { cancel, Primary } };
        Closed += (_, _) =>
        {
            foreach (var box in secrets) box.Clear();
        };
    }

    protected static Style Res(string key) => (Style)Application.Current.FindResource(key);

    protected abstract void Perform();

    /// <summary>Можно ли нажать главную кнопку — пересчитывается при каждом изменении полей.</summary>
    protected abstract bool CanPerform { get; }

    protected void Refresh() => Primary.IsEnabled = CanPerform;

    protected void Add(UIElement element, double spacing = 12)
    {
        if (element is FrameworkElement framework && Body.Children.Count > 0)
            framework.Margin = new Thickness(framework.Margin.Left, framework.Margin.Top + spacing, framework.Margin.Right, framework.Margin.Bottom);
        Body.Children.Add(element);
    }

    protected PasswordBox Password(string hint)
    {
        var box = new PasswordBox { Tag = hint };
        box.PasswordChanged += (_, _) => Refresh();
        secrets.Add(box);
        return box;
    }

    protected static TextBlock Explanation(string text) => new() { Text = text, Style = Res("Callout") };

    protected static TextBlock Caption(string text) => new() { Text = text, Style = Res("Caption") };
}

/// <summary>Сменить пароль сейфа: меняется только заголовок, данные не перешифровываются.</summary>
public sealed class SafeChangePasswordSheet : SafeSheet
{
    readonly PasswordBox old;
    readonly NewPasswordFields fields = new();

    public SafeChangePasswordSheet(AppModel app)
        : base(app, "Сменить пароль сейфа", Glyphs.Key, "Сменить",
               subtitle: "Данные не перешифровываются — меняется только заголовок, поэтому это быстро.")
    {
        old = Password("Текущий пароль");
        Add(old);
        fields.AcceptabilityChanged += (_, _) => Refresh();
        Add(fields, 8);
        Add(Caption("Копии заголовка, снятые раньше, откроются старым паролем: после смены снимите новую, а старые удалите."));
        Closed += (_, _) => fields.Clear();
        Loaded += (_, _) => old.Focus();
    }

    protected override bool CanPerform => old.Password.Length > 0 && fields.IsAcceptable;

    protected override void Perform() => Model.Safe.ChangePassword(old.Password, fields.Password, Model);
}

/// <summary>Вернуть диску место, освободившееся внутри сейфа. На Windows образ для этого переписывается заново.</summary>
public sealed class SafeCompactSheet : SafeSheet
{
    readonly PasswordBox password;

    public SafeCompactSheet(AppModel app) : base(app, "Вернуть место на диск", "", "Сжать")
    {
        Add(Explanation("Файлы, удалённые или возвращённые из сейфа, продолжают занимать место на диске: образ сам не уменьшается, хотя внутри это место идёт под новые данные. Чтобы вернуть его диску, OffLoadAI создаст рядом новый сейф с тем же паролем и пределом, перенесёт в него всё содержимое со сверкой SHA-256 и только потом заменит им старый. Если прервётся — старый сейф останется цел."));
        Add(Caption("Рядом с сейфом нужно свободное место под всё его содержимое, а на больших сейфах это займёт время. Сколько вернулось на самом деле, OffLoadAI скажет."));
        password = Password("Пароль сейфа");
        Add(password);
        Loaded += (_, _) => password.Focus();
    }

    protected override bool CanPerform => password.Password.Length > 0;

    protected override void Perform() => Model.Safe.Compact(password.Password, Model);
}

/// <summary>Увеличить предел сейфа. Открывается и из «Сейфа», и из «Разобрать», когда выбранное не помещается:
/// needed — сколько человек собирается положить, чтобы сразу предложить подходящий предел.</summary>
public sealed class GrowSafeSheet : SafeSheet
{
    readonly long needed;
    readonly long target;
    readonly List<SafeView.Choice<long>> choices;
    readonly ComboBox? picker;
    readonly TextBlock? tooSmall;
    readonly Grid? openRow;
    readonly PasswordBox? password;

    public GrowSafeSheet(AppModel app, long needed = 0)
        : base(app, "Увеличить предел сейфа", "", "Увеличить",
               subtitle: $"Сейчас — {Format.Bytes(app.Safe.Current?.SizeLimit ?? 0)}")
    {
        this.needed = needed;
        var safe = app.Safe;
        long current = safe.Current?.SizeLimit ?? 0;
        var host = app.Destination;
        choices = host == null ? [] : SafeModel.LimitChoices(host, current)
            .Select(v => new SafeView.Choice<long>(v, v == host.TotalBytes ? $"весь диск ({Format.Bytes(v)})" : Format.Bytes(v))).ToList();
        target = (safe.Current?.Allocated ?? 0) + needed;

        Add(Explanation("Содержимое остаётся на месте, а места на диске образ занимает столько же, сколько занимал: предел лишь разрешает ему расти."));
        if (choices.Count == 0)
        {
            Add(new NoticeView { Kind = NoticeKind.Info, Text = "Сейф уже может занять весь диск — увеличивать некуда." });
        }
        else
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(new TextBlock { Text = "Новый предел", Style = Res("Body"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
            picker = new ComboBox
            {
                ItemsSource = choices, DisplayMemberPath = "Title", MinWidth = 180,
                SelectedItem = choices.FirstOrDefault(c => c.Value >= target) ?? choices.Last(),
            };
            picker.SelectionChanged += (_, _) => Refresh();
            row.Children.Add(picker);
            Add(row);
            tooSmall = new TextBlock { Style = Res("Caption"), Foreground = Theme.Ink, Visibility = Visibility.Collapsed };
            Add(tooSmall, 6);

            openRow = new Grid();
            openRow.ColumnDefinitions.Add(new ColumnDefinition());
            openRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            openRow.Children.Add(new TextBlock { Text = "Сейф открыт — увеличить можно только закрытый.", Style = Res("Callout"), VerticalAlignment = VerticalAlignment.Center });
            var close = new Button { Content = "Закрыть сейф" };
            close.Click += (_, _) => app.Safe.Close(app);
            Grid.SetColumn(close, 1);
            openRow.Children.Add(close);
            Add(openRow);
            password = Password("Пароль сейфа");
            Add(password, 0);
            Add(Caption("На время увеличения сейф ненадолго подключится без буквы диска: файлы не видны ни Проводнику, ни программам."));
        }
        safe.PropertyChanged += Safe_Changed;
        Closed += (_, _) => safe.PropertyChanged -= Safe_Changed;
        Loaded += (_, _) => password?.Focus();
        Refresh();
        UpdateState();
    }

    long? Chosen => (picker?.SelectedItem as SafeView.Choice<long>)?.Value;

    void Safe_Changed(object? sender, PropertyChangedEventArgs e) => UpdateState();

    /// <summary>Сейф могли закрыть прямо отсюда — поле пароля появляется вместо строки «Сейф открыт».</summary>
    void UpdateState()
    {
        bool open = Model.Safe.IsOpen;
        if (openRow != null) openRow.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        if (password != null) password.Visibility = open ? Visibility.Collapsed : Visibility.Visible;
        Refresh();
    }

    protected override bool CanPerform
    {
        get
        {
            if (tooSmall != null)
            {
                bool small = needed > 0 && Chosen is { } chosen && chosen < target;
                tooSmall.Visibility = small ? Visibility.Visible : Visibility.Collapsed;
                tooSmall.Text = $"Выбранное для сейфа ({Format.Bytes(needed)}) при таком пределе поместится не целиком.";
            }
            return Chosen != null && password is { Password.Length: > 0 } && !Model.Safe.IsOpen && Model.Safe.Activity == null;
        }
    }

    protected override void Perform()
    {
        if (Chosen is { } chosen && password != null) Model.Safe.Grow(chosen, password.Password, Model);
    }
}

/// <summary>Восстановить заголовок из копии — если сейф перестал открываться верным паролем.</summary>
public sealed class SafeRestoreHeaderSheet : SafeSheet
{
    string? file;
    readonly TextBlock fileName;
    readonly PasswordBox password;

    public SafeRestoreHeaderSheet(AppModel app) : base(app, "Восстановить заголовок", Glyphs.History, "Восстановить", Tone.Caution)
    {
        Add(Explanation("Нужно, если сейф перестал открываться верным паролем (испортился заголовок). Сейф откроется паролем, который действовал, когда снималась копия. Если пароль к копии не подойдёт, прежний заголовок вернётся как был."));

        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(new TextBlock { Text = Glyphs.Document, Style = Res("Icon"), Foreground = Theme.Muted, Margin = new Thickness(0, 0, 8, 0) });
        fileName = new TextBlock
        {
            Text = "Копия не выбрана", Style = Res("Body"), Foreground = Theme.Faint, TextWrapping = TextWrapping.NoWrap,
            TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(fileName, 1);
        row.Children.Add(fileName);
        var choose = new Button { Content = "Выбрать…", Margin = new Thickness(8, 0, 0, 0) };
        choose.Click += (_, _) => Choose();
        Grid.SetColumn(choose, 2);
        row.Children.Add(choose);
        Add(new Border
        {
            Padding = new Thickness(10), CornerRadius = new CornerRadius(8),
            Background = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromArgb(0x0A, 0, 0, 0)),
            Child = row,
        });

        password = Password("Пароль этой копии");
        Add(password);
    }

    void Choose()
    {
        var dialog = new OpenFileDialog
        {
            Title = "Файл копии заголовка (.offload-header)",
            Filter = "Копия заголовка сейфа (*.offload-header)|*.offload-header|Все файлы (*.*)|*.*",
            CheckFileExists = true,
            Multiselect = false,
        };
        if (dialog.ShowDialog(this) != true) return;
        file = dialog.FileName;
        fileName.Text = Path.GetFileName(file);
        fileName.Foreground = Theme.Ink;
        fileName.ToolTip = file;
        Refresh();
        password.Focus();
    }

    protected override bool CanPerform => file != null && password.Password.Length > 0;

    protected override void Perform()
    {
        if (file != null) Model.Safe.RestoreHeader(file, password.Password, Model);
    }
}
