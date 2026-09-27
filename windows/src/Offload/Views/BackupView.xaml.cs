using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using Offload.Core;

namespace Offload;

/// <summary>Бэкап: какие папки копировать, что пропускать, куда класть и отдельно — ключи и токены, только в сейф.</summary>
public partial class BackupView : UserControl
{
    readonly AppModel app;
    bool editingExclusions;
    bool showSecrets;
    bool showProblems;

    public sealed record SourceRow(string Path, string Display);

    public BackupView(AppModel app)
    {
        this.app = app;
        InitializeComponent();
        DataContext = app;
        Content = null;
        Content = Pages.Scroll(Root);
        Loaded += (_, _) =>
        {
            app.PropertyChanged += Changed;
            app.Backup.PropertyChanged += Changed;
            app.Safe.PropertyChanged += Changed;
            app.Pro.PropertyChanged += Changed;
            Update();
        };
        Unloaded += (_, _) =>
        {
            app.PropertyChanged -= Changed;
            app.Backup.PropertyChanged -= Changed;
            app.Safe.PropertyChanged -= Changed;
            app.Pro.PropertyChanged -= Changed;
        };
    }

    BackupModel Model => app.Backup;

    void Changed(object? sender, PropertyChangedEventArgs e)
    {
        // Каждое нажатие клавиши в поле исключений меняет только капсулы: остальное перерисовывать незачем.
        if (sender == Model && e.PropertyName is nameof(BackupModel.ExcludedText) or nameof(BackupModel.ExcludedNames))
        {
            UpdateExclusions();
            return;
        }
        Update();
    }

    static Visibility Show(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

    void Update()
    {
        var model = Model;

        // Что бэкапить
        SourcesEmpty.Visibility = Show(model.Sources.Count == 0);
        SourcesList.ItemsSource = model.Sources.Select(s => new SourceRow(s, Ui.RelativeToHome(s, app.Rules.Home))).ToList();
        SourcesList.IsEnabled = !model.IsRunning;
        AddSourcesButton.IsEnabled = !model.IsRunning;

        UpdateExclusions();

        // Куда
        var target = app.Target;
        TargetBlock.Visibility = Show(target != null);
        DestinationUnlock.Visibility = Show(target == null && app.Destination != null && app.StoreMode == StoreMode.Safe && app.Safe.Current?.IsEncrypted == true);
        if (target != null)
        {
            DestinationText.Text = model.Destination(target);
            DestinationText.ToolTip = model.Destination(target);
            ChooseDestinationButton.IsEnabled = !model.IsRunning;
            OpenWarning.Visibility = Show(!target.IsEncryptedImage);
            RunningRow.Visibility = Show(model.IsRunning);
            CurrentItemText.Text = model.CurrentItem;
            CopiedText.Text = Format.Bytes(model.CopiedBytes);
            RunButton.Visibility = Show(!model.IsRunning);
            RunButton.IsEnabled = model.Sources.Count > 0;
            ProTag.Update(RunButton, !app.Pro.Allows(ProFeature.ProjectBackup));

            if (model.Report is { } report)
            {
                ReportBlock.Visibility = Visibility.Visible;
                ReportNotice.Message = new NoticeMessage(report.Problems.Count == 0 ? NoticeKind.Success : NoticeKind.Warning,
                    $"Скопировано {report.Copied} ({Format.Bytes(report.BytesCopied)}), без изменений {report.Unchanged}. " +
                    $"Секретов пропущено: {report.SecretsSkipped.Count}. Проблем: {report.Problems.Count}.");
                SecretsBlock.Visibility = Show(report.SecretsSkipped.Count > 0);
                SecretsList.ItemsSource = report.SecretsSkipped.Take(100).ToList();
                ProblemsBlock.Visibility = Show(report.Problems.Count > 0);
                ProblemsList.ItemsSource = report.Problems.Take(100).ToList();
            }
            else ReportBlock.Visibility = Visibility.Collapsed;
            SecretsList.Visibility = Show(showSecrets);
            SecretsChevron.Text = showSecrets ? Glyphs.ChevronDown : Glyphs.ChevronRight;
            ProblemsList.Visibility = Show(showProblems);
            ProblemsChevron.Text = showProblems ? Glyphs.ChevronDown : Glyphs.ChevronRight;

            ErrorNotice.Visibility = Show(model.Error != null);
            ErrorNotice.Text = model.Error ?? "";
        }

        // Ключи и токены
        bool safeOpen = app.SafeVolume != null;
        bool safeLocked = !safeOpen && app.Safe.Current?.IsEncrypted == true;
        PutKeysRow.Visibility = Show(safeOpen);
        PutKeysButton.IsEnabled = !model.KeysBusy;
        KeysSpinner.Visibility = Show(model.KeysBusy);
        KeysUnlock.Visibility = Show(safeLocked);
        CreateSafeButton.Visibility = Show(!safeOpen && !safeLocked && app.Destination != null);
        NoDiskText.Visibility = Show(!safeOpen && !safeLocked && app.Destination == null);
        KeysNotice.Visibility = Show(model.KeysMessage != null);
        if (model.KeysMessage is { } message) KeysNotice.Message = message;
        var unprotected = model.KeysReport?.UnprotectedKeys ?? [];
        UnprotectedNotice.Visibility = Show(unprotected.Count > 0);
        UnprotectedNotice.Text = $"SSH-ключи без парольной фразы: {string.Join(", ", unprotected)}. Любой, кто получит сам файл ключа, сразу сможет им пользоваться. " +
                                 @"Добавьте фразу: ssh-keygen -p -f %USERPROFILE%\.ssh\<ключ>";
    }

    void UpdateExclusions()
    {
        var names = Model.ExcludedNames.Order(StringComparer.Ordinal).ToList();
        EditExclusionsButton.Content = editingExclusions ? "Готово" : "Изменить";
        ExclusionsEditor.Visibility = Show(editingExclusions);
        ExclusionsNone.Visibility = Show(!editingExclusions && names.Count == 0);
        ExclusionChips.Visibility = Show(!editingExclusions && names.Count > 0);
        ExclusionChips.ItemsSource = names;
    }

    void RemoveSource_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string path }) Model.RemoveSource(path);
    }

    void AddSources_Click(object sender, RoutedEventArgs e) => Model.AddSources();

    void EditExclusions_Click(object sender, RoutedEventArgs e)
    {
        editingExclusions = !editingExclusions;
        UpdateExclusions();
        if (editingExclusions) ExclusionsEditor.Focus();
    }

    void ChooseDestination_Click(object sender, RoutedEventArgs e)
    {
        if (app.Target is { } target) Model.ChooseDestination(target);
        Update();
    }

    void Run_Click(object sender, RoutedEventArgs e)
    {
        if (app.Target is { } target) Model.Run(target, app);
    }

    void Cancel_Click(object sender, RoutedEventArgs e) => Model.Cancel();

    void SecretsToggle_Click(object sender, RoutedEventArgs e)
    {
        showSecrets = !showSecrets;
        Update();
    }

    void ProblemsToggle_Click(object sender, RoutedEventArgs e)
    {
        showProblems = !showProblems;
        Update();
    }

    void PutKeys_Click(object sender, RoutedEventArgs e) => Model.PutKeys(app);

    void CreateSafe_Click(object sender, RoutedEventArgs e) => app.Section = SidebarSection.Safe;
}
