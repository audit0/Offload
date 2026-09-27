using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;
using Offload.Core;

namespace Offload;

public partial class SafeView : UserControl
{
    readonly AppModel app;
    bool subscribed;

    /// <summary>Заводится ещё один сейф, хотя на диске уже есть образ.</summary>
    bool creatingAnother;
    /// <summary>Предел нового сейфа; null — весь диск.</summary>
    long? newLimit;
    /// <summary>Какие из лежащих открыто пунктов человек снял — их не переносить.</summary>
    readonly HashSet<Guid> excluded = [];

    // Поля ввода живут дольше перестройки карточки: иначе набранный пароль пропадал бы при любом обновлении.
    readonly NewPasswordFields createFields = new() { MaxWidth = 440, HorizontalAlignment = HorizontalAlignment.Left };
    readonly SafeUnlockRow unlockRow = new() { MaxWidth = 440, HorizontalAlignment = HorizontalAlignment.Left };
    readonly Button createButton;
    /// <summary>Отпечаток того, из чего собрана карточка состояния: перестраиваем, только когда он изменился.</summary>
    string? statusKey;
    bool updatingPickers;

    /// <summary>Пункт выпадающего списка: значение и подпись.</summary>
    public sealed record Choice<T>(T Value, string Title)
    {
        /// <summary>Подпись в закрытом списке: шаблон ComboBox показывает сам элемент.</summary>
        public override string ToString() => Title;
    }

    public SafeView(AppModel app)
    {
        this.app = app;
        InitializeComponent();
        DataContext = app;
        IdlePicker.ItemsSource = SafeModel.IdleChoices.Select(m => new Choice<int>(m, m == 0 ? "не закрывать" : $"{m} мин")).ToList();
        createButton = new Button { Content = "Создать сейф", Style = Res("ProminentButton"), IsDefault = true, IsEnabled = false };
        createButton.Click += Create_Click;
        createFields.AcceptabilityChanged += (_, _) => createButton.IsEnabled = createFields.IsAcceptable;
        Loaded += (_, _) =>
        {
            Subscribe(true);
            statusKey = null;
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
            app.Safe.PropertyChanged += Changed;
            app.History.PropertyChanged += Changed;
        }
        else
        {
            app.PropertyChanged -= Changed;
            app.Safe.PropertyChanged -= Changed;
            app.History.PropertyChanged -= Changed;
        }
    }

    void Changed(object? sender, PropertyChangedEventArgs e)
    {
        // Ошибка открытия показывается под полем пароля им самим — карточку ради неё не перестраиваем.
        if (e.PropertyName == nameof(SafeModel.UnlockError)) return;
        Update();
    }

    static Style Res(string key) => (Style)Application.Current.FindResource(key);

    void Update()
    {
        var safe = app.Safe;
        Message.Message = safe.Message;
        Message.Visibility = safe.Message != null ? Visibility.Visible : Visibility.Collapsed;
        ActivityPill.Visibility = safe.Activity != null ? Visibility.Visible : Visibility.Collapsed;
        ActivityText.Text = safe.Activity ?? "";
        // Пока с сейфом что-то делается, кнопки заблокированы; перенос в сейф при этом можно остановить.
        Body.IsEnabled = !(safe.Activity != null && safe.MigrationProgress == null);

        bool encrypted = safe.Current?.IsEncrypted == true;
        AutoCloseSection.Visibility = encrypted ? Visibility.Visible : Visibility.Collapsed;
        InterruptRow.Detail = safe.InterruptOperations
            ? "Идущий перенос отменится, оригиналы останутся на месте: они удаляются только после сверки копии."
            : "Если в сейф идёт копирование, он закроется сразу после его окончания.";
        ExposureSection.Visibility = app.Destination != null ? Visibility.Visible : Visibility.Collapsed;
        UpdateKeySection(encrypted);
        UpdateStatus();
        UpdateExposure();
    }

    /// <summary>Добавить в колонку с промежутком сверху.</summary>
    static void Add(Panel panel, UIElement element, double spacing = 16)
    {
        if (element is FrameworkElement framework && panel.Children.Count > 0)
        {
            var margin = framework.Margin;
            framework.Margin = new Thickness(margin.Left, margin.Top + spacing, margin.Right, margin.Bottom);
        }
        panel.Children.Add(element);
    }

    /// <summary>Снять долгоживущий элемент с прежнего места, прежде чем поставить на новое.</summary>
    static T Detach<T>(T element, Thickness margin) where T : FrameworkElement
    {
        switch (element.Parent)
        {
            case Panel panel: panel.Children.Remove(element); break;
            case Decorator decorator: decorator.Child = null; break;
            case ContentControl control: control.Content = null; break;
        }
        element.Margin = margin;
        return element;
    }

    static TextBlock Text(string text, string style = "Body", Brush? foreground = null)
    {
        var block = new TextBlock { Text = text, Style = Res(style) };
        if (foreground != null) block.Foreground = foreground;
        return block;
    }

    static TextBlock Display(string text, double size) =>
        new() { Text = text, Style = Res("Display"), FontSize = size, TextWrapping = TextWrapping.Wrap };

    /// <summary>Значок и заголовок с пояснением — верх карточки состояния.</summary>
    static Grid Header(string glyph, Tone tone, string title, string? detail, UIElement? accessory = null)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new IconTile { Glyph = glyph, Tone = tone, Size = 52, VerticalAlignment = VerticalAlignment.Top });
        var texts = new StackPanel { Margin = new Thickness(14, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(Display(title, 22));
        if (detail != null) texts.Children.Add(new TextBlock { Text = detail, Style = Res("Body"), Foreground = Theme.Muted, Margin = new Thickness(0, 3, 0, 0) });
        Grid.SetColumn(texts, 1);
        grid.Children.Add(texts);
        if (accessory != null)
        {
            Grid.SetColumn(accessory, 2);
            grid.Children.Add(accessory);
        }
        return grid;
    }

    static Button GlyphButton(string glyph, string title, bool prominent = false)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        content.Children.Add(new TextBlock { Text = glyph, FontFamily = Glyphs.Font, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0) });
        content.Children.Add(new TextBlock { Text = title });
        var button = new Button { Content = content };
        if (prominent) button.Style = Res("ProminentButton");
        return button;
    }

    // MARK: Состояние

    void UpdateStatus()
    {
        var safe = app.Safe;
        var host = app.Destination;
        var state = safe.Current;
        var key = string.Join("|", host?.Id, host?.AvailableBytes, state, string.Join(";", state?.Candidates ?? []), creatingAnother,
                              safe.PendingClose, app.SafeVolume?.AvailableBytes);
        if (key == statusKey) return;
        statusKey = key;
        StatusPanel.Children.Clear();
        if (host == null)
        {
            Add(StatusPanel, Header(Glyphs.DriveExternal, Tone.Neutral, "Нет внешнего диска", "Подключите внешний диск — сейф живёт на нём."));
            return;
        }
        if (state == null || state.VolumeId != host.Id)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(new ProgressBar { Style = Res("Spinner") });
            row.Children.Add(new TextBlock { Text = $"Смотрю, что на диске «{host.Name}»…", Style = Res("Body"), Foreground = Theme.Muted, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
            Add(StatusPanel, row);
            return;
        }
        if (!state.Exists || creatingAnother)
            CreateForm(host, creatingAnother ? state : null);
        else if (!state.IsEncrypted)
        {
            Add(StatusPanel, new NoticeView
            {
                Kind = NoticeKind.Error,
                Text = $"Образ «{Path.GetFileName(state.ImagePath)}» не зашифрован или шифрование не подтверждается. Offload не будет класть в него данные.",
            });
            CandidatesPicker(state);
            var another = new Button { Content = "Создать настоящий сейф" };
            another.Click += (_, _) => { creatingAnother = true; statusKey = null; Update(); };
            Add(StatusPanel, another);
        }
        else OpenedOrClosed(state, host);
    }

    void OpenedOrClosed(SafeModel.State state, VolumeInfo host)
    {
        var safe = app.Safe;
        bool isOpen = state.Mount != null;
        StackPanel? buttons = null;
        if (state.Mount is { } mount)
        {
            buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            var reveal = new Button { Content = "Показать в Проводнике" };
            reveal.Click += (_, _) =>
            {
                safe.NoteUse();
                // Открываем саму папку тома сейфа, а не выделяем его в «Этом компьютере».
                Ui.Open(mount);
            };
            var close = GlyphButton(Glyphs.Lock, "Закрыть сейф", prominent: true);
            close.Margin = new Thickness(8, 0, 0, 0);
            close.ToolTip = "Закрыть сейф (Ctrl+Shift+L)";
            close.Click += (_, _) => safe.Close(app);
            buttons.Children.Add(reveal);
            buttons.Children.Add(close);
        }
        Add(StatusPanel, Header(isOpen ? Glyphs.Unlock : Glyphs.Lock, isOpen ? Tone.Caution : Tone.Good,
            isOpen ? "Сейф открыт" : "Сейф закрыт",
            isOpen ? "Перенос, бэкап и ключи сейчас идут сюда. Закройте после работы."
                   : "На диске только шифротекст. Чтобы класть в сейф или брать из него, откройте его паролем.",
            buttons));

        if (!isOpen) Add(StatusPanel, Detach(unlockRow, new Thickness(0)));
        else if (safe.PendingClose is { } pending)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(new TextBlock { Text = Glyphs.Clock, FontFamily = Glyphs.Font, FontSize = 13, Foreground = Theme.Muted, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
            row.Children.Add(Text($"Закроется после копирования ({pending})", "Callout"));
            Add(StatusPanel, row);
        }

        Add(StatusPanel, new Border { Height = 1, Background = new SolidColorBrush(Color.FromArgb(0x14, 0, 0, 0)) });
        var facts = new Grid();
        void Fact(string value, string title, string? tip = null)
        {
            facts.ColumnDefinitions.Add(new ColumnDefinition());
            var stack = new StackPanel { ToolTip = tip, Background = Brushes.Transparent };
            stack.Children.Add(Display(value, 20));
            stack.Children.Add(new TextBlock { Text = title, Style = Res("Caption"), Margin = new Thickness(0, 2, 0, 0) });
            Grid.SetColumn(stack, facts.ColumnDefinitions.Count - 1);
            facts.Children.Add(stack);
        }
        Fact(Format.Bytes(state.Allocated), "занимает на диске");
        if (state.SizeLimit is { } limit) Fact(Format.Bytes(limit), "предел роста");
        if (app.SafeVolume is { } volume) Fact(Format.Bytes(volume.AvailableBytes), "свободно внутри", "Меньшее из свободного внутри образа и на самом диске");
        Add(StatusPanel, facts);

        var info = new StackPanel();
        TextBlock.SetFontSize(info, 12.5);
        info.Children.Add(new InfoRow
        {
            Title = "Образ",
            Content = new TextBox { Text = $"«{Path.GetFileName(state.ImagePath)}» на «{host.Name}»", Style = Res("SelectableText"), FontSize = 12.5, TextAlignment = TextAlignment.Right },
        });
        var encryption = "BitLocker XTS-AES-256" + (state.Info?.Version is { } version ? $", формат {version}" : "")
                         + (state.Info is { } known ? $" · паролей: {known.PassphraseCount}" : "");
        info.Children.Add(new InfoRow { Title = "Шифрование", Content = new TextBlock { Text = encryption }, Margin = new Thickness(0, 6, 0, 0) });
        Add(StatusPanel, info);

        if (state.SizeLimit is { } small && small < 20L << 30)
        {
            Add(StatusPanel, new NoticeView
            {
                Kind = NoticeKind.Warning,
                Text = $"Этот сейф ограничен {Format.Bytes(small)}: для ключей хватит, а для переноса больших папок — нет. Предел можно увеличить — содержимое останется на месте.",
            });
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            var grow = GlyphButton("", "Увеличить предел…", prominent: true);
            grow.Click += Grow_Click;
            var another = new Button { Content = "Создать другой сейф…", Margin = new Thickness(8, 0, 0, 0) };
            another.Click += (_, _) => { creatingAnother = true; statusKey = null; Update(); };
            row.Children.Add(grow);
            row.Children.Add(another);
            Add(StatusPanel, row);
        }
        CandidatesPicker(state);
    }

    /// <summary>Несколько зашифрованных образов на диске: какой из них считать сейфом.</summary>
    void CandidatesPicker(SafeModel.State state)
    {
        if (state.Candidates.Count <= 1) return;
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(new TextBlock { Text = "Какой образ — сейф", Style = Res("Body"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        var choices = state.Candidates.Select(p => new Choice<string>(p, Path.GetFileName(p))).ToList();
        var picker = new ComboBox
        {
            ItemsSource = choices, DisplayMemberPath = "Title", MinWidth = 220,
            SelectedItem = choices.FirstOrDefault(c => Paths.Same(c.Value, state.ImagePath)),
            IsEnabled = state.Mount == null,
            ToolTip = state.Mount != null ? "Закройте сейф, чтобы выбрать другой образ" : null,
        };
        picker.SelectionChanged += (_, _) =>
        {
            if (picker.SelectedItem is Choice<string> choice && !Paths.Same(choice.Value, state.ImagePath)) app.Safe.Choose(choice.Value, app);
        };
        row.Children.Add(picker);
        Add(StatusPanel, row);
    }

    void CreateForm(VolumeInfo host, SafeModel.State? replacing)
    {
        Add(StatusPanel, Header(Glyphs.Shield, Tone.Brand,
            replacing == null ? $"На диске «{host.Name}» сейфа пока нет" : $"Новый сейф на диске «{host.Name}»",
            "Образ VHDX растёт по мере заполнения: места он занимает ровно столько, сколько в нём лежит, а предел лишь не даёт ему вырасти больше. Предел потом можно увеличить. Придумайте пароль, который не используете больше нигде. Надёжнее всего — фраза из 4–6 случайных слов."));

        var limits = new StackPanel();
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(new TextBlock { Text = "Предел сейфа", Style = Res("Body"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        var choices = SafeModel.LimitChoices(host)
            .Select(limit => new Choice<long?>(limit == host.TotalBytes ? null : limit,
                                                limit == host.TotalBytes ? $"весь диск ({Format.Bytes(limit)})" : Format.Bytes(limit)))
            .ToList();
        var picker = new ComboBox { ItemsSource = choices, DisplayMemberPath = "Title", MinWidth = 180 };
        updatingPickers = true;
        picker.SelectedItem = choices.FirstOrDefault(c => c.Value == newLimit) ?? choices.LastOrDefault();
        updatingPickers = false;
        picker.SelectionChanged += (_, _) =>
        {
            if (!updatingPickers && picker.SelectedItem is Choice<long?> choice) newLimit = choice.Value;
        };
        row.Children.Add(picker);
        limits.Children.Add(row);
        limits.Children.Add(new TextBlock
        {
            Text = $"Остальное место на «{host.Name}» остаётся для обычных файлов, пока сейф до него не дорос.",
            Style = Res("Caption"), Margin = new Thickness(0, 4, 0, 0),
        });
        Add(StatusPanel, limits);
        Add(StatusPanel, Detach(createFields, new Thickness(0)));

        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        if (replacing != null)
        {
            var cancel = new Button { Content = "Отмена", Margin = new Thickness(0, 0, 8, 0), IsCancel = true };
            cancel.Click += (_, _) =>
            {
                creatingAnother = false;
                createFields.Clear();
                statusKey = null;
                Update();
            };
            buttons.Children.Add(cancel);
        }
        createButton.IsEnabled = createFields.IsAcceptable;
        buttons.Children.Add(Detach(createButton, new Thickness(0)));
        Add(StatusPanel, buttons);
    }

    void Create_Click(object sender, RoutedEventArgs e)
    {
        if (app.Destination is not { } host || !createFields.IsAcceptable) return;
        app.Safe.Create(createFields.Password, newLimit ?? host.TotalBytes, app);
        createFields.Clear();
        creatingAnother = false;
        statusKey = null;
        Update();
    }

    // MARK: Открытые данные

    void UpdateExposure()
    {
        ExposurePanel.Children.Clear();
        var host = app.Destination;
        if (host == null) return;
        var safe = app.Safe;
        var plain = app.PlainRecords;
        var rowPadding = new Thickness(14, 10, 14, 10);
        if (safe.MigrationProgress is { } migration)
        {
            var block = new StackPanel { Margin = rowPadding };
            var line = new Grid();
            line.ColumnDefinitions.Add(new ColumnDefinition());
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.Children.Add(new TextBlock
            {
                Text = $"{migration.Index} из {migration.Count}: «{migration.Item}» — {migration.Phase.ToLowerInvariant()}",
                Style = Res("Body"), TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis,
            });
            var bytes = new TextBlock { Text = $"{Format.Bytes(migration.BytesDone)} из {Format.Bytes(migration.BytesTotal)}", Style = Res("Caption"), Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(bytes, 1);
            line.Children.Add(bytes);
            block.Children.Add(line);
            block.Children.Add(new ProgressBar { Maximum = 1, Value = migration.Fraction, Margin = new Thickness(0, 8, 0, 0) });
            var stop = new Button { Content = "Остановить", Margin = new Thickness(0, 8, 0, 0) };
            stop.Click += (_, _) => safe.CancelMigration();
            block.Children.Add(stop);
            ExposurePanel.Children.Add(block);
        }
        else if (plain.Count == 0)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = rowPadding };
            row.Children.Add(new TextBlock { Text = Glyphs.CheckSeal, FontFamily = Glyphs.Font, FontSize = 14, Foreground = Theme.Ink, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
            row.Children.Add(Text("Перенесённого, лежащего на диске открыто, нет."));
            ExposurePanel.Children.Add(row);
        }
        else
        {
            long total = plain.Sum(r => r.Bytes);
            ExposurePanel.Children.Add(new NoticeView
            {
                Kind = NoticeKind.Warning, Margin = new Thickness(12),
                Text = $"На диске «{host.Name}» открыто лежат перенесённые данные: {plain.Count} {Plural.Ru(plain.Count, "объект", "объекта", "объектов")}, {Format.Bytes(total)}. Кто получит диск в руки, прочтёт их без пароля.",
            });
            foreach (var record in plain)
            {
                var texts = new StackPanel { Margin = new Thickness(4, 0, 0, 0) };
                texts.Children.Add(new TextBlock { Text = record.OriginalName, Style = Res("Body"), TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis });
                texts.Children.Add(new TextBlock
                {
                    Text = $"{Format.Bytes(record.Bytes)} · {Ui.RelativeToHome(record.OriginalPath, app.Rules.Home)}",
                    Style = Res("Caption"), TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis,
                });
                var box = new CheckBox { Content = texts, IsChecked = !excluded.Contains(record.Id), Margin = rowPadding };
                var id = record.Id;
                box.Checked += (_, _) => { excluded.Remove(id); UpdateExposure(); };
                box.Unchecked += (_, _) => { excluded.Add(id); UpdateExposure(); };
                ExposurePanel.Children.Add(box);
                ExposurePanel.Children.Add(new Separator { Style = Res("RowDivider") });
            }
            var chosen = plain.Where(r => !excluded.Contains(r.Id)).ToList();
            var bottom = new StackPanel { Margin = rowPadding };
            bottom.Children.Add(Text("Если какой-то программой вы пользуетесь прямо с диска (например, моделями LM Studio), после переноса в сейф укажите ей новую папку и держите сейф открытым, пока она нужна. Такие пункты можно снять.", "Caption"));
            if (app.SafeVolume == null)
                bottom.Children.Add(new TextBlock { Text = app.TargetProblem ?? "Откройте сейф.", Style = Res("Callout"), Margin = new Thickness(0, 10, 0, 0) });
            else
            {
                var encrypt = GlyphButton(Glyphs.Lock, $"Перенести в сейф и удалить открытые копии ({chosen.Count})", prominent: true);
                encrypt.Margin = new Thickness(0, 10, 0, 0);
                encrypt.IsEnabled = chosen.Count > 0 && !app.IsBusy;
                encrypt.Click += (_, _) => safe.Encrypt(chosen, app);
                bottom.Children.Add(encrypt);
            }
            ExposurePanel.Children.Add(bottom);
        }
        DiskEncryptionNote(host, rowPadding);
    }

    /// <summary>Зашифрован ли сам диск: сейф прячет только то, что в нём, а удалённые открытые копии на SSD и флешках
    /// физически живут, пока контроллер их не перезапишет.</summary>
    void DiskEncryptionNote(VolumeInfo host, Thickness padding)
    {
        if (app.Safe.Current is not { } state || state.VolumeId != host.Id) return;
        ExposurePanel.Children.Add(new Separator { Style = Res("RowDivider") });
        if (state.HostEncrypted)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = padding };
            row.Children.Add(new TextBlock { Text = Glyphs.CheckSeal, FontFamily = Glyphs.Font, FontSize = 14, Foreground = Theme.Ink, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
            row.Children.Add(Text($"Сам диск «{host.Name}» зашифрован целиком (BitLocker To Go)."));
            ExposurePanel.Children.Add(row);
            return;
        }
        string text = host.FsType is "ntfs" or "exfat" or "fat32" or "fat"
            ? $"Сам диск «{host.Name}» не зашифрован. Его можно зашифровать целиком, не стирая: правый щелчок по диску в Проводнике → «Включить BitLocker» (BitLocker To Go есть в Windows Pro и старше). Тогда защищено будет и то, что лежит вне сейфа."
            : $"Сам диск «{host.Name}» ({host.FsDisplayName}) BitLocker To Go зашифровать не может. Удалённые с SSD и флешек файлы физически могут оставаться в памяти, пока контроллер их не перезапишет. Для защиты всего диска, как в VeraCrypt при шифровании раздела: перенесите данные, отформатируйте диск в NTFS или exFAT, включите на нём BitLocker и верните их.";
        var note = Text(text, "Caption");
        note.Margin = padding;
        ExposurePanel.Children.Add(note);
    }

    // MARK: Пароль, заголовок, место

    void UpdateKeySection(bool encrypted)
    {
        var safe = app.Safe;
        KeySection.Visibility = encrypted ? Visibility.Visible : Visibility.Collapsed;
        bool closed = !safe.IsOpen;
        ChangePasswordButton.IsEnabled = BackupHeaderButton.IsEnabled = RestoreHeaderButton.IsEnabled = GrowButton.IsEnabled = CompactButton.IsEnabled = closed;
        LimitRow.Detail = $"Сейчас {(safe.Current?.SizeLimit is { } limit ? Format.Bytes(limit) : "неизвестно")}. Увеличивается без потери содержимого.";
        KeySection.Footer = safe.IsOpen
            ? "Смена пароля, копия и восстановление заголовка, увеличение и возврат места — на закрытом сейфе."
            : "В заголовке лежит ключ данных, зашифрованный паролем: испортится он — пропадёт всё, даже при верном пароле. Храните копию заголовка отдельно от диска. Место, освобождённое внутри сейфа, идёт под новые данные, но сам образ на диске не уменьшается. Вернуть его Windows может, только если переписать сейф заново: Offload сделает это со сверкой, но нужны время и свободное место рядом под всё содержимое.";
    }

    void ChangePassword_Click(object sender, RoutedEventArgs e) => new SafeChangePasswordSheet(app).ShowDialog();

    void Compact_Click(object sender, RoutedEventArgs e) => new SafeCompactSheet(app).ShowDialog();

    void RestoreHeader_Click(object sender, RoutedEventArgs e) => new SafeRestoreHeaderSheet(app).ShowDialog();

    void Grow_Click(object sender, RoutedEventArgs e) => new GrowSafeSheet(app).ShowDialog();

    void BackupHeader_Click(object sender, RoutedEventArgs e)
    {
        if (app.Safe.Current is not { IsEncrypted: true, Mount: null }) return;
        var dialog = new OpenFolderDialog
        {
            Title = "Куда положить копию заголовка сейфа. Лучше не на тот же диск: если он откажет, пропадут и сейф, и копия.",
        };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        app.Safe.BackupHeader(dialog.FolderName, app);
    }
}
