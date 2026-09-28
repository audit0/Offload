using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Microsoft.Win32;
using Offload.Core;

namespace Offload;

/// <summary>Раздел «Помощник»: выбрать папку, спросить — и увидеть, что в ней важно, что менее важно, а что мусор.
/// У каждого совета — кнопка, которая делает то же, что и без помощника: перенос со сверкой или Корзина с возвратом.</summary>
public sealed class AssistantView : UserControl
{
    readonly AppModel app;
    readonly StackPanel root = new();
    readonly TextBox question = new() { Tag = "Вопрос помощнику (необязательно): например, «что из этого можно удалить?»", Margin = new Thickness(0, 12, 0, 0) };
    bool pending;

    AssistantModel Model => app.Assistant;

    public AssistantView(AppModel app)
    {
        this.app = app;
        Content = Pages.Scroll(root);
        Model.PropertyChanged += Changed;
        Loaded += (_, _) =>
        {
            Update();
            // Снимки для README показывают ответ: в демонстрации он вымышленный и без сети.
            if (Demo.IsOn && Environment.GetEnvironmentVariable("OFFLOAD_SNAPSHOT_DIR") != null && Model.Answer == null && !Model.IsBusy)
                Model.Run(Path.Combine(app.Rules.Home, "Downloads"), null, app);
        };
        Update();
    }

    void Changed(object? sender, PropertyChangedEventArgs e)
    {
        if (pending) return;
        pending = true;
        Dispatcher.BeginInvoke(() => { pending = false; Update(); }, DispatcherPriority.Normal);
    }

    static Style Res(string key) => (Style)Application.Current.FindResource(key);

    void Update()
    {
        root.Children.Clear();
        root.Children.Add(new TextBlock { Text = "Помощник", Style = Res("Title") });
        root.Children.Add(new TextBlock
        {
            Text = "Смотрит на папку и говорит, что в ней важно, что менее важно, а что мусор. Сам ничего не удаляет и не переносит — только советует, а решаете вы.",
            Style = Res("Callout"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, Theme.SectionSpacing),
        });
        // Сначала — где думает помощник: от этого зависит, куда уйдут сведения, и согласие даётся на него.
        var problem = Demo.IsOn ? null : Model.Provider.Problem();
        root.Children.Add(ProviderCard(problem));
        if (!Model.Consent) { root.Children.Add(ConsentCard()); return; }
        if (problem != null) return;
        root.Children.Add(AskCard());
        if (Model.Error is { } error)
            root.Children.Add(new NoticeView { Message = new NoticeMessage(NoticeKind.Error, error), Margin = new Thickness(0, 16, 0, 0) });
        if (Model.Answer is { } answer) AddAnswer(answer);
    }

    FrameworkElement ConsentCard()
    {
        var body = new StackPanel();
        body.Children.Add(new TextBlock { Text = "Что уходит помощнику", Style = Res("Headline") });
        body.Children.Add(new TextBlock
        {
            Text = "Имена и пути файлов и папок от домашней папки, их размеры и даты, пометки правил OffLoadAI и несколько имён внутри папок. " +
                   "Содержимое файлов — нет: начало небольших текстовых файлов уходит, только если вы сами это включите, и никогда — " +
                   "таблицы (.csv), файлы с ключами и те, где видны пароль, токен, номер карты или фраза восстановления. " +
                   "Файлы, которые лежат только в облаке, не скачиваются. Фото, видео и документы никуда не уходят.",
            Style = Res("Body"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0),
        });
        body.Children.Add(new TextBlock
        {
            Text = "Куда: " + AssistantModel.Destination(Model.ProviderKind),
            Style = Res("Body"), FontWeight = FontWeights.Medium, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0),
        });
        body.Children.Add(new TextBlock
        {
            Text = "Остальной OffLoadAI работает без сети — кроме сообщений о новых версиях, если вы их включили. Согласие — отдельно для каждого варианта; отозвать его можно в любой момент.",
            Style = Res("Callout"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0),
        });
        var agree = new Button { Content = "Согласен — включить «" + AssistantModel.Title(Model.ProviderKind) + "»", Style = Res("ProminentButton"), Margin = new Thickness(0, 16, 0, 0) };
        agree.Click += (_, _) => { Model.SetConsent(true); Update(); };
        body.Children.Add(agree);
        return new Card { Content = body };
    }

    /// <summary>Где думает помощник, и что для этого нужно.</summary>
    FrameworkElement ProviderCard(string? problem)
    {
        var body = new StackPanel();
        body.Children.Add(new TextBlock { Text = "Где думает помощник", Style = Res("Headline") });
        var kinds = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
        foreach (var kind in Enum.GetValues<AssistantModel.Kind>())
        {
            var button = new Button
            {
                Content = AssistantModel.Title(kind), Margin = new Thickness(0, 0, 8, 8), IsEnabled = !Model.IsBusy,
                Style = kind == Model.ProviderKind ? Res("ProminentButton") : Res("PillButton"),
            };
            button.Click += (_, _) => Model.ProviderKind = kind;
            kinds.Children.Add(button);
        }
        body.Children.Add(kinds);
        body.Children.Add(new TextBlock
        {
            Text = Model.ProviderKind switch
            {
                AssistantModel.Kind.ClaudeCode => "Claude Code, установленный на этом компьютере, под вашей учётной записью Claude. Ключ не нужен.",
                AssistantModel.Kind.ApiKey => "Ваш ключ Anthropic API: платите по счёту API за каждый вопрос. Ключ хранится зашифрованным средствами Windows.",
                AssistantModel.Kind.Local => "Модель в Ollama на этом компьютере: сведения о файлах не покидают его. Медленнее и проще, чем Claude.",
                _ => "Сервер OffLoadAI передаёт вопрос Claude и ничего не хранит. Входит в OffLoadAI Pro — ни Claude Code, ни ключа не нужно.",
            },
            Style = Res("Callout"), TextWrapping = TextWrapping.Wrap,
        });

        if (Model.ProviderKind == AssistantModel.Kind.ApiKey)
        {
            if (Model.HasApiKey)
            {
                var remove = new Button { Content = "Убрать ключ", Margin = new Thickness(0, 12, 0, 0) };
                remove.Click += (_, _) => Model.SaveApiKey(null);
                body.Children.Add(new TextBlock { Text = "Ключ сохранён.", Style = Res("Body"), Margin = new Thickness(0, 12, 0, 0) });
                body.Children.Add(remove);
            }
            else
            {
                var entry = new Grid { Margin = new Thickness(0, 12, 0, 0) };
                entry.ColumnDefinitions.Add(new ColumnDefinition());
                entry.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var box = new PasswordBox { Tag = "sk-ant-…" };
                entry.Children.Add(box);
                var save = new Button { Content = "Сохранить ключ", Margin = new Thickness(8, 0, 0, 0) };
                save.Click += (_, _) => { Model.SaveApiKey(box.Password); box.Clear(); };
                Grid.SetColumn(save, 1);
                entry.Children.Add(save);
                body.Children.Add(entry);
            }
        }
        if (Model.ProviderKind == AssistantModel.Kind.Local && Model.Local.Models.Count > 0)
        {
            var picker = new ComboBox { ItemsSource = Model.Local.Models, Width = 280, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 12, 0, 0) };
            picker.SelectedItem = Model.LocalModel is { } chosen && Model.Local.Models.Contains(chosen) ? chosen : null;
            picker.SelectionChanged += (_, _) => { if (picker.SelectedItem is string model) Model.LocalModel = model; };
            body.Children.Add(picker);
        }
        if (problem != null)
        {
            body.Children.Add(new NoticeView { Message = new NoticeMessage(NoticeKind.Warning, problem), Margin = new Thickness(0, 12, 0, 0) });
            var retry = new Button { Content = "Проверить снова", Margin = new Thickness(0, 12, 0, 0) };
            retry.Click += (_, _) => Update();
            body.Children.Add(retry);
        }
        if (Model.Consent && !Demo.IsOn)
        {
            var revoke = new Button
            {
                Content = "Отозвать согласие на «" + AssistantModel.Title(Model.ProviderKind) + "»", Style = Res("LinkButton"),
                HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 12, 0, 0),
                ToolTip = "Сведения о файлах больше не уйдут сюда, пока вы снова не согласитесь",
            };
            revoke.Click += (_, _) => { Model.SetConsent(false); Update(); };
            body.Children.Add(revoke);
        }
        return new Card { Content = body, Margin = new Thickness(0, 0, 0, Theme.SectionSpacing) };
    }

    FrameworkElement AskCard()
    {
        var body = new StackPanel();
        body.Children.Add(new TextBlock { Text = "Какую папку разобрать", Style = Res("Headline") });
        var places = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
        var home = app.Rules.Home;
        foreach (var (title, folder) in new[]
                 {
                     ("Загрузки", Path.Combine(home, "Downloads")), ("Рабочий стол", Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory)),
                     ("Документы", Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments)), ("Видео", Environment.GetFolderPath(Environment.SpecialFolder.MyVideos)),
                     ("Домашняя папка", home),
                 })
        {
            var button = new Button { Content = title, Margin = new Thickness(0, 0, 8, 8), IsEnabled = !Model.IsBusy };
            button.Click += (_, _) => Model.Run(folder, question.Text, app);
            places.Children.Add(button);
        }
        var other = new Button { Content = "Другая папка…", Margin = new Thickness(0, 0, 8, 8), IsEnabled = !Model.IsBusy };
        other.Click += (_, _) =>
        {
            var dialog = new OpenFolderDialog { Title = "Какую папку разобрать с помощником", InitialDirectory = home };
            if (dialog.ShowDialog(Window.GetWindow(this)) == true) Model.Run(dialog.FolderName, question.Text, app);
        };
        places.Children.Add(other);
        body.Children.Add(places);
        if (question.Parent is Panel old) old.Children.Remove(question);
        question.IsEnabled = !Model.IsBusy;
        body.Children.Add(question);

        var previews = new CheckBox
        {
            Content = "Показывать помощнику начало небольших текстовых файлов", IsChecked = Model.SendsPreviews, IsEnabled = !Model.IsBusy,
            Margin = new Thickness(0, 12, 0, 0),
        };
        previews.Click += (_, _) => Model.SendsPreviews = previews.IsChecked == true;
        body.Children.Add(previews);
        body.Children.Add(new TextBlock
        {
            Text = "До 20 строк — так понятнее, что это за файл. Таблицы (.csv), файлы с ключами и те, где видны пароль, токен, " +
                   "номер карты или фраза восстановления, не уходят никогда.",
            Style = Res("Caption"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0),
        });

        if (Model.IsBusy)
        {
            var busy = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 14, 0, 0) };
            busy.Children.Add(new ProgressBar { Style = Res("Spinner") });
            busy.Children.Add(new TextBlock { Text = Model.Status ?? "", Style = Res("Callout"), Margin = new Thickness(10, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center });
            var stop = new Button { Content = "Отменить" };
            stop.Click += (_, _) => Model.Cancel();
            busy.Children.Add(stop);
            body.Children.Add(busy);
        }
        else if (Model.Folder is { } last && Model.Answer != null)
        {
            var again = new Button { Content = "Спросить ещё раз про «" + Paths.Name(last) + "»", Margin = new Thickness(0, 12, 0, 0) };
            again.Click += (_, _) => Model.Run(last, question.Text, app);
            body.Children.Add(again);
        }
        return new Card { Content = body };
    }

    void AddAnswer(AssistantAnswer answer)
    {
        if (answer.Summary.Length > 0)
        {
            var summary = new StackPanel();
            summary.Children.Add(new TextBlock { Text = answer.Summary, Style = Res("Body"), TextWrapping = TextWrapping.Wrap });
            var cost = answer.CostUsd is { } usd ? $" · ${usd:0.00}" : "";
            summary.Children.Add(new TextBlock { Text = $"Ответил: {answer.Provider}{cost}. Помощник может ошибаться — решение за вами.", Style = Res("Caption"), Margin = new Thickness(0, 8, 0, 0) });
            root.Children.Add(new Card { Content = summary, Margin = new Thickness(0, Theme.SectionSpacing, 0, 0) });
        }
        foreach (var (importance, title) in new[] { (Importance.Junk, "Мусор"), (Importance.Minor, "Менее важно"), (Importance.Important, "Важно") })
        {
            var group = answer.Items.Where(a => a.Importance == importance).OrderByDescending(a => Model.Item(a.Id)?.Bytes ?? 0).ToList();
            if (group.Count == 0) continue;
            long bytes = group.Sum(a => Model.Item(a.Id)?.Bytes ?? 0);
            var list = new StackPanel();
            for (int i = 0; i < group.Count; i++)
            {
                list.Children.Add(Row(group[i]));
                if (i < group.Count - 1) list.Children.Add(new Separator { Style = Res("RowDivider"), Margin = new Thickness(54, 0, 0, 0) });
            }
            root.Children.Add(new CardSection { Header = $"{title} — {group.Count}, {Format.Bytes(bytes)}", Content = list, Margin = new Thickness(0, Theme.SectionSpacing, 0, 0) });
        }
    }

    FrameworkElement Row(Advice advice)
    {
        var item = Model.Item(advice.Id);
        var grid = new Grid { Margin = new Thickness(14, 10, 14, 10) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var tone = advice.Importance switch { Importance.Important => Tone.Good, Importance.Junk => Tone.Neutral, _ => Tone.Caution };
        grid.Children.Add(new IconTile { Glyph = item?.IsDirectory == true ? Glyphs.Folder : Glyphs.Document, Tone = tone, VerticalAlignment = VerticalAlignment.Top });

        var text = new StackPanel { Margin = new Thickness(12, 0, 12, 0) };
        text.Children.Add(new TextBlock { Text = item != null ? Paths.Name(item.Path) : advice.Id, Style = Res("Body"), FontWeight = FontWeights.Medium, TextTrimming = TextTrimming.CharacterEllipsis });
        text.Children.Add(new TextBlock { Text = advice.Reason, Style = Res("Callout"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 0) });
        if (advice.Overruled is { } overruled)
            text.Children.Add(new TextBlock { Text = overruled, Style = Res("Caption"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) });
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        var size = new TextBlock { Text = item != null ? Format.Bytes(item.Bytes) : "", Style = Res("Callout"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
        Grid.SetColumn(size, 2);
        grid.Children.Add(size);

        FrameworkElement action;
        if (Model.Done(advice.Id) is { } outcome)
        {
            var status = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            status.Children.Add(new TextBlock { Text = "✓ " + outcome, Style = Res("Callout"), HorizontalAlignment = HorizontalAlignment.Right });
            if (Model.CanPutBack(advice.Id))
            {
                var back = new Button { Content = "Вернуть", Margin = new Thickness(0, 4, 0, 0), HorizontalAlignment = HorizontalAlignment.Right, ToolTip = "Вернуть из Корзины на прежнее место" };
                back.Click += async (_, _) =>
                {
                    if (await Model.PutBack(advice.Id, app) is { } problem)
                        Dialogs.Inform(Window.GetWindow(this), "Не получилось", problem, Glyphs.Warning, Tone.Caution);
                };
                status.Children.Add(back);
            }
            action = status;
        }
        else if (item == null || advice.Action == AdviceAction.Keep)
            action = new TextBlock { Text = "оставить", Style = Res("Caption"), VerticalAlignment = VerticalAlignment.Center };
        else if (advice.Action == AdviceAction.Safe)
        {
            var move = new Button { Content = "В сейф…", VerticalAlignment = VerticalAlignment.Center, ToolTip = "Перенос со сверкой каждого файла; вернуть можно в «Перенесённом»" };
            move.Click += (_, _) => MoveToSafe(advice.Id, item);
            action = move;
        }
        else
        {
            var trash = new Button { Content = "В Корзину", VerticalAlignment = VerticalAlignment.Center, ToolTip = "Вернуть можно здесь же или из Корзины, пока её не очистили" };
            trash.Click += async (_, _) => await ToTrash(advice.Id, item);
            action = trash;
        }
        Grid.SetColumn(action, 3);
        grid.Children.Add(action);
        return grid;
    }

    void MoveToSafe(string id, SpaceItem item)
    {
        if (Demo.IsOn) { Model.MarkDone(id, "в сейфе"); return; }
        var sheet = new SpaceMoveSheet(app, item.Path) { Owner = Window.GetWindow(this) };
        sheet.ShowDialog();
        if (!sheet.DidMove) return;
        Model.MarkDone(id, "в сейфе");
        app.Space.InvalidateAll();
        app.RefreshVolumes();
        app.History.Reload(app.HistoryVolumes);
    }

    async Task ToTrash(string id, SpaceItem item)
    {
        if (!Dialogs.Confirm(Window.GetWindow(this), $"Отправить «{Paths.Name(item.Path)}» в Корзину?",
                $"{Format.Bytes(item.Bytes)}. Вернуть можно здесь же или из Корзины, пока её не очистили.", "В Корзину", "Отмена", Tone.Caution, Glyphs.Trash))
            return;
        if (await Model.Trash(id, app) is { } problem)
            Dialogs.Inform(Window.GetWindow(this), "Не получилось", problem, Glyphs.Warning, Tone.Caution);
    }
}
