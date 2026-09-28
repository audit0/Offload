using System.IO;
using Microsoft.Win32;
using Offload.Core;

namespace Offload;

/// <summary>Раздел «Из iCloud»: найти бэкап restic в iCloud Drive, открыть его паролем, выбрать снимок
/// и вернуть из него файл или папку на компьютер.</summary>
public sealed class CloudRestoreModel : Observable
{
    bool resticInstalled = CloudRestore.IsResticInstalled;
    public bool ResticInstalled { get => resticInstalled; private set => Set(ref resticInstalled, value); }
    List<CloudRestore.Repository> repositories = [];
    public List<CloudRestore.Repository> Repositories { get => repositories; private set => Set(ref repositories, value); }
    bool searching;
    public bool Searching { get => searching; private set => Set(ref searching, value); }

    CloudRestore.Repository? repository;
    public CloudRestore.Repository? Repository
    {
        get => repository;
        set
        {
            if (Equals(repository, value)) return;
            repository = value;
            Raise(nameof(Repository));
            Lock();
            if (!Demo.IsOn) Settings.Set("icloud.repository", value?.Path);
        }
    }

    /// <summary>Пароль живёт только в памяти и только пока хранилище открыто: сон и блокировка экрана его стирают.</summary>
    CloudRestore.Password? password;
    /// <summary>Файл с паролем, который выбирали в прошлый раз, — только путь, не содержимое.</summary>
    string? passwordFile;
    public string? PasswordFile { get => passwordFile; private set => Set(ref passwordFile, value); }
    List<CloudRestore.Snapshot> snapshots = [];
    public List<CloudRestore.Snapshot> Snapshots { get => snapshots; private set { Set(ref snapshots, value); Raise(nameof(IsUnlocked), nameof(Snapshot)); } }

    string? snapshotId;
    public string? SnapshotId
    {
        get => snapshotId;
        set
        {
            if (snapshotId == value) return;
            snapshotId = value;
            Raise(nameof(SnapshotId), nameof(Snapshot));
            if (Snapshot is { } snapshot)
            {
                SearchResults = null;
                Open(snapshot.Root);
            }
        }
    }

    public CloudRestore.Snapshot? Snapshot => Snapshots.FirstOrDefault(s => s.Id == SnapshotId);
    public bool IsUnlocked => Snapshots.Count > 0;

    string directory = "/";
    public string Directory { get => directory; private set { Set(ref directory, value); Raise(nameof(Breadcrumbs)); } }
    public List<string> Breadcrumbs => CloudRestore.Ancestors(Directory);
    List<CloudRestore.Entry> entries = [];
    public List<CloudRestore.Entry> Entries { get => entries; private set => Set(ref entries, value); }
    string query = "";
    public string Query { get => query; set => Set(ref query, value); }
    List<CloudRestore.Entry>? searchResults;
    public List<CloudRestore.Entry>? SearchResults { get => searchResults; private set => Set(ref searchResults, value); }

    string? loading;
    /// <summary>Что сейчас загружается — одной фразой; пока не null, остальные кнопки ждут.</summary>
    public string? Loading { get => loading; private set => Set(ref loading, value); }
    string? error;
    public string? Error { get => error; set => Set(ref error, value); }

    string destination;
    public string Destination { get => destination; private set => Set(ref destination, value); }
    CloudRestore.Entry? restoring;
    public CloudRestore.Entry? Restoring { get => restoring; private set => Set(ref restoring, value); }
    CloudRestore.Progress? progress;
    public CloudRestore.Progress? RestoreProgress { get => progress; private set => Set(ref progress, value); }
    /// <summary>iCloud ещё не отдал часть бэкапа: restic ждёт и повторяет чтение.</summary>
    bool waitingForCloud;
    public bool WaitingForCloud { get => waitingForCloud; private set => Set(ref waitingForCloud, value); }
    NoticeMessage? restoreMessage;
    public NoticeMessage? RestoreMessage { get => restoreMessage; private set => Set(ref restoreMessage, value); }
    string? restoredItem;
    public string? RestoredItem { get => restoredItem; private set => Set(ref restoredItem, value); }
    CancelToken? token;

    public CloudRestoreModel()
    {
        destination = Settings.Get<string>("icloud.destination") ?? Path.Combine(Paths.Home, "Downloads");
        if (Demo.IsOn)
        {
            repositories = Demo.CloudRepositories;
            repository = repositories.First();
            snapshots = Demo.CloudSnapshots;
            snapshotId = snapshots.First().Id;
            directory = Demo.CloudDirectory;
            entries = Demo.CloudEntries;
            return;
        }
        passwordFile = Settings.Get<string>("icloud.passwordFile");
        if (Settings.Get<string>("icloud.repository") is { } saved) repository = new CloudRestore.Repository(saved);
        StartGuards();
    }

    // MARK: Хранилище и пароль

    /// <summary>Ищет хранилища в iCloud Drive. Запомненное в прошлый раз остаётся в списке, даже если лежит в другом месте.</summary>
    public async void Discover()
    {
        if (Demo.IsOn || Searching) return;
        ResticInstalled = CloudRestore.IsResticInstalled;
        Searching = true;
        var found = await Task.Run(() => CloudRestore.Discover());
        if (Repository is { } current && !found.Contains(current) && CloudRestore.IsRepository(current.Path)) found.Insert(0, current);
        Repositories = found;
        if (Repository is not { } chosen || !CloudRestore.IsRepository(chosen.Path)) Repository = found.FirstOrDefault();
        Searching = false;
    }

    public void ChooseRepository()
    {
        var dialog = new OpenFolderDialog
        {
            Title = "Папка хранилища restic — в ней лежат config, keys и data",
            InitialDirectory = System.IO.Directory.Exists(CloudRestore.ICloudDrive) ? CloudRestore.ICloudDrive : Paths.Home,
        };
        if (dialog.ShowDialog() != true) return;
        if (!CloudRestore.IsRepository(dialog.FolderName))
        {
            Error = new CloudRestore.RestoreException(CloudRestore.RestoreErrorKind.NotARepository, dialog.FolderName).Message;
            return;
        }
        var chosen = new CloudRestore.Repository(dialog.FolderName);
        if (!Repositories.Contains(chosen)) Repositories = [chosen, .. Repositories];
        Repository = chosen;
    }

    public void Unlock(string text)
    {
        if (text.Length == 0) return;
        Unlock(new CloudRestore.Password.Typed(text));
    }

    public void UnlockWithFile(string? file = null)
    {
        if (file == null)
        {
            var dialog = new OpenFileDialog { Title = "Файл, в котором записан пароль хранилища", CheckFileExists = true };
            if (dialog.ShowDialog() != true) return;
            file = dialog.FileName;
        }
        Unlock(new CloudRestore.Password.FromFile(file));
    }

    async void Unlock(CloudRestore.Password candidate)
    {
        if (Repository is not { } repo || Loading != null || Demo.IsOn) return;
        Loading = "Открываю хранилище…";
        Error = null;
        try
        {
            var found = await Task.Run(() => CloudRestore.Snapshots(repo, candidate));
            if (!Equals(repo, Repository))
            {
                Loading = null;
                return;
            }
            password = candidate;
            if (candidate is CloudRestore.Password.FromFile file)
            {
                PasswordFile = file.Path;
                Settings.Set("icloud.passwordFile", file.Path);
            }
            Snapshots = found;
            Loading = null;
            if (found.Count == 0) Error = "В хранилище пока нет ни одного снимка.";
            SnapshotId = found.FirstOrDefault()?.Id;
        }
        catch (Exception failure)
        {
            Loading = null;
            Error = failure.Message;
        }
    }

    /// <summary>Забыть пароль и всё прочитанное из хранилища.</summary>
    public void Lock()
    {
        token?.Cancel();
        password = null;
        Snapshots = [];
        snapshotId = null;
        Raise(nameof(SnapshotId), nameof(Snapshot));
        Entries = [];
        SearchResults = null;
        Directory = "/";
        Query = "";
    }

    // MARK: Просмотр

    public async void Open(string path)
    {
        if (Repository is not { } repo || password is not { } key || SnapshotId is not { } snapshot)
        {
            if (Demo.IsOn) Directory = path;
            return;
        }
        Loading = $"Читаю «{path.TrimEnd('/').Split('/').Last()}»…";
        Error = null;
        try
        {
            var listed = await Task.Run(() => CloudRestore.List(repo, key, snapshot, path));
            if (snapshot == SnapshotId)
            {
                Directory = path;
                Entries = listed;
                SearchResults = null;
            }
        }
        catch (Exception failure) { Error = failure.Message; }
        Loading = null;
    }

    public async void Search()
    {
        var text = Query.Trim();
        if (text.Length == 0)
        {
            SearchResults = null;
            return;
        }
        if (Repository is not { } repo || password is not { } key || SnapshotId is not { } snapshot) return;
        Loading = $"Ищу «{text}»…";
        Error = null;
        try
        {
            var found = await Task.Run(() => CloudRestore.Search(repo, key, snapshot, text));
            if (snapshot == SnapshotId) SearchResults = found;
        }
        catch (Exception failure) { Error = failure.Message; }
        Loading = null;
    }

    public void ClearSearch()
    {
        Query = "";
        SearchResults = null;
    }

    // MARK: Восстановление

    public void ChooseDestination()
    {
        var dialog = new OpenFolderDialog { Title = "Куда класть восстановленное — внутри появится новая папка", InitialDirectory = Destination };
        if (dialog.ShowDialog() != true) return;
        Destination = dialog.FolderName;
        if (!Demo.IsOn) Settings.Set("icloud.destination", Destination);
    }

    public async void Restore(CloudRestore.Entry entry, AppModel app)
    {
        if (Restoring != null) return;
        if (Demo.IsOn)
        {
            RestoreMessage = new NoticeMessage(NoticeKind.Success, $"Демонстрация: «{entry.Name}» восстановился бы в новую папку в «{Paths.Name(Destination)}».");
            return;
        }
        if (Repository is not { } repo || password is not { } key || Snapshot is not { } snapshot) return;
        var folder = Destination;
        var token = new CancelToken();
        this.token = token;
        var operation = app.BeginOperation(token.Cancel);
        var throttle = new Throttle(0.2);
        Restoring = entry;
        RestoreProgress = null;
        WaitingForCloud = false;
        RestoreMessage = null;
        RestoredItem = null;
        Error = null;
        try
        {
            var report = await Task.Run(() => CloudRestore.Restore(entry, repo, key, snapshot, folder, () => token.IsCancelled,
                waitingForCloud: _ => Ui.Post(() => { if (Equals(Restoring, entry)) WaitingForCloud = true; }),
                progress: update =>
                {
                    if (!throttle.Ready() && update.Fraction < 1) return;
                    Ui.Post(() =>
                    {
                        if (!Equals(Restoring, entry)) return;
                        // Данные пошли — значит, облако докачало.
                        if (update.BytesDone > (RestoreProgress?.BytesDone ?? 0)) WaitingForCloud = false;
                        RestoreProgress = update;
                    });
                }));
            RestoredItem = report.Item;
            var what = entry.IsDirectory
                ? $"{report.Files} {Plural.Ru(report.Files, "файл", "файла", "файлов")}, {Format.Bytes(report.Bytes)}"
                : Format.Bytes(report.Bytes);
            RestoreMessage = report.Verified && report.Problems.Count == 0
                ? new NoticeMessage(NoticeKind.Success, $"«{entry.Name}» восстановлено и сверено с бэкапом: {what}.")
                : new NoticeMessage(NoticeKind.Warning, $"«{entry.Name}» восстановлено не целиком: {what}. Файлы, которые не прочитались из бэкапа, убраны — они были бы испорчены; остальное с бэкапом не сверено: после ошибок restic не сверяет. Не удалось:",
                                    report.Problems.Take(10).ToList());
        }
        catch (OperationCanceledException) { RestoreMessage = new NoticeMessage(NoticeKind.Info, "Восстановление остановлено, недокачанное убрано."); }
        catch (Exception failure) { RestoreMessage = new NoticeMessage(NoticeKind.Error, failure.Message); }
        Restoring = null;
        RestoreProgress = null;
        WaitingForCloud = false;
        this.token = null;
        app.EndOperation(operation);
    }

    public void CancelRestore() => token?.Cancel();

    // MARK: Защита пароля

    /// <summary>Сон и блокировка экрана забывают пароль — как у сейфа.</summary>
    void StartGuards()
    {
        SystemEvents.PowerModeChanged += (_, e) => { if (e.Mode == PowerModes.Suspend) Ui.Post(LockIfIdle); };
        SystemEvents.SessionSwitch += (_, e) =>
        {
            if (e.Reason is SessionSwitchReason.SessionLock or SessionSwitchReason.ConsoleDisconnect or SessionSwitchReason.RemoteDisconnect)
                Ui.Post(LockIfIdle);
        };
    }

    /// <summary>Идущее восстановление не прерывается: пароль у него уже есть, а бросать его на середине незачем.</summary>
    void LockIfIdle()
    {
        if (Restoring != null || password == null) return;
        Lock();
    }
}
