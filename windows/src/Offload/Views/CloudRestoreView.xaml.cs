using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Offload.Core;

namespace Offload;

/// <summary>Вернуть файл или папку из бэкапа restic в iCloud Drive.</summary>
public partial class CloudRestoreView : UserControl
{
    readonly AppModel app;
    bool discovered;
    bool updatingPicker;

    /// <summary>Длинные папки показываются не целиком: остальное находится поиском.</summary>
    const int VisibleLimit = 300;

    static readonly CultureInfo Russian = CultureInfo.GetCultureInfo("ru-RU");

    public sealed record RepositoryRow(CloudRestore.Repository Repository, string Location, bool Selected, bool Enabled)
    {
        public Tone Tone => Selected ? Tone.Brand : Tone.Neutral;
        public FontWeight Weight => Selected ? FontWeights.SemiBold : FontWeights.Normal;
    }

    public sealed record EntryRow(CloudRestore.Entry Entry, string Detail, bool CanOpen, bool CanRestore)
    {
        public string Glyph => Entry.IsDirectory ? Glyphs.Folder : Glyphs.Document;
        public Tone Tone => Entry.IsDirectory ? Tone.Brand : Tone.Neutral;
    }

    /// <summary>Строка списка снимков. ToString — для поля выбора: его шаблон показывает сам объект.</summary>
    public sealed record SnapshotItem(string Id, string Title)
    {
        public override string ToString() => Title;
    }

    public CloudRestoreView(AppModel app)
    {
        this.app = app;
        InitializeComponent();
        DataContext = app;
        Content = null;
        Content = Pages.Scroll(Root);
        ResticNotice.Text = new CloudRestore.RestoreException(CloudRestore.RestoreErrorKind.ResticMissing).Message;
        Loaded += (_, _) =>
        {
            Model.PropertyChanged += Changed;
            Update();
            if (!discovered)
            {
                discovered = true;
                Model.Discover();
            }
        };
        Unloaded += (_, _) => Model.PropertyChanged -= Changed;
    }

    CloudRestoreModel Model => app.Cloud;

    void Changed(object? sender, PropertyChangedEventArgs e)
    {
        // Набор запроса меняет только доступность кнопки «Найти».
        if (e.PropertyName == nameof(CloudRestoreModel.Query))
        {
            SearchButton.IsEnabled = Model.Query.Trim().Length > 0 && Model.Loading == null;
            return;
        }
        Update();
    }

    static Visibility Show(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

    void Update()
    {
        var model = Model;
        bool restoring = model.Restoring != null;
        bool loading = model.Loading != null;

        // Хранилище
        // В демонстрации хранилище уже открыто — значит, restic «есть», даже если на этом компьютере его нет.
        ResticMissing.Visibility = Show(!model.ResticInstalled && !Demo.IsOn);
        SearchingRow.Visibility = Show(model.Searching && model.Repositories.Count == 0);
        NothingFound.Visibility = Show(!model.Searching && model.Repositories.Count == 0);
        RepositoryList.ItemsSource = model.Repositories
            .Select(r => new RepositoryRow(r, Location(r), Equals(r, model.Repository), !restoring && !loading)).ToList();
        ChooseRepositoryButton.IsEnabled = !restoring;

        PasswordBlock.Visibility = Show(model.Repository != null);
        UnlockedRow.Visibility = Show(model.IsUnlocked);
        LockedBlock.Visibility = Show(!model.IsUnlocked);
        int count = model.Snapshots.Count;
        UnlockedText.Text = $"Открыто · {count} {Plural.Ru(count, "снимок", "снимка", "снимков")}";
        LockButton.IsEnabled = !restoring;
        UnlockSpinner.Visibility = Show(loading);
        UnlockButton.Visibility = Show(!loading);
        FileLinks.IsEnabled = !loading;
        RememberedFileButton.Visibility = Show(model.PasswordFile != null);
        if (model.PasswordFile is { } file)
        {
            RememberedFileText.Text = $"Пароль из «{Paths.Name(file)}»";
            RememberedFileButton.ToolTip = Ui.RelativeToHome(file, app.Rules.Home);
        }
        ErrorRow.Visibility = Show(model.Error != null);
        ErrorText.Text = model.Error ?? "";

        UnlockedSections.Visibility = Show(model.IsUnlocked);
        if (!model.IsUnlocked) return;

        // Снимок
        updatingPicker = true;
        SnapshotPicker.ItemsSource = model.Snapshots.Select(s => new SnapshotItem(s.Id, Title(s))).ToList();
        SnapshotPicker.SelectedValue = model.SnapshotId;
        updatingPicker = false;
        SnapshotPicker.IsEnabled = !restoring && !loading;
        SnapshotPathsRow.Visibility = Show(model.Snapshot != null);
        SnapshotPaths.Text = model.Snapshot is { } snapshot ? string.Join(", ", snapshot.PathsInSnapshot) : "";

        // Куда
        DestinationText.Text = Ui.RelativeToHome(model.Destination, app.Rules.Home);
        DestinationText.ToolTip = model.Destination;
        ChooseDestinationButton.IsEnabled = !restoring;
        RestoringBlock.Visibility = Show(restoring);
        if (model.Restoring is { } entry)
        {
            RestoringText.Text = $"Восстанавливаю «{entry.Name}»";
            var progress = model.RestoreProgress;
            RestoringBytes.Visibility = Show(progress is { BytesTotal: > 0 });
            if (progress is { } value) RestoringBytes.Text = $"{Format.Bytes(value.BytesDone)} из {Format.Bytes(value.BytesTotal)}";
            RestoreBar.IsIndeterminate = progress == null;
            RestoreBar.Value = progress?.Fraction ?? 0;
            SizingText.Visibility = Show(progress == null);
            WaitingNotice.Visibility = Show(model.WaitingForCloud);
        }
        RestoreNotice.Visibility = Show(model.RestoreMessage != null);
        if (model.RestoreMessage is { } message) RestoreNotice.Message = message;
        RevealButton.Visibility = Show(model.RestoreMessage != null && model.RestoredItem != null);

        // Файлы
        SearchButton.IsEnabled = model.Query.Trim().Length > 0 && !loading;
        ClearSearchButton.Visibility = Show(model.SearchResults != null);
        LoadingRow.Visibility = Show(loading);
        LoadingText.Text = model.Loading ?? "";

        if (model.SearchResults is { } results)
        {
            SearchBlock.Visibility = Visibility.Visible;
            BrowseBlock.Visibility = Visibility.Collapsed;
            SearchSummary.Text = results.Count == 0 ? "Ничего не нашлось."
                : $"Найдено: {results.Count}" + (results.Count >= 500 ? " — показаны первые 500, уточните запрос" : "");
            SearchList.ItemsSource = results.Select(e => Row(e, showsPath: true, loading, restoring)).ToList();
            EntryList.ItemsSource = null;
        }
        else
        {
            SearchBlock.Visibility = Visibility.Collapsed;
            BrowseBlock.Visibility = Visibility.Visible;
            SearchList.ItemsSource = null;
            BuildBreadcrumbs(loading);
            EmptyFolder.Visibility = Show(model.Entries.Count == 0 && !loading);
            EntryList.ItemsSource = model.Entries.Take(VisibleLimit).Select(e => Row(e, showsPath: false, loading, restoring)).ToList();
            MoreRow.Visibility = Show(model.Entries.Count > VisibleLimit);
            MoreText.Text = $"Ещё {model.Entries.Count - VisibleLimit} не показаны — найдите нужное по имени.";
        }
    }

    /// <summary>Где лежит хранилище — так, как человек его знает: «iCloud Drive\Бэкапы\…» или путь от домашней папки.</summary>
    string Location(CloudRestore.Repository repository) =>
        Paths.Relative(repository.Path, CloudRestore.ICloudDrive) is { } inside
            ? @"iCloud Drive\" + inside
            : Ui.RelativeToHome(repository.Path, app.Rules.Home);

    static string Title(CloudRestore.Snapshot snapshot)
    {
        var parts = new List<string> { snapshot.Time.ToLocalTime().ToString("d MMM yyyy 'г.', HH:mm", Russian) };
        if (snapshot.TotalBytes is { } bytes) parts.Add(Format.Bytes(bytes));
        parts.Add(snapshot.ShortId);
        return string.Join(" · ", parts);
    }

    static EntryRow Row(CloudRestore.Entry entry, bool showsPath, bool loading, bool restoring)
    {
        var parts = new List<string>();
        if (showsPath) parts.Add(CloudRestore.ParentDirectory(entry.Path));
        if (entry.Size is { } size && !entry.IsDirectory) parts.Add(Format.Bytes(size));
        if (entry.Modified is { } modified) parts.Add(modified.ToLocalTime().ToString("d MMM yyyy 'г.'", Russian));
        return new EntryRow(entry, string.Join(" · ", parts), entry.IsDirectory && !loading, !restoring);
    }

    void BuildBreadcrumbs(bool loading)
    {
        Breadcrumbs.Children.Clear();
        var path = Model.Breadcrumbs;
        for (int index = 0; index < path.Count; index++)
        {
            var item = path[index];
            if (index > 0)
                Breadcrumbs.Children.Add(new TextBlock
                {
                    Text = Glyphs.ChevronRight, Style = (Style)FindResource("Icon"), FontSize = 9, Margin = new Thickness(6, 1, 6, 0),
                });
            var name = item == "/" ? "Корень" : item.TrimEnd('/').Split('/').Last();
            if (item == Model.Directory)
            {
                Breadcrumbs.Children.Add(new TextBlock { Text = name, Style = (Style)FindResource("Body"), FontSize = 12.5, FontWeight = FontWeights.SemiBold,
                                                         VerticalAlignment = VerticalAlignment.Center });
                continue;
            }
            var button = new Button
            {
                Style = (Style)FindResource("LinkButton"), FontSize = 12.5, IsEnabled = !loading, VerticalAlignment = VerticalAlignment.Center,
                Content = new TextBlock { Text = name },
            };
            button.Click += (_, _) => Model.Open(item);
            Breadcrumbs.Children.Add(button);
        }
    }

    // MARK: Действия

    void Discover_Click(object sender, RoutedEventArgs e) => Model.Discover();

    void Repository_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: RepositoryRow row }) Model.Repository = row.Repository;
    }

    void ChooseRepository_Click(object sender, RoutedEventArgs e) => Model.ChooseRepository();

    void Password_Changed(object sender, RoutedEventArgs e)
    {
        UnlockButton.IsEnabled = Password.Password.Length > 0;
        if (Password.Password.Length > 0 && Model.Error != null) Model.Error = null;
    }

    void Password_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) Unlock();
    }

    void Unlock_Click(object sender, RoutedEventArgs e) => Unlock();

    /// <summary>Пароль стирается из поля сразу после попытки — удачной или нет.</summary>
    void Unlock()
    {
        if (Password.Password.Length == 0) return;
        Model.Unlock(Password.Password);
        Password.Clear();
    }

    void RememberedFile_Click(object sender, RoutedEventArgs e)
    {
        if (Model.PasswordFile is { } file) Model.UnlockWithFile(file);
    }

    void PasswordFile_Click(object sender, RoutedEventArgs e) => Model.UnlockWithFile();

    void Lock_Click(object sender, RoutedEventArgs e) => Model.Lock();

    void SnapshotPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (updatingPicker || SnapshotPicker.SelectedValue is not string id || id == Model.SnapshotId) return;
        Model.SnapshotId = id;
    }

    void ChooseDestination_Click(object sender, RoutedEventArgs e) => Model.ChooseDestination();

    void CancelRestore_Click(object sender, RoutedEventArgs e) => Model.CancelRestore();

    void Reveal_Click(object sender, RoutedEventArgs e)
    {
        if (Model.RestoredItem is { } item) Ui.Reveal(item);
    }

    void Query_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) Model.Search();
    }

    void Search_Click(object sender, RoutedEventArgs e) => Model.Search();

    void ClearSearch_Click(object sender, RoutedEventArgs e) => Model.ClearSearch();

    void Entry_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: EntryRow row } && row.Entry.IsDirectory) Model.Open(row.Entry.Path);
    }

    void Restore_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: EntryRow row }) Model.Restore(row.Entry, app);
    }
}
