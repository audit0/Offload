using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Threading;
using Offload.Core;

namespace Offload;

/// <summary>Разбор компьютера: «Начать» → вопросы → ответы. Никаких флажков и папок: на каждый вопрос —
/// «да» или «не сейчас», и сделанное видно сразу у вопроса.</summary>
public partial class CleanupView : UserControl
{
    readonly AppModel app;
    CleanupModel Model => app.Cleanup;
    readonly Dictionary<QuestionKind, CleanupQuestionCard> cards = [];
    readonly Dictionary<CleanupModule, (IconTile Tile, TextBlock Value)> tiles = [];
    bool pending;

    // Что сейчас показано в списках начальной страницы: пересобираются, только когда изменились.
    List<HabitModel.Prediction>? shownHabits;
    int shownRemembered = -1;
    string? shownForgetProblem;
    List<string>? shownIgnored;
    string? shownIgnoreProblem;
    bool? shownPro;

    /// <summary>Где разбор ищет — чтобы было видно, что личное в AppData он не трогает.</summary>
    static readonly (string Glyph, string Title)[] PlaceList =
    [
        (Glyphs.Download, "Загрузки"), (Glyphs.Computer, "Рабочий стол"), (Glyphs.Document, "Документы"),
        (CleanupGlyphs.Video, "Видео"), (CleanupGlyphs.Music, "Музыка"), (CleanupGlyphs.Pictures, "Изображения"),
        (Glyphs.Folder, "Свои папки в домашней"), (CleanupGlyphs.Tools, "Кеши программ"), (Glyphs.Package, "Docker"),
    ];

    /// <summary>О чём спрошу и что будет по «да».</summary>
    static readonly (string Glyph, Tone Tone, string Title, string Detail, string Outcome)[] Kinds =
    [
        (Glyphs.Trash, Tone.Brand, "Мусор", "Кеши и скачанные пакеты — программы создадут их заново.", "в Корзину"),
        (Glyphs.Package, Tone.Info, "Docker", "Кеш сборки и образы без имени. Образы с именем и тома с данными не трогаю.", "удалит Docker"),
        (Glyphs.Copy, Tone.Caution, "Лишние копии", "Одинаковые файлы — одна копия каждого остаётся всегда.", "в Корзину"),
        (Glyphs.Download, Tone.Info, "Установщики", ".exe, .msi и .msix старше недели — только отдельным «да».", "в Корзину"),
        (Glyphs.Shield, Tone.Good, "Крупное и старое", "Не менялось больше трёх месяцев — со сверкой каждого файла.", "в сейф"),
        (Glyphs.Backup, Tone.Brand, "Проекты без бэкапа", "Папки с git — ничего не удаляется.", "в бэкап"),
    ];

    public CleanupView(AppModel app)
    {
        this.app = app;
        InitializeComponent();
        DataContext = app;
        BuildPlaces();
        BuildLegend();
        BuildTiles();
        Model.PropertyChanged += Changed;
        app.PropertyChanged += Changed;
        app.Safe.PropertyChanged += Changed;
        app.Pro.PropertyChanged += Changed;
        Loaded += (_, _) =>
        {
            Model.LoadHabits(app.Rules.Home);
            Update();
        };
        Update();
    }

    void Changed(object? sender, PropertyChangedEventArgs e)
    {
        // Модель сообщает о многом сразу — перерисовываем один раз, когда она закончит.
        if (pending) return;
        pending = true;
        Dispatcher.BeginInvoke(() =>
        {
            pending = false;
            Update();
        }, DispatcherPriority.Normal);
    }

    static Visibility Show(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

    Style Res(string key) => (Style)FindResource(key);

    void Update()
    {
        StoreNotice.Visibility = Show(Model.StoreProblem != null);
        if (Model.StoreProblem is { } problem) StoreNotice.Message = new NoticeMessage(NoticeKind.Warning, $"Решения не запоминаются: {problem}");
        var stage = Model.Stage;
        StartPanel.Visibility = Show(stage == CleanupModel.StageKind.Idle);
        ScanPanel.Visibility = Show(stage == CleanupModel.StageKind.Scanning);
        ReviewPanel.Visibility = Show(stage == CleanupModel.StageKind.Review);
        switch (stage)
        {
            case CleanupModel.StageKind.Idle: UpdateStart(); break;
            case CleanupModel.StageKind.Scanning: UpdateScan(); break;
            default: UpdateReview(); break;
        }
    }

    // MARK: Начало

    void BuildPlaces()
    {
        foreach (var (glyph, title) in PlaceList)
        {
            var content = new StackPanel { Orientation = Orientation.Horizontal };
            content.Children.Add(new TextBlock { Text = glyph, Style = Res("Icon"), FontSize = 12, Foreground = Theme.Ink, Margin = new Thickness(0, 0, 6, 0) });
            content.Children.Add(new TextBlock { Text = title, Style = Res("Body"), FontSize = 12.5, TextWrapping = TextWrapping.NoWrap });
            Places.Children.Add(new Border { Style = (Style)Resources["PlaceChip"], Child = content });
        }
    }

    void BuildLegend()
    {
        for (int i = 0; i < Kinds.Length; i++)
        {
            var kind = Kinds[i];
            var text = new StackPanel();
            text.Children.Add(new TextBlock { Text = kind.Title, Style = Res("Body"), FontWeight = FontWeights.Medium });
            text.Children.Add(new TextBlock { Text = kind.Detail, Style = Res("Callout"), Margin = new Thickness(0, 2, 0, 0) });
            Legend.Children.Add(Row(new IconTile { Glyph = kind.Glyph, Tone = kind.Tone }, text, new StatusPill { Text = kind.Outcome, Tone = Tone.Neutral }));
            if (i < Kinds.Length - 1) Legend.Children.Add(Divider());
        }
    }

    /// <summary>Строка карточки-списка: значок, текст, справа — управление.</summary>
    static Grid Row(UIElement icon, UIElement middle, UIElement? right)
    {
        var grid = new Grid { Margin = new Thickness(14, 10, 14, 10) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (icon is FrameworkElement element) element.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(icon);
        if (middle is FrameworkElement body)
        {
            body.Margin = new Thickness(12, 0, 12, 0);
            body.VerticalAlignment = VerticalAlignment.Center;
        }
        Grid.SetColumn(middle, 1);
        grid.Children.Add(middle);
        if (right is FrameworkElement side)
        {
            side.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(side, 2);
            grid.Children.Add(side);
        }
        return grid;
    }

    Separator Divider() => new() { Style = Res("RowDivider"), Margin = new Thickness(54, 0, 0, 0) };

    void UpdateStart()
    {
        if (Model.LastRun is { } run)
        {
            LastRunSection.Visibility = Visibility.Visible;
            var date = run.Date.ToLocalTime().ToString("d MMM yyyy 'г.,' HH:mm", CultureInfo.GetCultureInfo("ru-RU"));
            LastRunSection.Header = $"Прошлый разбор — {date}";
            LastTrashed.Text = Format.Bytes(run.TrashedBytes);
            LastMoved.Text = Format.Bytes(run.MovedBytes);
            LastAdded.Text = run.AddedToBackup.ToString(CultureInfo.InvariantCulture);
        }
        else LastRunSection.Visibility = Visibility.Collapsed;

        LearnedSection.Visibility = Show(Model.StoreProblem == null);
        if (!ReferenceEquals(shownHabits, Model.Habits) || shownRemembered != Model.Remembered || shownForgetProblem != Model.ForgetProblem
            || shownPro != app.Pro.Allows(ProFeature.Habits)) BuildLearned();

        IgnoredSection.Visibility = Show(Model.Ignored.Count > 0);
        IgnoredSection.Header = $"Не предлагаю — {Model.Ignored.Count}";
        if (!ReferenceEquals(shownIgnored, Model.Ignored) || shownIgnoreProblem != Model.IgnoreProblem) BuildIgnored();
    }

    /// <summary>Чему OffLoadAI научился на решениях человека — и кнопка, чтобы всё это забыть.</summary>
    void BuildLearned()
    {
        var habits = Model.Habits;
        int remembered = Model.Remembered;
        shownHabits = habits;
        shownRemembered = remembered;
        shownForgetProblem = Model.ForgetProblem;
        shownPro = app.Pro.Allows(ProFeature.Habits);
        Learned.Children.Clear();
        if (shownPro == false)
        {
            var more = new Button { Content = "Подробнее…" };
            more.Click += (_, _) => app.Pro.Offer(ProFeature.Habits);
            Learned.Children.Add(Row(new IconTile { Glyph = Glyphs.Lightbulb, Tone = Tone.Neutral }, new TextBlock
            {
                Text = "Привычки действуют в OffLoadAI Pro. Ваши ответы запоминаются и сейчас — с Pro похожее сразу начнёт попадать в нужный вопрос.",
                Style = Res("Callout"),
            }, more));
            Learned.Children.Add(Divider());
        }
        if (habits.Count == 0)
        {
            var row = Row(new IconTile { Glyph = Glyphs.Sparkle, Tone = Tone.Neutral }, new TextBlock
            {
                Text = "Пока привычек нет. Привычка появляется, когда вы хотя бы трижды одинаково решаете похожее — например, убираете в сейф старые съёмки из «Видео». Тогда похожие папки сами попадут в вопрос о сейфе.",
                Style = Res("Callout"),
            }, null);
            ((FrameworkElement)row.Children[0]).VerticalAlignment = VerticalAlignment.Top;
            Learned.Children.Add(row);
        }
        for (int i = 0; i < habits.Count; i++)
        {
            var habit = habits[i];
            var text = new StackPanel();
            var scope = habit.Scope.Length > 0 ? char.ToUpper(habit.Scope[0]) + habit.Scope[1..] : habit.Scope;
            text.Children.Add(new TextBlock { Text = scope, Style = Res("Body"), FontWeight = FontWeights.Medium });
            text.Children.Add(new TextBlock { Text = $"обычно {HabitModel.Prediction.Verb(habit.Action)}", Style = Res("Callout"), Margin = new Thickness(0, 2, 0, 0) });
            var count = new TextBlock
            {
                Text = $"{habit.Agreeing} из {habit.Total}", Style = Res("Callout"), TextWrapping = TextWrapping.NoWrap,
                ToolTip = "Столько похожих решений за это действие из всех похожих",
            };
            Typography.SetNumeralAlignment(count, FontNumeralAlignment.Tabular);
            Learned.Children.Add(Row(new IconTile { Glyph = habit.Action.Glyph(), Tone = habit.Action.Tone() }, text, count));
            if (i < habits.Count - 1 || remembered > 0) Learned.Children.Add(Divider());
        }
        if (remembered > 0)
        {
            if (habits.Count == 0) Learned.Children.Add(Divider());
            var grid = new Grid { Margin = new Thickness(14, 10, 14, 10) };
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.Children.Add(new TextBlock
            {
                Text = $"Помню ваши ответы для {remembered} {Plural.Ru(remembered, "объекта", "объектов", "объектов")}",
                Style = Res("Callout"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0),
            });
            var forget = new Button { Content = "Забыть мои решения…" };
            forget.Click += Forget_Click;
            Grid.SetColumn(forget, 1);
            grid.Children.Add(forget);
            Learned.Children.Add(grid);
        }
        if (Model.ForgetProblem is { } problem)
            Learned.Children.Add(new NoticeView { Message = new NoticeMessage(NoticeKind.Warning, $"Забыть не получилось: {problem}"), Margin = new Thickness(18) });
    }

    /// <summary>То, что человек просил больше не предлагать, — с возможностью вернуть.</summary>
    void BuildIgnored()
    {
        var ignored = Model.Ignored;
        shownIgnored = ignored;
        shownIgnoreProblem = Model.IgnoreProblem;
        IgnoredList.Children.Clear();
        for (int i = 0; i < ignored.Count; i++)
        {
            var path = ignored[i];
            var text = new TextBlock
            {
                Text = Ui.RelativeToHome(path, app.Rules.Home), Style = Res("Body"), TextWrapping = TextWrapping.NoWrap,
                TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = path,
            };
            var again = new Button { Content = "Снова предлагать" };
            again.Click += (_, _) => Model.Unignore(path);
            IgnoredList.Children.Add(Row(new IconTile { Glyph = CleanupGlyphs.Hide, Tone = Tone.Neutral }, text, again));
            if (i < ignored.Count - 1) IgnoredList.Children.Add(Divider());
        }
        if (Model.IgnoreProblem is { } problem)
            IgnoredList.Children.Add(new NoticeView { Message = new NoticeMessage(NoticeKind.Warning, $"Не получилось: {problem}"), Margin = new Thickness(18) });
    }

    void StartButton_IsVisibleChanged(object sender, DependencyPropertyChangedEventArgs e) =>
        // Enter начинает разбор, только пока видна эта кнопка: страницы других разделов живут в том же окне.
        StartButton.IsDefault = StartButton.IsVisible;

    void Start_Click(object sender, RoutedEventArgs e) => Model.Start(app);

    void Forget_Click(object sender, RoutedEventArgs e)
    {
        if (!Dialogs.Confirm(Window.GetWindow(this), "Забыть ваши решения?",
                "OffLoadAI забудет ваши ответы по каждой папке и файлу и привычки, выученные на них. Итоги прошлых разборов и то, что вы просили не предлагать, останутся.",
                "Забыть", "Отмена", Tone.Danger, Glyphs.Warning, destructive: true)) return;
        Model.ForgetDecisions(app.Rules.Home);
    }

    // MARK: Поиск

    void BuildTiles()
    {
        foreach (var module in new[] { CleanupModule.Junk, CleanupModule.Safe, CleanupModule.Duplicates, CleanupModule.Installers, CleanupModule.Projects })
        {
            var tile = new IconTile { Glyph = module.Glyph(), Tone = Tone.Neutral, Size = 34, HorizontalAlignment = HorizontalAlignment.Left };
            var value = new TextBlock { Style = Res("Display"), FontSize = 24, Margin = new Thickness(0, 10, 0, 0) };
            Typography.SetNumeralAlignment(value, FontNumeralAlignment.Tabular);
            var body = new StackPanel();
            body.Children.Add(tile);
            body.Children.Add(value);
            body.Children.Add(new TextBlock { Text = module.Title(), Style = Res("Callout"), Margin = new Thickness(0, 2, 0, 0) });
            var card = new Card { Content = body, Margin = new Thickness(6, 0, 6, 0) };
            (module is CleanupModule.Junk or CleanupModule.Safe ? ScanTilesTop : ScanTilesBottom).Children.Add(card);
            tiles[module] = (tile, value);
        }
    }

    void UpdateScan()
    {
        var progress = Model.Scan;
        ScanTitle.Text = progress.Duplicates ? "Ищу одинаковые файлы" : progress.Total == 0 ? "Собираю, что посмотреть…" : "Смотрю, что занимает место";
        ScanCurrent.Text = progress.Current.Length == 0 ? " " : progress.Current;
        ScanCurrent.ToolTip = progress.Current.Length == 0 ? null : progress.Current;
        if (progress.Duplicates) ScanCount.Text = $"{progress.Files} {Plural.Ru(progress.Files, "файл", "файла", "файлов")}";
        else if (progress.Total > 0) ScanCount.Text = $"{progress.Done} из {progress.Total}";
        ScanCount.Visibility = Show(progress.Duplicates || progress.Total > 0);
        // Сколько файлов впереди у поиска одинаковых, заранее неизвестно — полоса без конца.
        ScanBar.IsIndeterminate = progress.Duplicates;
        ScanBar.Value = progress.Fraction;
        foreach (var (module, (tile, value)) in tiles)
        {
            long found = progress.FoundBytes.GetValueOrDefault(module);
            value.Text = module switch
            {
                CleanupModule.Duplicates => progress.Duplicates ? "ищу…" : "после замера",
                CleanupModule.Projects => found.ToString(CultureInfo.InvariantCulture),
                _ => Format.Bytes(found),
            };
            bool active = found > 0 || (module == CleanupModule.Duplicates && progress.Duplicates);
            tile.Tone = active ? module.Tone() : Tone.Neutral;
        }
    }

    void CancelScan_Click(object sender, RoutedEventArgs e) => Model.Cancel();

    // MARK: Вопросы

    void UpdateReview()
    {
        var questions = Model.Questions;
        bool none = questions.Count == 0;
        NothingCard.Visibility = Show(none);
        SummaryCard.Visibility = Show(!none);
        Questions.Visibility = Show(!none);
        UpdateDockerIdle();
        if (none)
        {
            IgnoreNotice.Visibility = TrashCard.Visibility = ErasedNotice.Visibility = TrashProblemsNotice.Visibility = FinalButtons.Visibility = Visibility.Collapsed;
            SyncCards(questions);
            return;
        }
        UpdateSummary();
        SyncCards(questions);
        IgnoreNotice.Visibility = Show(Model.IgnoreProblem != null);
        if (Model.IgnoreProblem is { } problem) IgnoreNotice.Message = new NoticeMessage(NoticeKind.Warning, $"Не получилось запомнить «не предлагать»: {problem}");
        UpdateTrash();
        FinalButtons.Visibility = Show(Model.IsSettled);
        FinalButtons.IsEnabled = !Model.IsBusy;
    }

    /// <summary>Карточки вопросов живут, пока жив вопрос: так у них сохраняется раскрытый список «Что именно».</summary>
    void SyncCards(List<CleanupQuestion> questions)
    {
        var kinds = questions.Select(q => q.Kind).ToHashSet();
        foreach (var gone in cards.Keys.Where(k => !kinds.Contains(k)).ToList()) cards.Remove(gone);
        var ordered = new List<CleanupQuestionCard>();
        foreach (var question in questions)
        {
            if (!cards.TryGetValue(question.Kind, out var card))
            {
                card = new CleanupQuestionCard(app, question, Yes) { Margin = new Thickness(0, 0, 0, 28) };
                cards[question.Kind] = card;
            }
            card.Update(question, Model.AnswerFor(question.Kind), Model.Hints.GetValueOrDefault(question.Kind));
            ordered.Add(card);
        }
        bool same = Questions.Children.Count == ordered.Count && ordered.Select((c, i) => ReferenceEquals(Questions.Children[i], c)).All(x => x);
        if (same) return;
        Questions.Children.Clear();
        foreach (var card in ordered) Questions.Children.Add(card);
    }

    void UpdateSummary()
    {
        var open = Model.Asking;
        // Вопросы из Pro без ключа «Разрешить всё» не отвечает — и в его сумму они не входят.
        var together = open.Where(q => q.AnsweredTogether && !Model.IsLocked(q.Kind, app)).ToList();
        long togetherBytes = together.Sum(q => q.Bytes);
        long freed = Math.Max(0, Model.Freed ?? 0);
        if (open.Count > 0)
        {
            SummaryCaption.Text = "Можно освободить";
            SummaryValue.Text = Format.Bytes(Model.PendingBytes);
            SummaryValue.FontSize = 44;
            SummaryLine.Text = $"{open.Count} {Plural.Ru(open.Count, "вопрос", "вопроса", "вопросов")} — на каждый ответьте «да» или «не сейчас». Удаляемое сначала уходит в Корзину.";
        }
        else
        {
            SummaryCaption.Text = Model.IsSettled ? "Готово" : "Делаю…";
            SummaryValue.Text = freed >= 100_000_000 ? $"Освободилось {Format.Bytes(freed)}" : "Ответили на всё";
            SummaryValue.FontSize = 34;
            SummaryLine.Text = SettledLine();
        }
        AllowAllButton.Visibility = Show(together.Count > 0);
        AllowAllText.Text = togetherBytes > 0 ? $"Разрешить всё · {Format.Bytes(togetherBytes)}" : "Разрешить всё";
        AllowAllButton.ToolTip = open.Count > together.Count
            ? "Ответить «да» на все вопросы, кроме установщиков (их удаляю только по отдельному ответу) и вопросов из OffLoadAI Pro"
            : "Ответить «да» на все вопросы";
        CancelReviewButton.Visibility = Show(!Model.IsSettled);
        CancelReviewButton.IsEnabled = !Model.IsBusy;
    }

    string SettledLine()
    {
        if (Model.TrashedItems.Count > 0)
            return "Удалённое лежит в Корзине и занимает место, пока её не очистят, — ниже можно удалить это насовсем.";
        if (Model.HasDone && Model.FreeNow is { } now) return $"Свободно на компьютере {Format.Bytes(now)}.";
        return "Ответы запомнены: что вы вернули из Корзины, больше не предложу.";
    }

    /// <summary>Docker стоит, но не запущен: что в нём можно убрать, узнать нельзя — сказать, как это исправить.</summary>
    void UpdateDockerIdle()
    {
        bool shown = Model.DockerIdle is >= 1_000_000_000;
        DockerIdleCard.Visibility = Show(shown);
        if (!shown) return;
        DockerIdleText.Text = $"Его диск занимает {Format.Bytes(Model.DockerIdle!.Value)}. Запустите Docker Desktop и разберите ещё раз — спрошу, что из него можно удалить.";
        LaunchDockerButton.Visibility = Show(DockerDesktop != null);
    }

    static string? DockerDesktop
    {
        get
        {
            var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Docker", "Docker", "Docker Desktop.exe");
            return File.Exists(path) ? path : null;
        }
    }

    void LaunchDocker_Click(object sender, RoutedEventArgs e)
    {
        if (DockerDesktop is { } path) Ui.Open(path);
    }

    /// <summary>Удалённое этим разбором лежит в Корзине: удалить насовсем, чтобы место освободилось сейчас?</summary>
    void UpdateTrash()
    {
        var items = Model.TrashedItems;
        long inTrash = items.Sum(i => i.Bytes);
        TrashCard.Visibility = Show(items.Count > 0);
        TrashText.Text = $"В Корзине {Format.Bytes(inTrash)} из этого разбора: место на компьютере освободится, только когда их удалят оттуда. Остальное в Корзине не трогаю. Вернуть удалённое насовсем будет нельзя.";
        TrashBytes.Text = Format.Bytes(inTrash);
        FinishingRow.Visibility = Show(Model.Finishing != null);
        FinishingText.Text = Model.Finishing ?? "";
        EraseButton.IsEnabled = !Model.IsBusy;
        ErasedNotice.Visibility = Show(Model.Erased > 0);
        if (Model.Erased > 0)
            ErasedNotice.Message = new NoticeMessage(NoticeKind.Success, $"Удалено из Корзины насовсем: {Model.Erased}, {Format.Bytes(Model.ErasedBytes)}.");
        TrashProblemsNotice.Visibility = Show(Model.TrashProblems.Count > 0);
        if (Model.TrashProblems.Count > 0)
            TrashProblemsNotice.Message = new NoticeMessage(NoticeKind.Warning, "Не всё получилось:", Model.TrashProblems);
    }

    /// <summary>«Да». Для сейфа, если он закрыт, сначала пароль — и выполнение начнётся, как только сейф откроется.</summary>
    void Yes(QuestionKind kind)
    {
        if (Model.NeedsSafe(kind, app)) AskSafe();
        else Model.Respond(kind, true, app);
    }

    void AskSafe()
    {
        var safeKind = QuestionKind.Of(CleanupModule.Safe);
        new CleanupSafeSheet(app, Model.Question(safeKind)?.Bytes ?? 0, () => Model.Respond(safeKind, true, app)) { Owner = Window.GetWindow(this) }.ShowDialog();
    }

    /// <summary>«Разрешить всё». Если сейф на подключённом диске закрыт — спросить пароль для вопроса о сейфе;
    /// сейфа нет или диск не подключён — вопрос о сейфе просто остаётся ждать, с объяснением.</summary>
    void AllowAll_Click(object sender, RoutedEventArgs e)
    {
        if (Model.RespondAll(app) && app.Destination != null && app.Safe.Exists) AskSafe();
    }

    void Cancel_Click(object sender, RoutedEventArgs e) => Leave(false);

    void Done_Click(object sender, RoutedEventArgs e) => Leave(false);

    void Again_Click(object sender, RoutedEventArgs e) => Leave(true);

    /// <summary>«Готово», «Отмена», «Разобрать ещё раз». Список отправленного в Корзину живёт только в этом
    /// разборе, поэтому, пока он не пуст, сначала спрашиваем — иначе он пропадал бы молча.</summary>
    void Leave(bool thenScan)
    {
        int trashed = Model.TrashedItems.Count;
        if (trashed > 0)
        {
            var what = trashed % 10 == 1 && trashed % 100 != 11
                ? $"{trashed} объект, отправленный"
                : $"{trashed} {Plural.Ru(trashed, "объект", "объекта", "объектов")}, отправленных";
            if (!Dialogs.Confirm(Window.GetWindow(this), "Закончить разбор?",
                    $"В Корзине лежит {what} этим разбором. Кнопки «Вернуть» у вопросов после этого не будет: вернуть их можно будет только вручную из Корзины.",
                    "Закончить", "Остаться", Tone.Neutral, Glyphs.Trash)) return;
        }
        Model.Reset(app);
        if (thenScan) Model.Start(app);
    }

    void Erase_Click(object sender, RoutedEventArgs e)
    {
        long inTrash = Model.TrashedItems.Sum(i => i.Bytes);
        if (!Dialogs.Confirm(Window.GetWindow(this), $"Удалить насовсем {Format.Bytes(inTrash)}?",
                "Из Корзины удалится только то, что туда отправил этот разбор. Вернуть это будет нельзя.",
                "Удалить насовсем", "Отмена", Tone.Danger, Glyphs.Trash, destructive: true)) return;
        Model.EraseTrashed(app);
    }
}
