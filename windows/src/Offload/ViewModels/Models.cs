using System.IO;
using System.Windows.Threading;
using Microsoft.Win32;
using Offload.Core;

namespace Offload;

// MARK: Обзор

public sealed class OverviewModel : Observable
{
    VolumeInfo? disk;
    public VolumeInfo? Disk { get => disk; private set => Set(ref disk, value); }
    MemorySnapshot? memory;
    public MemorySnapshot? Memory { get => memory; private set => Set(ref memory, value); }
    List<string> advice = [];
    public List<string> Advice { get => advice; private set => Set(ref advice, value); }
    DispatcherTimer? timer;

    public async void Start()
    {
        if (Demo.IsOn)
        {
            Disk = Demo.SystemDisk;
            Memory = Demo.Memory;
            Advice = [.. DiskAdvice(Demo.SystemDisk), .. MemoryStats.Advice(Demo.Memory)];
            return;
        }
        if (timer != null) return;
        timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        timer.Tick += async (_, _) => await Poll();
        timer.Start();
        await Poll();
    }

    async Task Poll()
    {
        var (volume, snapshot) = await Task.Run(() => (Volumes.Info(Paths.Home), MemoryStats.Snapshot()));
        Disk = volume;
        Memory = snapshot;
        Advice = [.. DiskAdvice(volume), .. MemoryStats.Advice(snapshot)];
    }

    public static List<string> DiskAdvice(VolumeInfo? disk)
    {
        if (disk is not { TotalBytes: > 0 } || (double)disk.AvailableBytes / disk.TotalBytes >= 0.15) return [];
        return [$"На системном диске свободно всего {Format.Bytes(disk.AvailableBytes)}. Когда места мало, Windows тормозит: ей негде держать файл подкачки и обновления. Откройте «Освободить место»."];
    }
}

// MARK: Освободить место

public sealed class SpaceModel : Observable
{
    string? location;
    public string? Location { get => location; private set => Set(ref location, value); }
    List<SpaceItem> items = [];
    public List<SpaceItem> Items
    {
        get => items;
        private set { Set(ref items, value); Raise(nameof(VisibleItems), nameof(HiddenSmallCount), nameof(Largest)); }
    }
    bool isScanning;
    public bool IsScanning { get => isScanning; private set => Set(ref isScanning, value); }
    CancelToken token = new();
    readonly Dictionary<string, List<SpaceItem>> cache = new(Paths.Comparer);

    public const long SmallItem = 1 << 20;

    /// <summary>Посчитанные — по убыванию размера, ещё считающиеся — ниже, по имени.</summary>
    public List<SpaceItem> VisibleItems =>
        Items.Where(i => i.IsMeasured && (i.Bytes >= SmallItem || i.AccessDenied)).OrderByDescending(i => i.Bytes).ThenBy(i => i.Name, StringComparer.CurrentCulture)
            .Concat(Items.Where(i => !i.IsMeasured).OrderBy(i => i.Name, StringComparer.CurrentCultureIgnoreCase)).ToList();

    public int HiddenSmallCount => Items.Count(i => i.IsMeasured && i.Bytes < SmallItem && !i.AccessDenied);
    public long Largest => Math.Max(Items.Select(i => i.Bytes).DefaultIfEmpty(0).Max(), 1);

    public string Title(string home) => Location == null ? "Домашняя папка и общие файлы" : Ui.RelativeToHome(Location, home);

    public void Open(string? path, SafetyRules rules)
    {
        token.Cancel();
        Location = path;
        if (cache.TryGetValue(Key(path), out var cached))
        {
            Items = cached;
            IsScanning = false;
            return;
        }
        Scan(rules);
    }

    public void Rescan(SafetyRules rules)
    {
        cache.Remove(Key(Location));
        Open(Location, rules);
    }

    /// <summary>После переноса размеры во всех родительских папках устарели.</summary>
    public void InvalidateAll() => cache.Clear();

    public void GoUp(SafetyRules rules)
    {
        if (Location is not { } current) return;
        var parent = Paths.Parent(current);
        bool rootLevel = Paths.Same(parent, rules.Home) || Paths.Same(current, rules.Public);
        Open(rootLevel ? null : parent, rules);
    }

    async void Scan(SafetyRules rules)
    {
        if (Demo.IsOn)
        {
            Items = Demo.SpaceItems();
            IsScanning = false;
            return;
        }
        var token = new CancelToken();
        this.token = token;
        Items = [];
        IsScanning = true;
        var location = Location;
        var key = Key(location);
        var collector = new Collector<SpaceItem>();
        var throttle = new Throttle(0.3);
        var paths = await Task.Run(() => location != null ? SpaceScanner.Children(location) : Roots(rules));
        if (token.IsCancelled) return;
        Items = await Task.Run(() => paths.Select(p => SpaceScanner.Placeholder(p, rules)).ToList());
        await Task.Run(() => SpaceScanner.Scan(paths, rules, () => token.IsCancelled, item =>
        {
            collector.Append(item);
            if (!throttle.Ready()) return;
            var measured = collector.All;
            Ui.Post(() => { if (!token.IsCancelled) Apply(measured); });
        }));
        if (token.IsCancelled) return;
        Apply(collector.All);
        IsScanning = false;
        cache[key] = Items;
    }

    /// <summary>Подставляет посчитанные строки на место заглушек.</summary>
    void Apply(List<SpaceItem> measured)
    {
        var byId = measured.GroupBy(i => i.Id, Paths.Comparer).ToDictionary(g => g.Key, g => g.Last(), Paths.Comparer);
        Items = Items.Select(i => byId.TryGetValue(i.Id, out var found) ? found : i).ToList();
    }

    static List<string> Roots(SafetyRules rules)
    {
        var paths = SpaceScanner.Children(rules.Home);
        if (Directory.Exists(rules.Public)) paths.Add(rules.Public);
        return paths;
    }

    static string Key(string? path) => path ?? "";
}

// MARK: Перенос

public abstract record MoveStage
{
    public sealed record Idle : MoveStage;
    public sealed record Inspecting : MoveStage;
    public sealed record Ready(MovePlan Plan) : MoveStage;
    public sealed record Running(MoveProgress Progress) : MoveStage;
    public sealed record Done(MoveRecord Record) : MoveStage;
    public sealed record Failed(string Message) : MoveStage;
}

public sealed class MoveModel : Observable
{
    MoveStage stage = new MoveStage.Idle();
    public MoveStage Stage { get => stage; set { Set(ref stage, value); Raise(nameof(IsBusy)); } }
    bool deleteOriginal = true;
    public bool DeleteOriginal { get => deleteOriginal; set => Set(ref deleteOriginal, value); }
    bool acceptCautions;
    public bool AcceptCautions { get => acceptCautions; set => Set(ref acceptCautions, value); }
    /// <summary>Перенос действительно состоялся — только тогда раздел со списком стоит пересчитывать заново.</summary>
    public bool DidMove { get; private set; }
    /// <summary>Токен на каждый запуск, а не один на модель: общий терялся при следующем запуске.</summary>
    readonly Dictionary<Guid, CancelToken> tokens = [];
    Guid? preparing;

    public bool IsBusy => Stage is MoveStage.Inspecting or MoveStage.Running;

    public bool CanRun(MovePlan plan) => plan.CanProceed && (!plan.Verdict.IsCaution || AcceptCautions);

    public async void Prepare(string source, VolumeInfo volume, SafetyRules rules)
    {
        // Идёт копирование — новой проверки не будет: смена диска не должна обрывать начатый перенос.
        if (Stage is MoveStage.Running) return;
        // Отменяется только прежняя проверка, а не перенос.
        if (preparing is { } previous && tokens.TryGetValue(previous, out var old)) old.Cancel();
        var id = Guid.NewGuid();
        var token = new CancelToken();
        tokens[id] = token;
        Stage = new MoveStage.Inspecting();
        AcceptCautions = false;
        preparing = id;
        var plan = await Task.Run(() => new SafeMover(rules).Plan(source, volume, () => token.IsCancelled));
        tokens.Remove(id);
        // Ответ прежней проверки не должен трогать окно: человек мог сменить диск и запустить новую.
        if (preparing != id) return;
        // Без этой ветки отмена оставляла бы окно навсегда в состоянии «Проверяю…».
        if (token.IsCancelled)
        {
            Stage = new MoveStage.Failed("Проверка отменена. Ничего не скопировано и не удалено.");
            return;
        }
        Stage = new MoveStage.Ready(plan);
    }

    public async void Run(MovePlan plan, AppModel app)
    {
        var rules = app.Rules;
        var token = new CancelToken();
        bool delete = DeleteOriginal, accept = AcceptCautions;
        var throttle = new Throttle();
        var operation = app.BeginOperation(token.Cancel);
        tokens[operation] = token;
        Stage = new MoveStage.Running(new MoveProgress(MovePhase.Inspecting, 0, plan.Content.LogicalBytes, Paths.Name(plan.Source)));
        try
        {
            var record = await Task.Run(() => new SafeMover(rules).Execute(plan, delete, accept, () => token.IsCancelled, progress =>
            {
                if (!throttle.Ready()) return;
                Ui.Post(() => { if (Stage is MoveStage.Running) Stage = new MoveStage.Running(progress); });
            }));
            Stage = new MoveStage.Done(record);
            DidMove = true;
        }
        catch (OperationCanceledException)
        {
            Stage = new MoveStage.Failed("Перенос отменён. Оригинал не тронут, незаконченная копия удалена.");
        }
        catch (Exception error)
        {
            Stage = new MoveStage.Failed(error.Message);
        }
        tokens.Remove(operation);
        app.EndOperation(operation);
    }

    public void Cancel()
    {
        foreach (var token in tokens.Values) token.Cancel();
    }
}

// MARK: Перенесённое

public sealed class HistoryModel : Observable
{
    List<MoveRecord> records = [];
    public List<MoveRecord> Records { get => records; private set { Set(ref records, value); Raise(nameof(PendingCount)); } }
    Guid? busyId;
    public Guid? BusyId { get => busyId; private set => Set(ref busyId, value); }
    MoveProgress? progress;
    public MoveProgress? Progress { get => progress; private set => Set(ref progress, value); }
    NoticeMessage? message;
    public NoticeMessage? Message { get => message; set => Set(ref message, value); }
    readonly Dictionary<Guid, CancelToken> tokens = [];
    /// <summary>Есть ли архив на диске — считается при перечитывании списка, а не в каждой строке.</summary>
    Dictionary<Guid, bool> availability = [];

    /// <summary>Сколько перенесённого лежит на дисках — видно на боковой панели.</summary>
    public int PendingCount => Records.Count(r => !r.Restored);

    public void Reload(IReadOnlyList<VolumeInfo> volumes)
    {
        if (Demo.IsOn)
        {
            Records = Demo.Records();
            availability = Records.ToDictionary(r => r.Id, r => !r.Restored);
            return;
        }
        var byId = new Dictionary<Guid, MoveRecord>();
        foreach (var record in Journal.LocalRecords()) byId[record.Id] = Journal.Rebase(record, volumes);
        foreach (var volume in volumes)
        {
            foreach (var record in Journal.Records(volume))
            {
                // Запись с диска обычно свежее, но не тогда, когда архив переехал в сейф: на открытой части могла
                // остаться прежняя запись, указывающая на уже удалённую открытую копию. Побеждает та, чей архив на месте.
                if (byId.TryGetValue(record.Id, out var known) && FileSystem.Exists(known.ArchivedPath) && !FileSystem.Exists(record.ArchivedPath)) continue;
                byId[record.Id] = record;
            }
        }
        Records = byId.Values.OrderByDescending(r => r.Date).ToList();
        availability = Records.ToDictionary(r => r.Id, r => FileSystem.Exists(r.ArchivedPath));
    }

    public bool ArchiveExists(MoveRecord record) => availability.GetValueOrDefault(record.Id);
    public bool IsArchiveAvailable(MoveRecord record) => !record.Restored && ArchiveExists(record);

    public async void Restore(MoveRecord record, bool deleteArchive, AppModel app)
    {
        var token = new CancelToken();
        var rules = app.Rules;
        var throttle = new Throttle();
        BusyId = record.Id;
        Progress = null;
        Message = null;
        var operation = app.BeginOperation(token.Cancel);
        tokens[operation] = token;
        try
        {
            var outcome = await Task.Run(() => new SafeMover(rules).Restore(record, deleteArchive, () => token.IsCancelled, update =>
            {
                if (!throttle.Ready()) return;
                Ui.Post(() => { if (BusyId == record.Id) Progress = update; });
            }));
            var name = record.OriginalName;
            // Оговорки ядра — о том, что сверено не всё, что архив не удалось удалить. Человек должен их увидеть.
            var notes = new List<string>(outcome.Notes);
            if (record.IsEncrypted && deleteArchive)
                notes.Add("Место внутри сейфа освободилось и пойдёт под новые данные, но сам образ на диске от этого не уменьшится.");
            Message = outcome.NeedsAttention
                ? new NoticeMessage(NoticeKind.Warning, $"«{name}» возвращён на место, но с оговорками:", notes)
                : new NoticeMessage(NoticeKind.Success, $"«{name}» возвращён на место, каждый файл перечитан и сверен по SHA-256.", notes);
        }
        catch (OperationCanceledException)
        {
            Message = new NoticeMessage(NoticeKind.Info, "Возврат отменён, незаконченная копия удалена. Архив на диске не тронут.");
        }
        catch (Exception error)
        {
            Message = new NoticeMessage(NoticeKind.Error, $"Вернуть не удалось: {error.Message}");
        }
        BusyId = null;
        Progress = null;
        tokens.Remove(operation);
        app.EndOperation(operation);
        app.RefreshVolumes();
        app.Space.InvalidateAll();
        Reload(app.HistoryVolumes);
    }

    public void Cancel()
    {
        foreach (var token in tokens.Values) token.Cancel();
    }
}

// MARK: Бэкап

public sealed class BackupModel : Observable
{
    List<string> sources;
    public List<string> Sources { get => sources; set { if (Set(ref sources, value)) Persist(); } }
    string excludedText;
    public string ExcludedText { get => excludedText; set { if (Set(ref excludedText, value)) { Persist(); Raise(nameof(ExcludedNames)); } } }
    bool isRunning;
    public bool IsRunning { get => isRunning; private set => Set(ref isRunning, value); }
    string currentItem = "";
    public string CurrentItem { get => currentItem; private set => Set(ref currentItem, value); }
    long copiedBytes;
    public long CopiedBytes { get => copiedBytes; private set => Set(ref copiedBytes, value); }
    BackupReport? report;
    public BackupReport? Report { get => report; private set => Set(ref report, value); }
    string? error;
    public string? Error { get => error; set => Set(ref error, value); }
    readonly Dictionary<Guid, CancelToken> tokens = [];

    /// <summary>Ключи и токены — только в сейф: итог последней раскладки.</summary>
    bool keysBusy;
    public bool KeysBusy { get => keysBusy; private set => Set(ref keysBusy, value); }
    SecretsReport? keysReport;
    public SecretsReport? KeysReport { get => keysReport; private set => Set(ref keysReport, value); }
    NoticeMessage? keysMessage;
    public NoticeMessage? KeysMessage { get => keysMessage; set => Set(ref keysMessage, value); }

    /// <summary>Своя папка бэкапа на диске (например, уже существующая), иначе «Offload Backup» в корне.</summary>
    string? destinationPath;
    public string? DestinationPath { get => destinationPath; set { if (Set(ref destinationPath, value)) Persist(); } }

    public BackupModel()
    {
        sources = Settings.Get<List<string>>("backup.sources") ?? [];
        excludedText = Settings.Get<string>("backup.excluded") ?? string.Join(", ", BackupEngine.DefaultExcludedNames.Order(StringComparer.Ordinal));
        destinationPath = Settings.Get<string>("backup.destination");
        if (Demo.IsOn) sources = Demo.BackupSources;
    }

    public HashSet<string> ExcludedNames =>
        ExcludedText.Split([',', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                    .Where(n => n.Length > 0 && !n.Contains('\\') && !n.Contains('/')).ToHashSet(StringComparer.OrdinalIgnoreCase);

    public string Destination(VolumeInfo volume) =>
        DestinationPath is { } path && Paths.IsInside(path, volume.MountPoint) ? path : Path.Combine(volume.MountPoint, "Offload Backup");

    public void ChooseDestination(VolumeInfo volume)
    {
        var dialog = new OpenFolderDialog
        {
            Title = $"Папка для бэкапа на диске «{volume.Name}» — можно указать уже существующую",
            InitialDirectory = volume.MountPoint,
        };
        if (dialog.ShowDialog() != true) return;
        if (!Paths.IsInside(dialog.FolderName, volume.MountPoint))
        {
            Error = $"Папка должна лежать на диске «{volume.Name}».";
            return;
        }
        DestinationPath = dialog.FolderName;
    }

    void Persist()
    {
        // В демо ничего не сохраняем: иначе вымышленные папки заменили бы настоящие.
        if (Demo.IsOn) return;
        Settings.Set("backup.sources", Sources);
        Settings.Set("backup.excluded", ExcludedText);
        Settings.Set("backup.destination", DestinationPath);
    }

    public void AddSources()
    {
        var dialog = new OpenFolderDialog { Title = "Выберите папки с проектами и документами для бэкапа", Multiselect = true };
        if (dialog.ShowDialog() != true) return;
        var list = new List<string>(Sources);
        foreach (var folder in dialog.FolderNames) if (!list.Any(s => Paths.Same(s, folder))) list.Add(folder);
        Sources = list;
    }

    public void RemoveSource(string path) => Sources = Sources.Where(s => !Paths.Same(s, path)).ToList();

    public async void Run(VolumeInfo volume, AppModel app)
    {
        if (!app.Pro.Allows(ProFeature.ProjectBackup))
        {
            app.Pro.Offer(ProFeature.ProjectBackup);
            return;
        }
        var token = new CancelToken();
        var operation = app.BeginOperation(token.Cancel);
        tokens[operation] = token;
        var sources = Sources.ToList();
        var excluded = ExcludedNames;
        var destination = Destination(volume);
        var throttle = new Throttle(0.2);
        var counter = new Counter();
        IsRunning = true;
        Report = null;
        Error = null;
        CopiedBytes = 0;
        CurrentItem = "";
        try
        {
            Report = await Task.Run(() => BackupEngine.Run(sources, destination, excluded, () => token.IsCancelled, (item, bytes) =>
            {
                long total = counter.Add(bytes);
                if (!throttle.Ready()) return;
                Ui.Post(() =>
                {
                    if (!IsRunning) return;
                    CurrentItem = item;
                    CopiedBytes = total;
                });
            }));
        }
        catch (OperationCanceledException) { Error = "Бэкап остановлен. Уже скопированные файлы остались на диске."; }
        catch (Exception failure) { Error = failure.Message; }
        IsRunning = false;
        tokens.Remove(operation);
        app.EndOperation(operation);
        // Бэкап занял место на диске: без этого в боковой панели оставалась бы прежняя цифра.
        app.RefreshVolumes();
    }

    public void Cancel()
    {
        foreach (var token in tokens.Values) token.Cancel();
    }

    /// <summary>Складывает ~\.ssh, учётку GitHub CLI, дотфайлы с токенами, базы KeePass и секреты из папок бэкапа
    /// в открытый сейф. В открытую часть диска всё это не попадает никогда.</summary>
    public async void PutKeys(AppModel app)
    {
        if (app.SafeVolume is not { } safe || KeysBusy) return;
        var home = app.Rules.Home;
        var roots = Sources.ToList();
        var mount = safe.MountPoint;
        KeysBusy = true;
        KeysMessage = null;
        // Отменяемо: закрытие сейфа по сну или блокировке с прерыванием операций должно остановить и запись ключей.
        var token = new CancelToken();
        var operation = app.BeginOperation(token.Cancel);
        var result = await Task.Run(() => SecretsVault.Fill(mount, home, roots, () => token.IsCancelled));
        KeysReport = result;
        var text = $"В сейф сложено файлов: {result.Copied}, без изменений: {result.Unchanged}" + (result.Problems.Count == 0 ? "." : $", проблем: {result.Problems.Count}.");
        KeysMessage = new NoticeMessage(result.Problems.Count == 0 ? NoticeKind.Success : NoticeKind.Warning, text, result.Problems.Take(5).ToList());
        KeysBusy = false;
        app.EndOperation(operation);
        app.RefreshVolumes();
    }
}
