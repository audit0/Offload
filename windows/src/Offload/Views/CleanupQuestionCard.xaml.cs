using System.Windows;
using System.Windows.Controls;
using Offload.Core;

namespace Offload;

public partial class CleanupQuestionCard : UserControl
{
    /// <summary>Сколько строк «Что именно» видно: список в сотни строк ничего не добавит к ответу.</summary>
    const int VisibleItems = 40;

    readonly AppModel app;
    readonly Action<QuestionKind> yes;
    CleanupQuestion question;
    CleanupModel.Answer answer = CleanupModel.Answer.Asking;
    bool expanded;
    /// <summary>Для чего собран список «Что именно»: вопрос и можно ли ещё просить не предлагать.</summary>
    (CleanupQuestion Question, bool Asking)? listed;
    /// <summary>Что делает ссылка в строке сейфа.</summary>
    Action? safeLink;

    CleanupModel Model => app.Cleanup;

    public QuestionKind Kind => question.Kind;

    public CleanupQuestionCard(AppModel app, CleanupQuestion question, Action<QuestionKind> yes)
    {
        this.app = app;
        this.question = question;
        this.yes = yes;
        InitializeComponent();
        NoButton.Content = CleanupQuestionDisplay.NoTitle;
        Update(question, Model.AnswerFor(question.Kind), null);
    }

    public void Update(CleanupQuestion question, CleanupModel.Answer answer, string? hint)
    {
        bool fresh = !ReferenceEquals(this.question, question) || TitleText.Text.Length == 0;
        this.question = question;
        this.answer = answer;
        var kind = answer.Kind;
        if (fresh)
        {
            TitleText.Text = question.Title();
            AmountText.Text = question.Amount();
            BodyText.Text = question.Text();
            Notes.ItemsSource = question.Notes;
            Notes.Visibility = question.Notes.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            YesButton.Content = question.YesTitle();
            DetailsTitle.Text = $"Что именно — {question.Items.Count}";
            DetailsPanel.Visibility = question.Items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        bool locked = Model.IsLocked(question.Kind, app);
        ProTag.Update(YesButton, locked);
        YesButton.ToolTip = locked ? "Нужен Offload Pro — откроется окно с ценой и ключом" : null;
        Tile.Glyph = question.Glyph();
        Tile.Tone = kind == CleanupModel.AnswerKind.Declined ? Tone.Neutral : question.Tone();
        Root.Opacity = kind == CleanupModel.AnswerKind.Declined ? 0.7 : 1;

        AskingPanel.Visibility = Show(kind == CleanupModel.AnswerKind.Asking);
        QueuedPanel.Visibility = Show(kind == CleanupModel.AnswerKind.Queued);
        RunningPanel.Visibility = Show(kind == CleanupModel.AnswerKind.Running);
        DonePanel.Visibility = Show(kind == CleanupModel.AnswerKind.Done);
        DeclinedPanel.Visibility = Show(kind == CleanupModel.AnswerKind.Declined);

        HintRow.Visibility = Show(hint != null);
        HintText.Text = hint ?? "";

        if (answer.Running is { } progress)
        {
            RunCount.Visibility = Show(progress.Count > 1);
            RunCount.Text = $"{Math.Max(progress.Index, 1)} из {progress.Count}";
            RunItem.Text = progress.Item.Length == 0 ? " " : $"«{progress.Item}»";
            RunItem.ToolTip = progress.Item.Length == 0 ? null : progress.Item;
            RunPhase.Text = progress.Phase;
            double done = Math.Min(progress.Count, Math.Max(progress.Index, 1) - 1 + progress.Fraction);
            RunBar.Value = done / Math.Max(progress.Count, 1);
        }

        if (answer.Result is { } outcome)
        {
            DoneGlyph.Text = outcome.Done > 0 ? Glyphs.CheckCircle : Glyphs.Warning;
            DoneText.Text = question.DoneLine(outcome);
            RestoreButton.Visibility = Show(outcome.TrashedItems.Count > 0);
            RestoreButton.IsEnabled = Model.Finishing == null;
            OpenBackupButton.Visibility = Show(question.Kind == QuestionKind.Of(CleanupModule.Projects) && outcome.Done > 0);
            Problems.Visibility = Show(outcome.Problems.Count > 0);
            if (outcome.Problems.Count > 0) Problems.Message = new NoticeMessage(NoticeKind.Warning, "Не всё получилось:", outcome.Problems);
        }

        UpdateSafeLine();
        if (expanded) FillDetails();
    }

    static Visibility Show(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>Сейф для вопроса «в сейф»: есть ли он, открыт ли и поместится ли.</summary>
    public void UpdateSafeLine()
    {
        bool shown = question.Kind == QuestionKind.Of(CleanupModule.Safe) && answer.Kind == CleanupModel.AnswerKind.Asking;
        SafeLine.Visibility = Show(shown);
        if (!shown) return;
        var safe = app.Safe;
        string glyph, text;
        var brush = Theme.Muted;
        string? link = null;
        safeLink = null;
        if (Demo.IsOn)
        {
            (glyph, text) = (Glyphs.Unlock, "Сейф открыт");
        }
        else if (app.Destination == null)
        {
            (glyph, text, brush) = (Glyphs.DriveExternal, "Подключите внешний диск с сейфом", Theme.Ink);
        }
        else if (!safe.Exists)
        {
            (glyph, text, brush) = (Glyphs.LockSlash, "Сейфа на диске нет", Theme.Ink);
            link = "Создать…";
            safeLink = () => app.Section = SidebarSection.Safe;
        }
        else if (safe.Current?.IsEncrypted != true)
        {
            (glyph, text, brush) = (Glyphs.Error, "Шифрование образа не подтверждается", Theme.Bad);
        }
        else if (safe.RoomLeft(app.Destination, app.SafeVolume) is { } room && question.Bytes > room)
        {
            (glyph, text, brush) = (Glyphs.Warning, $"Поместится около {Format.Bytes(room)}", Theme.Ink);
            link = "Увеличить…";
            var needed = question.Bytes;
            safeLink = () => new GrowSafeSheet(app, needed).ShowDialog();
        }
        else if (app.SafeVolume is { } volume)
        {
            (glyph, text) = (Glyphs.Unlock, $"Сейф открыт · свободно {Format.Bytes(volume.AvailableBytes)}");
        }
        else
        {
            (glyph, text) = (Glyphs.Lock, "Сейф закрыт — пароль спрошу, когда ответите «да»");
        }
        SafeGlyph.Text = glyph;
        SafeGlyph.Foreground = brush;
        SafeText.Text = text;
        SafeText.Foreground = brush;
        SafeLink.Visibility = Show(link != null);
        SafeLink.Content = link;
    }

    void FillDetails()
    {
        bool asking = answer.Kind == CleanupModel.AnswerKind.Asking;
        if (listed is { } done && ReferenceEquals(done.Question, question) && done.Asking == asking) return;
        listed = (question, asking);
        DetailsList.Children.Clear();
        var items = question.Items;
        var shown = items.Take(VisibleItems).ToList();
        var home = app.Rules.Home;
        for (int i = 0; i < shown.Count; i++)
        {
            var item = shown[i];
            var keeper = question.Keepers.FirstOrDefault(k => k.DuplicateGroup != null && k.DuplicateGroup == item.DuplicateGroup);
            DetailsList.Children.Add(new CleanupFoundRow(item, home, keeper, asking ? () => Model.Ignore(item) : null));
            if (i < shown.Count - 1) DetailsList.Children.Add(new Separator { Style = (Style)FindResource("RowDivider"), Margin = new Thickness(40, 0, 0, 0) });
        }
        if (items.Count > shown.Count)
            DetailsList.Children.Add(new TextBlock
            {
                Text = $"и ещё {items.Count - shown.Count}",
                Style = (Style)FindResource("Caption"),
                Margin = new Thickness(0, 6, 0, 0),
            });
    }

    void DetailsToggle_Click(object sender, RoutedEventArgs e)
    {
        expanded = !expanded;
        DetailsChevron.Text = expanded ? Glyphs.ChevronDown : Glyphs.ChevronRight;
        DetailsList.Visibility = Show(expanded);
        if (expanded) FillDetails();
    }

    void Yes_Click(object sender, RoutedEventArgs e) => yes(question.Kind);

    void No_Click(object sender, RoutedEventArgs e) => Model.Respond(question.Kind, false, app);

    void Reconsider_Click(object sender, RoutedEventArgs e) => Model.Reconsider(question.Kind);

    void Stop_Click(object sender, RoutedEventArgs e) => Model.Stop();

    void Restore_Click(object sender, RoutedEventArgs e) => Model.Restore(question.Kind, app);

    void OpenBackup_Click(object sender, RoutedEventArgs e) => app.Section = SidebarSection.Backup;

    void SafeLink_Click(object sender, RoutedEventArgs e) => safeLink?.Invoke();
}
