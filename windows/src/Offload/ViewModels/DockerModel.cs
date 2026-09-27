using System.IO;
using Offload.Core;

namespace Offload;

public enum DockerStatus { Unknown, Checking, NotInstalled, NotRunning, Ready }

public sealed class DockerModel : Observable
{
    DockerStatus status = DockerStatus.Unknown;
    public DockerStatus Status { get => status; private set => Set(ref status, value); }
    List<DockerVolume> volumes = [];
    public List<DockerVolume> Volumes { get => volumes; private set { Set(ref volumes, value); Raise(nameof(SelectedBytes)); } }
    HashSet<string> selection = [];
    public HashSet<string> Selection { get => selection; set { selection = value; Raise(nameof(Selection), nameof(SelectedBytes)); } }
    Dictionary<string, DateTime> activity = [];
    public Dictionary<string, DateTime> Activity { get => activity; private set => Set(ref activity, value); }
    HashSet<string> checking = [];
    public HashSet<string> Checking { get => checking; private set => Set(ref checking, value); }
    long? rawBytes;
    public long? RawBytes { get => rawBytes; private set => Set(ref rawBytes, value); }
    /// <summary>Docker ещё считает размеры томов.</summary>
    bool sizing;
    public bool Sizing { get => sizing; private set => Set(ref sizing, value); }
    DockerUsage? usage;
    /// <summary>Сколько внутри Docker занимают образы, контейнеры, тома и кеш сборки.</summary>
    public DockerUsage? Usage { get => usage; private set => Set(ref usage, value); }
    bool measuringUsage;
    public bool MeasuringUsage { get => measuringUsage; private set => Set(ref measuringUsage, value); }
    List<string> archives = [];
    public List<string> Archives { get => archives; private set => Set(ref archives, value); }
    string? busy;
    public string? Busy { get => busy; private set => Set(ref busy, value); }
    /// <summary>Идёт очистка: её не отменить — Docker доводит начатое до конца, даже если остановить клиент.</summary>
    bool pruning;
    public bool Pruning { get => pruning; private set => Set(ref pruning, value); }
    List<string> messages = [];
    public List<string> Messages { get => messages; private set => Set(ref messages, value); }
    readonly Dictionary<Guid, CancelToken> tokens = [];
    Guid reloadGeneration = Guid.NewGuid();
    readonly DockerService service = new();

    public static string ArchiveFolder(VolumeInfo volume) => Path.Combine(volume.MountPoint, SafeMover.FolderName, "docker-volumes");

    public long SelectedBytes => Volumes.Where(v => Selection.Contains(v.Name)).Sum(v => v.SizeBytes ?? 0);

    public void Toggle(string name, bool selected)
    {
        var next = new HashSet<string>(Selection);
        if (selected) next.Add(name);
        else next.Remove(name);
        Selection = next;
    }

    /// <summary>Архивы томов ищутся и в сейфе, и на открытой части диска: упакованное раньше не должно
    /// пропасть из виду оттого, что теперь всё кладётся в сейф.</summary>
    public void Reload(AppModel app) => Reload(new[] { app.SafeVolume, app.Destination }.Where(v => v != null).Select(v => v!).ToList());

    public async void Reload(IReadOnlyList<VolumeInfo> archiveVolumes)
    {
        // В демонстрации настоящий Docker не спрашивается: на снимке не должно быть томов человека.
        if (Demo.IsOn)
        {
            Status = DockerStatus.Ready;
            Volumes = Demo.DockerVolumes;
            RawBytes = Demo.DockerRawBytes;
            Usage = Demo.DockerUsage;
            Archives = [];
            Sizing = false;
            MeasuringUsage = false;
            return;
        }
        Status = DockerStatus.Checking;
        Sizing = false;
        MeasuringUsage = false;
        var generation = Guid.NewGuid();
        reloadGeneration = generation;
        // Сначала быстрый список без размеров, потом размеры: docker system df работает десятки секунд.
        var quick = await Task.Run(() =>
        {
            if (!service.IsInstalled) return (DockerStatus.NotInstalled, new List<DockerVolume>(), (long?)null);
            try
            {
                var list = service.ListVolumes(withSizes: false).OrderBy(v => v.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
                return (DockerStatus.Ready, list, service.RawDiskBytes());
            }
            catch (Exception ex) when (ex is DockerException or RunnerException) { return (DockerStatus.NotRunning, new List<DockerVolume>(), service.RawDiskBytes()); }
        });
        if (reloadGeneration != generation) return;
        Status = quick.Item1;
        Volumes = quick.Item2;
        RawBytes = quick.Item3;
        Selection = Selection.Where(n => Volumes.Any(v => v.Name == n)).ToHashSet();
        Archives = await Task.Run(() => archiveVolumes.SelectMany(DockerService.Archives).ToList());
        if (Status != DockerStatus.Ready)
        {
            Usage = null;
            return;
        }
        // Размеры томов и место внутри Docker считаются одновременно: для Docker это одна и та же долгая работа.
        MeasuringUsage = true;
        var measured = Task.Run(service.Usage);
        if (Volumes.Count > 0)
        {
            Sizing = true;
            var sizes = await Task.Run(service.VolumeSizes);
            if (reloadGeneration != generation) return;
            Volumes = Volumes.Select(v => v with { SizeBytes = sizes.TryGetValue(v.Name, out var size) ? size : null })
                             .OrderByDescending(v => v.SizeBytes ?? 0).ThenBy(v => v.Name, StringComparer.CurrentCulture).ToList();
            Sizing = false;
        }
        var result = await measured;
        if (reloadGeneration != generation) return;
        Usage = result;
        MeasuringUsage = false;
    }

    /// <summary>Удаляет выбранное из того, что Docker пересоздаст сам, и ждёт, пока диск Docker вернёт место.</summary>
    public async void Prune(IReadOnlySet<DockerPruneTarget> targets, AppModel app)
    {
        if (targets.Count == 0 || Busy != null) return;
        // В демонстрации кнопки ничего не удаляют: демо запускают, чтобы посмотреть, а Docker настоящий.
        if (Demo.IsOn)
        {
            Messages = ["Демонстрация: Docker не тронут."];
            return;
        }
        long? rawBefore = service.RawDiskBytes();
        Busy = "Очистка: подготовка";
        Pruning = true;
        Messages = [];
        var list = new List<string>();
        try
        {
            var reclaimed = await Task.Run(() => service.Prune(targets, target => Ui.Post(() =>
            {
                if (Busy != null) Busy = $"Очистка: {target.Title().ToLowerInvariant()}";
            })));
            Busy = "Жду, пока Docker вернёт место компьютеру";
            var rawAfter = await Settle(service, rawBefore);
            list.Add(PruneReport(reclaimed, rawBefore, rawAfter));
        }
        catch (Exception error) { list.Add("✗ " + error.Message); }
        Messages = list;
        Busy = null;
        Pruning = false;
        app.RefreshVolumes();
        Reload(app);
    }

    /// <summary>Диск Docker — расширяемый образ WSL: освобождённое внутри он отдаёт не сразу, а часто и вовсе
    /// не отдаёт. Ждём, пока размер перестанет меняться, но не дольше 12 секунд; ответ — размер после.</summary>
    public static async Task<long?> Settle(DockerService service, long? before)
    {
        long? after = service.RawDiskBytes();
        for (int i = 0; i < 6; i++)
        {
            await Task.Delay(TimeSpan.FromSeconds(2));
            long? now = service.RawDiskBytes();
            bool settled = now == after && (now ?? 0) < (before ?? 0);
            after = now;
            if (settled) break;
        }
        return after;
    }

    public static string PruneReport(long? reclaimed, long? rawBefore, long? rawAfter)
    {
        if (reclaimed == 0) return "Удалять было нечего: всё выбранное сейчас используется.";
        var inside = reclaimed is { } bytes ? $"Docker удалил {Format.Bytes(bytes)}." : "Docker удалил выбранное.";
        if (rawBefore is { } before && rawAfter is { } after && before - after >= 64L << 20)
            return $"✓ {inside} Диск Docker на компьютере уменьшился на {Format.Bytes(before - after)}.";
        return $"✓ {inside} Место на компьютере Docker вернёт позже: файл его диска (docker_data.vhdx) сразу не уменьшается — иногда только после перезапуска Docker Desktop.";
    }

    public void CheckActivity(IEnumerable<string> names)
    {
        if (Demo.IsOn) return;
        foreach (var name in names.Where(n => !Checking.Contains(n)).ToList())
        {
            Checking = [.. Checking, name];
            _ = Task.Run(() =>
            {
                DateTime? date = null;
                try { date = service.LastActivity(name); } catch (Exception ex) when (ex is DockerException or RunnerException) { }
                Ui.Post(() =>
                {
                    if (date is { } value) Activity = new Dictionary<string, DateTime>(Activity) { [name] = value };
                    Checking = Checking.Where(n => n != name).ToHashSet();
                });
            });
        }
    }

    public async void ArchiveSelected(VolumeInfo volume, AppModel app)
    {
        var names = Volumes.Where(v => Selection.Contains(v.Name)).Select(v => v.Name).ToList();
        if (names.Count == 0) return;
        if (Demo.IsOn)
        {
            Messages = ["Демонстрация: тома не упакованы, Docker не тронут."];
            return;
        }
        var token = new CancelToken();
        // Упаковка и возврат тома — та же долгая работа, что перенос: выход во время неё должен спросить
        // и довести отмену до конца, а не оборвать docker на полпути.
        var id = app.BeginOperation(token.Cancel);
        tokens[id] = token;
        var folder = ArchiveFolder(volume);
        var list = new List<string>();
        Messages = [];
        foreach (var name in names)
        {
            if (token.IsCancelled) break;
            Busy = $"«{name}»: подготовка";
            try
            {
                var archive = await Task.Run(() =>
                {
                    var path = service.Archive(name, folder, () => token.IsCancelled, status => Ui.Post(() =>
                    {
                        if (Busy != null) Busy = $"«{name}»: {status.ToLowerInvariant()}";
                    }));
                    service.RemoveVolume(name);
                    return path;
                });
                long size = FileSystem.Stat(archive)?.Size ?? 0;
                list.Add($"✓ «{name}» упакован в {Paths.Name(archive)} ({Format.Bytes(size)}), сверен и убран из Docker.");
            }
            catch (OperationCanceledException) { list.Add($"«{name}»: отменено, том не тронут."); }
            catch (Exception error) { list.Add($"✗ «{name}»: {error.Message}"); }
            Messages = [.. list];
        }
        Busy = null;
        tokens.Remove(id);
        app.EndOperation(id);
        Selection = [];
        app.RefreshVolumes();
        Reload(app);
    }

    public async void Restore(string archive, string name, AppModel app)
    {
        if (Demo.IsOn)
        {
            Messages = ["Демонстрация: Docker не тронут."];
            return;
        }
        var token = new CancelToken();
        var id = app.BeginOperation(token.Cancel);
        tokens[id] = token;
        Busy = $"«{name}»: подготовка";
        Messages = [];
        try
        {
            await Task.Run(() => service.Restore(archive, name, () => token.IsCancelled, status => Ui.Post(() =>
            {
                if (Busy != null) Busy = $"«{name}»: {status.ToLowerInvariant()}";
            })));
            Messages = [$"✓ Том «{name}» восстановлен из {Paths.Name(archive)} и сверен. Архив остался на диске."];
        }
        catch (OperationCanceledException) { Messages = [$"«{name}»: отменено, созданный том удалён."]; }
        catch (Exception error) { Messages = [$"✗ «{name}»: {error.Message}"]; }
        Busy = null;
        tokens.Remove(id);
        app.EndOperation(id);
        app.RefreshVolumes();
        Reload(app);
    }

    public void Cancel()
    {
        foreach (var token in tokens.Values) token.Cancel();
    }
}
