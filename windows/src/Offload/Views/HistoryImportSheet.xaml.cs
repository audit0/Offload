using System.IO;
using System.Windows;
using Microsoft.Win32;
using Offload.Core;

namespace Offload;

/// <summary>Регистрация переноса, сделанного без OffLoadAI: что лежит на внешнем диске и где оно было на компьютере.
/// После этого вернуть его можно как обычно — со сверкой.</summary>
public partial class HistoryImportSheet : SheetWindow
{
    readonly AppModel app;
    string? archive;
    string? originalParent;
    bool busy;

    public HistoryImportSheet(AppModel app)
    {
        this.app = app;
        InitializeComponent();
    }

    void UpdateState()
    {
        ArchiveText.Text = archive != null ? RelativeToVolume(archive) : "не выбрано";
        ArchiveText.ToolTip = archive;
        ArchiveText.Foreground = archive != null ? Theme.Ink : Theme.Muted;
        ParentText.Text = originalParent != null ? Ui.RelativeToHome(originalParent, app.Rules.Home) : "не выбрано";
        ParentText.ToolTip = originalParent;
        ParentText.Foreground = originalParent != null ? Theme.Ink : Theme.Muted;
        AddButton.IsEnabled = archive != null && originalParent != null && NameBox.Text.Trim().Length > 0 && !busy;
    }

    string RelativeToVolume(string path)
    {
        if (app.Destination is not { } disk || Paths.Relative(path, disk.MountPoint) is not { } relative) return path;
        return $"«{disk.Name}» \\ {relative}";
    }

    void PickArchiveFolder_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Что лежит на внешнем диске", InitialDirectory = app.Destination?.MountPoint ?? "" };
        if (dialog.ShowDialog(this) != true) return;
        SetArchive(dialog.FolderName);
    }

    void PickArchiveFile_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Title = "Что лежит на внешнем диске", InitialDirectory = app.Destination?.MountPoint ?? "", CheckFileExists = true };
        if (dialog.ShowDialog(this) != true) return;
        SetArchive(dialog.FileName);
    }

    void SetArchive(string path)
    {
        archive = path;
        if (NameBox.Text.Length == 0) NameBox.Text = Paths.Name(path);
        UpdateState();
    }

    void PickParent_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Папка на компьютере, где это лежало", InitialDirectory = app.Rules.Home };
        if (dialog.ShowDialog(this) != true) return;
        originalParent = dialog.FolderName;
        UpdateState();
    }

    void Name_Changed(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        if (AddButton != null) UpdateState();
    }

    async void Add_Click(object sender, RoutedEventArgs e)
    {
        if (archive == null || originalParent == null || NameBox.Text.Trim().Length == 0 || busy) return;
        ErrorNotice.Visibility = Visibility.Collapsed;
        // В демонстрации журнал не меняется.
        if (Demo.IsOn)
        {
            ShowError("В демонстрации журнал не меняется.");
            return;
        }
        busy = true;
        UpdateState();
        var archived = archive;
        var original = Path.Combine(originalParent, NameBox.Text.Trim());
        var rules = app.Rules;
        bool removed = RemovedCheck.IsChecked == true;
        var note = NoteBox.Text.Trim();
        try
        {
            await Task.Run(() => new SafeMover(rules).ImportRecord(archived, original, removed, note.Length == 0 ? null : note));
            app.History.Reload(app.HistoryVolumes);
            Close();
        }
        catch (Exception error)
        {
            ShowError(error.Message);
        }
        busy = false;
        if (IsLoaded) UpdateState();
    }

    void ShowError(string text)
    {
        ErrorNotice.Text = text;
        ErrorNotice.Visibility = Visibility.Visible;
    }

    void Cancel_Click(object sender, RoutedEventArgs e) => Close();
}
