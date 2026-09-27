using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using Offload.Core;

namespace Offload;

/// <summary>Лист переноса одного объекта на внешний диск: в сейф или открыто — как выбрано на боковой панели.</summary>
public partial class SpaceMoveSheet : SheetWindow
{
    readonly AppModel app;
    readonly string source;
    readonly MoveModel model = new();
    /// <summary>Для какого места назначения составлен план: он зависит от того, куда класть, и от свободного места.</summary>
    string? preparedFor;
    MovePlan? shownPlan;
    string archivedPath = "";

    /// <summary>Перенос состоялся — список раздела стоит пересчитать.</summary>
    public bool DidMove => model.DidMove;

    public SpaceMoveSheet(AppModel app, string source)
    {
        this.app = app;
        this.source = source;
        InitializeComponent();
        Heading = $"Перенести «{Paths.Name(source)}»";
        Subtitle = Ui.RelativeToHome(source, app.Rules.Home);
        model.PropertyChanged += Model_Changed;
        app.PropertyChanged += App_Changed;
        app.Safe.PropertyChanged += App_Changed;
        PreviewKeyDown += Sheet_KeyDown;
        // Закрывать окно нельзя только во время самого копирования; на этапе проверки — можно.
        Closing += (_, e) => { if (model.Stage is MoveStage.Running) e.Cancel = true; };
        // Проверка шла бы дальше и без окна: на большой папке это десятки секунд впустую.
        Closed += (_, _) =>
        {
            model.Cancel();
            model.PropertyChanged -= Model_Changed;
            app.PropertyChanged -= App_Changed;
            app.Safe.PropertyChanged -= App_Changed;
        };
        Loaded += (_, _) =>
        {
            PrepareIfNeeded();
            Update();
        };
    }

    void Model_Changed(object? sender, PropertyChangedEventArgs e) => Update();

    void App_Changed(object? sender, PropertyChangedEventArgs e)
    {
        PrepareIfNeeded();
        Update();
    }

    void PrepareIfNeeded()
    {
        var target = app.Target;
        if (target?.Id == preparedFor) return;
        // Идущее копирование и его итог не подменяются новой проверкой.
        if (model.Stage is MoveStage.Running or MoveStage.Done) return;
        preparedFor = target?.Id;
        if (target != null) model.Prepare(source, target, app.Rules);
    }

    void Update()
    {
        var target = app.Target;
        var stage = model.Stage;

        bool unlock = target == null && app.Destination != null && app.StoreMode == StoreMode.Safe && app.Safe.Current?.IsEncrypted == true;
        UnlockPanel.Visibility = unlock ? Visibility.Visible : Visibility.Collapsed;
        OpenInsteadText.Text = $"Всё-таки положить открыто на диск «{app.Destination?.Name ?? ""}»";

        bool showStage = target != null || stage is MoveStage.Running or MoveStage.Done or MoveStage.Failed;
        StagePanel.Visibility = showStage ? Visibility.Visible : Visibility.Collapsed;
        InspectingPanel.Visibility = stage is MoveStage.Idle or MoveStage.Inspecting ? Visibility.Visible : Visibility.Collapsed;
        ReadyPanel.Visibility = stage is MoveStage.Ready ? Visibility.Visible : Visibility.Collapsed;
        RunningPanel.Visibility = stage is MoveStage.Running ? Visibility.Visible : Visibility.Collapsed;
        DonePanel.Visibility = stage is MoveStage.Done ? Visibility.Visible : Visibility.Collapsed;
        FailedNotice.Visibility = stage is MoveStage.Failed ? Visibility.Visible : Visibility.Collapsed;

        switch (stage)
        {
            case MoveStage.Idle or MoveStage.Inspecting:
                InspectingText.Text = $"Проверяю содержимое, открытые файлы и диск «{target?.Name ?? ""}»…";
                break;
            case MoveStage.Ready planned:
                ShowPlan(planned.Plan);
                break;
            case MoveStage.Running running:
                var progress = running.Progress;
                PhaseText.Text = progress.Phase.Title();
                BytesText.Text = $"{Format.Bytes(progress.BytesDone)} из {Format.Bytes(progress.BytesTotal)}";
                RunProgress.Value = progress.Fraction;
                ItemText.Text = progress.Item;
                ItemText.ToolTip = progress.Item;
                break;
            case MoveStage.Done done:
                var record = done.Record;
                archivedPath = record.ArchivedPath;
                DoneNotice.Text = record.OriginalRemoved
                    ? $"Перенесено и сверено: {record.Files} {Files(record.Files)}, {Format.Bytes(record.Bytes)}. Оригинал удалён, место на компьютере освободилось."
                    : $"Скопировано и сверено: {record.Files} {Files(record.Files)}, {Format.Bytes(record.Bytes)}. Оригинал на месте.";
                EncryptedRow.Visibility = record.IsEncrypted ? Visibility.Visible : Visibility.Collapsed;
                break;
            case MoveStage.Failed failed:
                FailedNotice.Text = failed.Message;
                break;
        }

        // Кнопки: во время работы — только «Отменить», у готового плана — «Закрыть» и «Перенести», иначе — «Готово».
        bool busy = stage is MoveStage.Inspecting or MoveStage.Running;
        bool ready = stage is MoveStage.Ready;
        CancelButton.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        CloseButton.Visibility = ready ? Visibility.Visible : Visibility.Collapsed;
        RunButton.Visibility = ready ? Visibility.Visible : Visibility.Collapsed;
        RunButton.IsDefault = ready;
        RunButton.IsEnabled = stage is MoveStage.Ready r && model.CanRun(r.Plan);
        DoneButton.Visibility = !busy && !ready ? Visibility.Visible : Visibility.Collapsed;
        DoneButton.IsDefault = !busy && !ready;
    }

    static string Files(int count) => Plural.Ru(count, "файл", "файла", "файлов");

    void ShowPlan(MovePlan plan)
    {
        AcceptCheck.IsChecked = model.AcceptCautions;
        DeleteCheck.IsChecked = model.DeleteOriginal;
        DeleteText.Text = model.DeleteOriginal
            ? "Оригинал удаляется только после того, как каждый файл копии перечитан с диска и сверен по SHA-256."
            : "Останется копия на диске, место на компьютере не освободится.";
        if (ReferenceEquals(plan, shownPlan)) return;
        shownPlan = plan;
        SizeText.Text = $"{Format.Bytes(plan.Content.LogicalBytes)} · файлов {plan.Content.Files} · папок {Math.Max(0, plan.Content.Directories - 1)}";
        TargetText.Text = TrimStart(plan.Target, 64);
        TargetText.ToolTip = plan.Target;
        OpenNotice.Visibility = plan.Volume.IsEncryptedImage ? Visibility.Collapsed : Visibility.Visible;
        BlockedNotice.Visibility = plan.Verdict.IsBlocked ? Visibility.Visible : Visibility.Collapsed;
        BlockedNotice.Text = plan.Verdict.Reason ?? "";
        CautionList.ItemsSource = plan.Verdict.IsCaution ? plan.Verdict.Notes : null;
        AcceptCheck.Visibility = plan.Verdict.IsCaution ? Visibility.Visible : Visibility.Collapsed;
        BlockerList.ItemsSource = plan.Check.Blockers;
        NoteList.ItemsSource = plan.Check.Notes;
    }

    /// <summary>Длинный путь — с многоточием в начале: важнее, где он кончается.</summary>
    static string TrimStart(string text, int length) => text.Length <= length ? text : "…" + text[^(length - 1)..];

    void Accept_Click(object sender, RoutedEventArgs e)
    {
        model.AcceptCautions = AcceptCheck.IsChecked == true;
        Update();
    }

    void Delete_Click(object sender, RoutedEventArgs e)
    {
        model.DeleteOriginal = DeleteCheck.IsChecked == true;
        Update();
    }

    void OpenInstead_Click(object sender, RoutedEventArgs e) => app.StoreMode = StoreMode.Open;

    void Run_Click(object sender, RoutedEventArgs e)
    {
        if (model.Stage is MoveStage.Ready ready && model.CanRun(ready.Plan)) model.Run(ready.Plan, app);
    }

    void Cancel_Click(object sender, RoutedEventArgs e) => model.Cancel();

    void Close_Click(object sender, RoutedEventArgs e) => Close();

    void RevealArchive_Click(object sender, RoutedEventArgs e) => Ui.Reveal(archivedPath);

    void Sheet_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Escape) return;
        e.Handled = true;
        if (model.Stage is not MoveStage.Running) Close();
    }
}
