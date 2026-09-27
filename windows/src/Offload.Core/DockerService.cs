using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Offload.Core;

public sealed record DockerVolume(string Name, DateTime? CreatedAt, long? SizeBytes, IReadOnlyList<string> UsedBy)
{
    public string Id => Name;
}

/// <summary>Что Docker пересоздаст сам, если понадобится. Тома сюда не входят: в них данные.
/// Порядок случаев — порядок очистки: сначала контейнеры, иначе их образы ещё считаются занятыми.</summary>
public enum DockerPruneTarget { Containers, DanglingImages, Images, BuildCache }

public static class DockerPruneTargets
{
    public static string Title(this DockerPruneTarget target) => target switch
    {
        DockerPruneTarget.Containers => "Остановленные контейнеры",
        DockerPruneTarget.DanglingImages => "Образы без имени",
        DockerPruneTarget.Images => "Все неиспользуемые образы",
        _ => "Кеш сборки",
    };
}

/// <summary>Сколько места внутри Docker занимают образы, контейнеры, тома и кеш сборки — по docker system df.</summary>
public sealed record DockerUsage(DockerUsage.PartInfo? Images = null, DockerUsage.PartInfo? Containers = null,
                                 DockerUsage.PartInfo? Volumes = null, DockerUsage.PartInfo? BuildCache = null)
{
    /// <summary>Reclaimable — сколько Docker готов отдать: у образов — не нужные ни одному контейнеру,
    /// у контейнеров — остановленные, у кеша — не занятый идущей сборкой.</summary>
    public sealed record PartInfo(int Count, int Active, long Bytes, long Reclaimable);

    public PartInfo? Part(DockerPruneTarget target) => target switch
    {
        DockerPruneTarget.Containers => Containers,
        // Сколько занимают образы без имени, docker system df не сообщает.
        DockerPruneTarget.DanglingImages => null,
        DockerPruneTarget.Images => Images,
        _ => BuildCache,
    };

    public long ReclaimableFor(IEnumerable<DockerPruneTarget> targets) => targets.Sum(t => Part(t)?.Reclaimable ?? 0);
}

public enum DockerErrorKind { NotInstalled, NotRunning, InvalidName, InUse, AlreadyExists, DiskGuard, Failed, VerificationFailed, RemoteDaemon, PruneIncomplete }

public sealed class DockerException : Exception
{
    public DockerErrorKind Kind { get; }
    public int Done { get; }
    public long? Reclaimed { get; }
    public string Detail { get; }

    public DockerException(DockerErrorKind kind, string detail = "", IReadOnlyList<string>? containers = null, int done = 0, long? reclaimed = null)
        : base(Describe(kind, detail, containers, done, reclaimed))
    {
        Kind = kind;
        Detail = detail;
        Done = done;
        Reclaimed = reclaimed;
    }

    static string Describe(DockerErrorKind kind, string detail, IReadOnlyList<string>? containers, int done, long? reclaimed) => kind switch
    {
        DockerErrorKind.NotInstalled => "Docker не установлен.",
        DockerErrorKind.NotRunning => "Docker не запущен. Откройте Docker Desktop и повторите.",
        DockerErrorKind.InvalidName => $"Недопустимое имя тома: «{detail}».",
        DockerErrorKind.InUse => $"Том «{detail}» используется контейнерами: {string.Join(", ", containers ?? [])}.",
        DockerErrorKind.AlreadyExists => $"Том «{detail}» уже существует — перезаписывать не буду.",
        DockerErrorKind.DiskGuard => $"Остановлено, чтобы не забить диск компьютера: {detail}",
        DockerErrorKind.VerificationFailed => $"Архив тома «{detail}» не совпал с томом — том не тронут.",
        DockerErrorKind.PruneIncomplete =>
            $"Docker очистил только часть выбранного ({done} из выбранных пунктов{(reclaimed is { } r ? $", освобождено {Format.Bytes(r)}" : "")}), а дальше остановился: {detail}",
        DockerErrorKind.RemoteDaemon =>
            $"Docker сейчас смотрит не на этот компьютер, а на «{detail}» (контекст Docker или DOCKER_HOST). Очищать и архивировать чужой Docker Offload не будет: переключитесь на локальный контекст (docker context use desktop-linux или default) и повторите.",
        _ => detail,
    };
}

/// <summary>Архивация томов Docker на внешний диск и возврат обратно.
///
/// Урок из практики: вывод контейнера Docker по умолчанию пишет ещё и в свой лог внутри диска Docker,
/// и поток архива на десятки гигабайт забивает компьютер. Поэтому все потоковые запуски идут с
/// --log-driver none и --network none, у каждого контейнера есть имя (останавливается сам контейнер,
/// а не только клиент), а рост диска Docker и свободное место отслеживаются.</summary>
public sealed class DockerService(string? home = null)
{
    /// <summary>От этого образа зависит сверка перед удалением тома, поэтому база закреплена по digest,
    /// а свой образ узнаётся по метке — тот же, что у версии для Mac.</summary>
    public const string HelperImage = "offload-gnutar:2";
    const string HelperLabel = "io.github.audit0.offload.helper";
    const string HelperLabelValue = "2";
    static readonly string HelperDockerfile = $"""
        FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
        RUN apk add --no-cache tar
        LABEL {HelperLabel}={HelperLabelValue}

        """;
    static readonly string[] RunPrefix = ["run", "--rm", "--log-driver", "none", "--network", "none"];

    public sealed record DiskGuard(long? MaxRawGrowth, long? MinFreeBytes)
    {
        public static readonly DiskGuard Archiving = new(3L << 30, 5L << 30);
        public static readonly DiskGuard Restoring = new(null, 5L << 30);
    }

    public string Home { get; } = home ?? Paths.Home;

    // MARK: Проверки

    /// <summary>Имена томов Docker: [a-zA-Z0-9][a-zA-Z0-9_.-]+. Всё остальное (например, «\» или «:»)
    /// в аргументе -v превратилось бы в подключение папки с компьютера.</summary>
    public static bool IsValidVolumeName(string name)
    {
        var bytes = Encoding.UTF8.GetBytes(name);
        if (bytes.Length is < 2 or > 255) return false;
        static bool Alphanumeric(byte b) => b is >= 48 and <= 57 or >= 65 and <= 90 or >= 97 and <= 122;
        if (!Alphanumeric(bytes[0])) return false;
        return bytes.Skip(1).All(b => Alphanumeric(b) || b is 95 or 46 or 45);
    }

    public static string? VolumeNameFromArchive(string path)
    {
        var name = Paths.Name(path);
        foreach (var suffix in new[] { ".tar.zst", ".tar" })
        {
            if (!name.EndsWith(suffix, StringComparison.Ordinal)) continue;
            var volume = name[..^suffix.Length];
            return IsValidVolumeName(volume) ? volume : null;
        }
        return null;
    }

    /// <summary>Docker пишет размеры десятичными единицами: 31.65GB, 867.4MB, 1.002kB, 264B.</summary>
    public static long? ParseSize(string text)
    {
        var trimmed = text.Trim();
        foreach (var (suffix, factor) in new[] { ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1.0) })
        {
            if (!trimmed.EndsWith(suffix, StringComparison.Ordinal)) continue;
            return double.TryParse(trimmed[..^suffix.Length], NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
                ? (long)Math.Round(value * factor) : null;
        }
        return null;
    }

    /// <summary>Архивы томов на диске: в папке Offload\docker-volumes и в папках docker-volumes внутри
    /// любой папки верхнего уровня — туда их кладут и ручные скрипты.</summary>
    public static List<string> Archives(VolumeInfo volume)
    {
        var folders = new List<string> { Path.Combine(volume.MountPoint, SafeMover.FolderName, "docker-volumes") };
        try
        {
            foreach (var item in FileSystem.List(volume.MountPoint))
                if (item.IsDirectory && !item.IsLink && !item.IsHidden && !item.Name.Equals(SafeMover.FolderName, Paths.Comparison))
                    folders.Add(Path.Combine(volume.MountPoint, item.Name, "docker-volumes"));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        return folders.SelectMany(ListArchives).OrderBy(p => p, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    static IEnumerable<string> ListArchives(string folder)
    {
        try
        {
            return FileSystem.List(folder).Where(i => !i.IsDirectory && !i.Name.StartsWith('.')
                                                      && (i.Name.EndsWith(".tar.zst", StringComparison.Ordinal) || i.Name.EndsWith(".tar", StringComparison.Ordinal)))
                             .Select(i => Path.Combine(folder, i.Name)).ToList();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return []; }
    }

    /// <summary>Диск Docker Desktop в WSL: в новых версиях — docker_data.vhdx, в старых — ext4.vhdx.</summary>
    public string? RawDiskPath
    {
        get
        {
            var root = Path.Combine(Home, "AppData", "Local", "Docker", "wsl");
            foreach (var candidate in new[] { Path.Combine(root, "disk", "docker_data.vhdx"), Path.Combine(root, "data", "ext4.vhdx"),
                                              Path.Combine(root, "main", "ext4.vhdx") })
                if (File.Exists(candidate)) return candidate;
            return null;
        }
    }

    public long? RawDiskBytes() =>
        RawDiskPath is { } path && FileSystem.Stat(path) is { } stat ? FileSystem.Allocated(path, stat.Size, stat.Attributes, 0) : null;

    public bool IsInstalled => Runner.Locate("docker") != null;

    public void EnsureRunning()
    {
        if (!IsInstalled) throw new DockerException(DockerErrorKind.NotInstalled);
        CommandResult result;
        try { result = Runner.Run("docker", ["info", "--format", "{{.ServerVersion}}"], timeout: TimeSpan.FromSeconds(20)); }
        catch (RunnerException) { throw new DockerException(DockerErrorKind.NotRunning); }
        if (!result.Succeeded) throw new DockerException(DockerErrorKind.NotRunning);
        // Контекст Docker или DOCKER_HOST могут вести на сервер. Тогда «Очистить Docker» удалил бы кеш и образы там,
        // а архивация — перекачала бы и удалила его тома.
        var host = Endpoint();
        if (host == null || !(host.StartsWith("npipe://", StringComparison.OrdinalIgnoreCase) || host.StartsWith("unix://", StringComparison.OrdinalIgnoreCase)))
            throw new DockerException(DockerErrorKind.RemoteDaemon, host ?? "неизвестно");
    }

    /// <summary>Куда смотрит клиент docker: DOCKER_HOST или адрес текущего контекста.</summary>
    string? Endpoint()
    {
        if (Environment.GetEnvironmentVariable("DOCKER_HOST") is { Length: > 0 } host) return host;
        try
        {
            var result = Runner.Run("docker", ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], timeout: TimeSpan.FromSeconds(20));
            var text = result.Output.Trim();
            return result.Succeeded && text.Length > 0 ? text : null;
        }
        catch (RunnerException) { return null; }
    }

    // MARK: Тома

    public List<DockerVolume> ListVolumes(bool withSizes = true)
    {
        EnsureRunning();
        var names = Runner.Check("docker", ["volume", "ls", "--format", "{{.Name}}"], timeout: TimeSpan.FromSeconds(60)).Output
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Where(IsValidVolumeName).ToList();
        if (names.Count == 0) return [];
        var sizes = withSizes ? VolumeSizes() : [];
        var created = new Dictionary<string, DateTime>();
        try
        {
            var inspect = Runner.Run("docker", ["volume", "inspect", "--format", "{{.Name}}\t{{.CreatedAt}}", .. names], timeout: TimeSpan.FromSeconds(60));
            foreach (var line in inspect.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                var parts = line.Trim().Split('\t', 2);
                if (parts.Length == 2 && DateTime.TryParse(parts[1], CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal, out var date))
                    created[parts[0]] = date;
            }
        }
        catch (RunnerException) { }
        var usage = ContainersByVolume();
        return names.Select(n => new DockerVolume(n, created.TryGetValue(n, out var d) ? d : null, sizes.TryGetValue(n, out var s) ? s : null,
                                                  usage.TryGetValue(n, out var u) ? u : [])).ToList();
    }

    /// <summary>Какие контейнеры подключают какие тома — одним вызовом.</summary>
    Dictionary<string, List<string>> ContainersByVolume()
    {
        var usage = new Dictionary<string, List<string>>();
        try
        {
            var list = Runner.Run("docker", ["ps", "-aq"], timeout: TimeSpan.FromSeconds(30));
            var ids = list.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            if (!list.Succeeded || ids.Length == 0) return usage;
            var inspect = Runner.Run("docker", ["inspect", "--format", "{{.Name}}\t{{range .Mounts}}{{if .Name}}{{.Name}}\t{{end}}{{end}}", .. ids],
                                     timeout: TimeSpan.FromSeconds(60));
            if (!inspect.Succeeded) return usage;
            foreach (var line in inspect.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                var fields = line.TrimEnd('\r').Split('\t', StringSplitOptions.RemoveEmptyEntries);
                if (fields.Length == 0) continue;
                var name = fields[0].TrimStart('/');
                foreach (var volume in fields.Skip(1))
                {
                    if (!usage.TryGetValue(volume, out var users)) usage[volume] = users = [];
                    users.Add(name);
                }
            }
        }
        catch (RunnerException) { }
        return usage;
    }

    public Dictionary<string, long> VolumeSizes()
    {
        var sizes = new Dictionary<string, long>();
        try
        {
            var result = Runner.Run("docker", ["system", "df", "-v", "--format", "{{json .Volumes}}"], timeout: TimeSpan.FromMinutes(3));
            if (!result.Succeeded) return sizes;
            using var document = JsonDocument.Parse(result.Stdout);
            foreach (var item in document.RootElement.EnumerateArray())
            {
                if (!item.TryGetProperty("Name", out var name)) continue;
                if (item.TryGetProperty("Size", out var size))
                {
                    if (size.ValueKind == JsonValueKind.String && ParseSize(size.GetString()!) is { } bytes) sizes[name.GetString()!] = bytes;
                    else if (size.ValueKind == JsonValueKind.Number) sizes[name.GetString()!] = size.GetInt64();
                }
            }
        }
        catch (Exception ex) when (ex is RunnerException or JsonException or InvalidOperationException) { }
        return sizes;
    }

    // MARK: Место внутри Docker

    const string UsageFormat = "{{.Type}}\t{{.TotalCount}}\t{{.Active}}\t{{.Size}}\t{{.Reclaimable}}";

    /// <summary>Docker, как и для размеров томов, считает это десятки секунд.</summary>
    public DockerUsage? Usage()
    {
        try
        {
            var result = Runner.Run("docker", ["system", "df", "--format", UsageFormat], timeout: TimeSpan.FromMinutes(3));
            return result.Succeeded ? ParseUsage(result.Output) : null;
        }
        catch (RunnerException) { return null; }
    }

    /// <summary>Строки docker system df: «Images⇥25⇥3⇥12.34GB⇥10.2GB (82%)». У кеша сборки доля в скобках не пишется.</summary>
    public static DockerUsage? ParseUsage(string text)
    {
        var usage = new DockerUsage();
        bool found = false;
        foreach (var line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var fields = line.TrimEnd('\r').Split('\t').Select(f => f.Trim()).ToArray();
            if (fields.Length != 5 || !int.TryParse(fields[1], out var count) || !int.TryParse(fields[2], out var active)
                || ParseSize(fields[3]) is not { } bytes || ParseSize(fields[4].Split('(')[0]) is not { } reclaimable) continue;
            var part = new DockerUsage.PartInfo(count, active, bytes, reclaimable);
            switch (fields[0])
            {
                case "Images": usage = usage with { Images = part }; break;
                case "Containers": usage = usage with { Containers = part }; break;
                case "Local Volumes": usage = usage with { Volumes = part }; break;
                case "Build Cache": usage = usage with { BuildCache = part }; break;
                default: continue;
            }
            found = true;
        }
        return found ? usage : null;
    }

    /// <summary>Что и в каком порядке чистить. Все неиспользуемые образы включают и образы без имени — второй раз их не чистим.</summary>
    public static List<DockerPruneTarget> PruneOrder(IReadOnlySet<DockerPruneTarget> targets) =>
        Enum.GetValues<DockerPruneTarget>()
            .Where(t => targets.Contains(t) && !(t == DockerPruneTarget.DanglingImages && targets.Contains(DockerPruneTarget.Images))).ToList();

    public static string[] PruneArguments(DockerPruneTarget target) => target switch
    {
        DockerPruneTarget.Containers => ["container", "prune", "--force"],
        DockerPruneTarget.DanglingImages => ["image", "prune", "--force"],
        DockerPruneTarget.Images => ["image", "prune", "--all", "--force"],
        _ => ["builder", "prune", "--all", "--force"],
    };

    /// <summary>Итог очистки: «Total reclaimed space: 1.2GB» или «Total:⇥5.6GB» у buildx.</summary>
    public static long? ParseReclaimed(string output)
    {
        foreach (var raw in output.Split('\n').Reverse())
        {
            var text = raw.Trim();
            foreach (var prefix in new[] { "Total reclaimed space:", "Total:" })
                if (text.StartsWith(prefix, StringComparison.Ordinal)) return ParseSize(text[prefix.Length..]);
        }
        return null;
    }

    /// <summary>Удаляет выбранное из того, что Docker пересоздаст сам. Тома не трогаются никогда.
    /// Возвращает, сколько места Docker назвал освободившимся, или null, если он не сказал.</summary>
    public long? Prune(IReadOnlySet<DockerPruneTarget> targets, Action<DockerPruneTarget>? status = null)
    {
        EnsureRunning();
        long? reclaimed = null;
        int done = 0;
        foreach (var target in PruneOrder(targets))
        {
            status?.Invoke(target);
            try
            {
                var result = Runner.Check("docker", PruneArguments(target), timeout: TimeSpan.FromMinutes(30));
                if (ParseReclaimed(result.Output) is { } bytes) reclaimed = (reclaimed ?? 0) + bytes;
                done++;
            }
            catch (Exception ex) when (ex is RunnerException or DockerException)
            {
                // Удалённое до ошибки уже не вернуть: «не получилось» было бы неправдой.
                if (done == 0) throw;
                throw new DockerException(DockerErrorKind.PruneIncomplete, ex.Message, done: done, reclaimed: reclaimed);
            }
        }
        return reclaimed;
    }

    public List<string> Containers(string name)
    {
        if (!IsValidVolumeName(name)) throw new DockerException(DockerErrorKind.InvalidName, name);
        var result = Runner.Check("docker", ["ps", "-a", "--filter", $"volume={name}", "--format", "{{.Names}}"], timeout: TimeSpan.FromSeconds(30));
        return result.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();
    }

    /// <summary>Когда в томе последний раз что-то менялось (по датам файлов и папок на глубине до трёх уровней).</summary>
    public DateTime? LastActivity(string name, Func<bool>? isCancelled = null)
    {
        if (!IsValidVolumeName(name)) throw new DockerException(DockerErrorKind.InvalidName, name);
        EnsureRunning();
        EnsureHelperImage();
        var output = Stream(["-v", $"{name}:/v:ro", HelperImage, "sh", "-c", "find /v -maxdepth 3 -exec stat -c %Y {} + 2>/dev/null | sort -n | tail -1"],
                            null, Sink.Capture, null, isCancelled ?? (() => false));
        return double.TryParse(output, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds) ? DateTime.UnixEpoch.AddSeconds(seconds) : null;
    }

    void EnsureHelperImage()
    {
        try
        {
            var result = Runner.Run("docker", ["image", "inspect", "--format", $"{{{{index .Config.Labels \"{HelperLabel}\"}}}}", HelperImage],
                                    timeout: TimeSpan.FromSeconds(30));
            if (result.Succeeded && result.Output.Trim() == HelperLabelValue) return;
        }
        catch (RunnerException) { }
        Runner.Check("docker", ["build", "-q", "-t", HelperImage, "-"], Encoding.UTF8.GetBytes(HelperDockerfile), TimeSpan.FromMinutes(15));
    }

    // MARK: Архивация и возврат

    /// <summary>Упаковывает том в архив и сверяет список всех путей и содержимое архива с томом.
    /// Сам том не удаляется — это отдельный шаг <see cref="RemoveVolume"/> после успешной архивации.</summary>
    public string Archive(string name, string directory, Func<bool>? isCancelled = null, Action<string>? status = null)
    {
        isCancelled ??= () => false;
        if (!IsValidVolumeName(name)) throw new DockerException(DockerErrorKind.InvalidName, name);
        EnsureRunning();
        var users = Containers(name);
        if (users.Count > 0) throw new DockerException(DockerErrorKind.InUse, name, users);
        status?.Invoke("Подготовка образа с GNU tar");
        EnsureHelperImage();

        Directory.CreateDirectory(directory);
        bool compressed = Runner.Locate("zstd") != null;
        if (RawDiskBytes() == null)
            status?.Invoke("Диск Docker не найден: за его ростом не слежу, только за свободным местом на компьютере");
        var final = SafeMover.Unique(Path.Combine(directory, compressed ? $"{name}.tar.zst" : $"{name}.tar"));
        var partial = Path.Combine(directory, $".{name}.partial-{Guid.NewGuid().ToString().ToUpperInvariant()}");
        try
        {
            status?.Invoke("Упаковка тома");
            // --hard-dereference: жёсткая ссылка иначе ляжет в архив ссылкой без содержимого, и сверка содержимого её не увидит.
            Stream(["-v", $"{name}:/v:ro", HelperImage, "tar", "--hard-dereference", "-cf", "-", "-C", "/v", "."],
                   null, compressed ? Sink.Compress(partial) : Sink.File(partial), DiskGuard.Archiving, isCancelled);
            status?.Invoke("Сверка: список файлов тома");
            var volumeDigest = DigestOfVolume(name, isCancelled);
            status?.Invoke("Сверка: список файлов архива");
            var archiveDigest = DigestOfArchive(partial, compressed, isCancelled);
            if (volumeDigest.Length == 0 || volumeDigest != archiveDigest) throw new DockerException(DockerErrorKind.VerificationFailed, name);
            // Оба отпечатка считает один и тот же вспомогательный образ. Независимо от него архив читает
            // системный tar Windows: число записей должно совпасть с числом путей в томе.
            status?.Invoke("Сверка: архив читается на компьютере");
            if (ArchiveEntryCount(partial, compressed, isCancelled) is not { } listed
                || listed.ToString(CultureInfo.InvariantCulture) != volumeDigest.Split(' ')[0])
                throw new DockerException(DockerErrorKind.VerificationFailed, name);
            FileSystem.RenameExclusive(partial, final);
        }
        catch
        {
            try { if (File.Exists(partial)) File.Delete(partial); } catch (IOException) { }
            throw;
        }
        return final;
    }

    public void RemoveVolume(string name)
    {
        if (!IsValidVolumeName(name)) throw new DockerException(DockerErrorKind.InvalidName, name);
        var users = Containers(name);
        if (users.Count > 0) throw new DockerException(DockerErrorKind.InUse, name, users);
        Runner.Check("docker", ["volume", "rm", name], timeout: TimeSpan.FromMinutes(2));
    }

    const string RestoreLabel = "io.github.audit0.offload.restore";

    /// <summary>Создаёт том из архива и сверяет результат. Существующий том не перезаписывается.</summary>
    public void Restore(string archive, string name, Func<bool>? isCancelled = null, Action<string>? status = null)
    {
        isCancelled ??= () => false;
        if (!IsValidVolumeName(name)) throw new DockerException(DockerErrorKind.InvalidName, name);
        RequireRegularFile(archive);
        EnsureRunning();
        // «Тома нет» — только когда Docker так и ответил. Тайм-аут или другая ошибка — не повод распаковывать в живой том.
        var inspect = Runner.Run("docker", ["volume", "inspect", name], timeout: TimeSpan.FromSeconds(30));
        if (inspect.Succeeded) throw new DockerException(DockerErrorKind.AlreadyExists, name);
        if (!inspect.Stderr.Contains("no such volume", StringComparison.OrdinalIgnoreCase))
            throw new DockerException(DockerErrorKind.Failed, $"Не удалось проверить, есть ли уже том «{name}»: {inspect.Stderr.Trim()}");
        status?.Invoke("Подготовка образа с GNU tar");
        EnsureHelperImage();
        bool compressed = archive.EndsWith(".zst", StringComparison.OrdinalIgnoreCase);
        // Метка с одноразовым значением: по ней видно, что том создан этим вызовом.
        var mark = Guid.NewGuid().ToString().ToUpperInvariant();
        Runner.Check("docker", ["volume", "create", "--label", $"{RestoreLabel}={mark}", name], timeout: TimeSpan.FromMinutes(1));
        if (RestoreMark(name) != mark) throw new DockerException(DockerErrorKind.AlreadyExists, name);
        try
        {
            status?.Invoke("Распаковка в том");
            Stream(["-i", "-v", $"{name}:/v", HelperImage, "tar", "-xpf", "-", "-C", "/v"],
                   compressed ? Feed.Decompress(archive) : Feed.File(archive), Sink.Capture, DiskGuard.Restoring, isCancelled);
            status?.Invoke("Сверка");
            var volumeDigest = DigestOfVolume(name, isCancelled);
            var archiveDigest = DigestOfArchive(archive, compressed, isCancelled);
            if (volumeDigest.Length == 0 || volumeDigest != archiveDigest) throw new DockerException(DockerErrorKind.VerificationFailed, name);
        }
        catch
        {
            // Удаляем, только если на томе наша метка: том создан этим вызовом.
            if (RestoreMark(name) == mark)
                try { Runner.Run("docker", ["volume", "rm", name], timeout: TimeSpan.FromMinutes(2)); } catch (RunnerException) { }
            throw;
        }
    }

    /// <summary>Сколько записей в архиве по мнению системного tar Windows (libarchive) — без Docker. null — архив не читается.</summary>
    internal static long? ArchiveEntryCount(string path, bool compressed, Func<bool> isCancelled)
    {
        try
        {
            using var tar = Runner.MakeProcess("tar", ["-tf", compressed ? "-" : path], redirectStdin: compressed);
            Process? zstd = null;
            tar.Start();
            Task? pump = null;
            if (compressed)
            {
                zstd = Runner.MakeProcess("zstd", ["-dcq", "--", path]);
                zstd.Start();
                zstd.BeginErrorReadLine();
                pump = zstd.StandardOutput.BaseStream.CopyToAsync(tar.StandardInput.BaseStream).ContinueWith(_ => tar.StandardInput.Close());
            }
            tar.BeginErrorReadLine();
            long count = 0;
            var counter = Task.Run(() =>
            {
                var buffer = new byte[1 << 16];
                int read;
                while ((read = tar.StandardOutput.BaseStream.Read(buffer, 0, buffer.Length)) > 0)
                    for (int i = 0; i < read; i++) if (buffer[i] == (byte)'\n') count++;
            });
            while (!tar.WaitForExit(100) || (zstd != null && !zstd.HasExited))
            {
                if (!isCancelled()) continue;
                try { tar.Kill(true); } catch (InvalidOperationException) { }
                try { zstd?.Kill(true); } catch (InvalidOperationException) { }
                return null;
            }
            counter.Wait();
            pump?.Wait();
            bool ok = tar.ExitCode == 0 && (zstd == null || zstd.ExitCode == 0);
            zstd?.Dispose();
            return ok ? count : null;
        }
        catch (Exception ex) when (ex is RunnerException or IOException or InvalidOperationException or AggregateException) { return null; }
    }

    string? RestoreMark(string name)
    {
        try
        {
            var result = Runner.Run("docker", ["volume", "inspect", "--format", $"{{{{index .Labels \"{RestoreLabel}\"}}}}", name],
                                    timeout: TimeSpan.FromSeconds(30));
            return result.Succeeded ? result.Output.Trim() : null;
        }
        catch (RunnerException) { return null; }
    }

    /// <summary>Архив с чужого диска: на его месте может лежать ссылка на файл с компьютера.</summary>
    static void RequireRegularFile(string path)
    {
        if (!FileSystem.IsRegularFile(path)) throw new CopyException(CopyErrorKind.Unreadable, path);
    }

    /// <summary>Отпечаток: число и SHA-256 отсортированного списка путей, затем число и SHA-256 списка
    /// «хеш содержимого — путь» для обычных файлов. pipefail — чтобы ошибка tar или find не терялась.</summary>
    static string Summary(string names, string files) =>
        "set -eo pipefail; " + names + " | sed 's|/$||' | LC_ALL=C sort > /tmp/list; "
        + files + " | LC_ALL=C sort > /tmp/files; "
        + "echo \"$(wc -l < /tmp/list) $(sha256sum < /tmp/list | cut -d' ' -f1) $(wc -l < /tmp/files) $(sha256sum < /tmp/files | cut -d' ' -f1)\"";

    static string HashLine(string input) => "h=$(sha256sum" + input + " | cut -d' ' -f1) && printf '%s  %s\\n' \"$h\" \"$f\"";

    static string Quoted(string text) => "'" + text.Replace("'", "'\\''") + "'";

    internal static string VolumeDigestScript =>
        Summary("cd /v && find . ! -type s", "find . -type f -exec sh -c " + Quoted("for f; do " + HashLine(" < \"$f\"") + "; done") + " _ {} +");

    internal static string ArchiveDigestScript(string tar = "tar")
    {
        var command = "f=\"$TAR_FILENAME\"; " + HashLine("") + " >> /tmp/hashes";
        return Summary("mkdir -p /tmp/x && : > /tmp/hashes && " + tar + " -xvf - -C /tmp/x --quoting-style=literal --to-command=" + Quoted(command),
                       "cat /tmp/hashes");
    }

    string DigestOfVolume(string name, Func<bool> isCancelled) =>
        Stream(["-v", $"{name}:/v:ro", HelperImage, "sh", "-c", VolumeDigestScript], null, Sink.Capture, null, isCancelled);

    string DigestOfArchive(string path, bool compressed, Func<bool> isCancelled)
    {
        RequireRegularFile(path);
        return Stream(["-i", HelperImage, "sh", "-c", ArchiveDigestScript()], compressed ? Feed.Decompress(path) : Feed.File(path),
                      Sink.Capture, null, isCancelled);
    }

    // MARK: Потоки

    sealed record Feed(string Path, bool Decompressed)
    {
        public static Feed File(string path) => new(path, false);
        public static Feed Decompress(string path) => new(path, true);
    }

    sealed record Sink(string? Path, bool Compressed)
    {
        public static readonly Sink Capture = new(null, false);
        public static Sink File(string path) => new(path, false);
        public static Sink Compress(string path) => new(path, true);
    }

    /// <summary>Запускает контейнер с потоковым вводом и выводом, следя за отменой и диском.
    /// Каналы между процессами Windows не соединяет сама — байты перекачиваются здесь.</summary>
    string Stream(string[] arguments, Feed? feed, Sink sink, DiskGuard? guard, Func<bool> isCancelled)
    {
        var container = "offload-" + Guid.NewGuid().ToString("N")[..12];
        var processes = new List<Process>();
        var pumps = new List<Task>();
        FileStream? input = null, output = null;
        var captured = new MemoryStream();
        var docker = Runner.MakeProcess("docker", [.. RunPrefix, "--name", container, .. arguments], redirectStdin: feed != null);
        try
        {
            if (feed != null && !feed.Decompressed)
            {
                RequireRegularFile(feed.Path);
                input = new FileStream(feed.Path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20);
            }
            Process? unzstd = null, zstd = null;
            if (feed is { Decompressed: true })
            {
                unzstd = Runner.MakeProcess("zstd", ["-dcq", "--", feed.Path]);
                unzstd.Start();
                unzstd.BeginErrorReadLine();
                processes.Add(unzstd);
            }
            if (sink is { Path: { } path, Compressed: false })
                output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 20);
            if (sink is { Path: { } zpath, Compressed: true })
            {
                zstd = Runner.MakeProcess("zstd", ["-T0", "-3", "-q", "-o", zpath], redirectStdin: true);
                zstd.Start();
                zstd.BeginErrorReadLine();
                processes.Add(zstd);
            }
            long? startRaw = guard?.MaxRawGrowth != null ? RawDiskBytes() : null;
            docker.Start();
            docker.BeginErrorReadLine();
            processes.Add(docker);
            if (feed != null)
            {
                var source = unzstd?.StandardOutput.BaseStream ?? (System.IO.Stream)input!;
                pumps.Add(source.CopyToAsync(docker.StandardInput.BaseStream, 1 << 20).ContinueWith(_ => { try { docker.StandardInput.Close(); } catch (IOException) { } }));
            }
            System.IO.Stream target = zstd?.StandardInput.BaseStream ?? (System.IO.Stream?)output ?? captured;
            pumps.Add(docker.StandardOutput.BaseStream.CopyToAsync(target, 1 << 20).ContinueWith(_ =>
            {
                if (zstd != null) try { zstd.StandardInput.Close(); } catch (IOException) { }
            }));
            Watch(processes, container, startRaw, guard, isCancelled);
            Task.WaitAll([.. pumps], TimeSpan.FromMinutes(5));
            output?.Flush(true);
        }
        catch
        {
            Stop(processes, container);
            output?.Dispose();
            input?.Dispose();
            throw;
        }
        output?.Dispose();
        input?.Dispose();
        if (docker.ExitCode != 0) throw new DockerException(DockerErrorKind.Failed, $"docker завершился с кодом {docker.ExitCode}");
        foreach (var helper in processes.Where(p => p != docker))
            if (helper.ExitCode != 0) throw new DockerException(DockerErrorKind.Failed, $"zstd завершился с кодом {helper.ExitCode}");
        foreach (var process in processes) process.Dispose();
        return Encoding.UTF8.GetString(captured.ToArray()).Trim();
    }

    void Watch(List<Process> processes, string container, long? startRaw, DiskGuard? guard, Func<bool> isCancelled)
    {
        var lastCheck = DateTime.UtcNow;
        while (processes.Any(p => !p.HasExited))
        {
            if (isCancelled())
            {
                Stop(processes, container);
                throw new OperationCanceledException();
            }
            if (guard != null && DateTime.UtcNow - lastCheck >= TimeSpan.FromSeconds(5))
            {
                lastCheck = DateTime.UtcNow;
                if (guard.MaxRawGrowth is { } limit && startRaw is { } start && RawDiskBytes() is { } now && now - start > limit)
                {
                    Stop(processes, container);
                    throw new DockerException(DockerErrorKind.DiskGuard, $"диск Docker вырос на {Format.Bytes(now - start)}.");
                }
                if (guard.MinFreeBytes is { } minimum && Volumes.Info(Home)?.AvailableBytes is { } free && free < minimum)
                {
                    Stop(processes, container);
                    throw new DockerException(DockerErrorKind.DiskGuard, $"на компьютере осталось {Format.Bytes(free)}.");
                }
            }
            Thread.Sleep(200);
        }
    }

    static void Stop(List<Process> processes, string container)
    {
        // Останавливаем именно контейнер: если убить только клиент docker, контейнер продолжит работать.
        try { Runner.Run("docker", ["rm", "-f", container], timeout: TimeSpan.FromMinutes(1)); } catch (RunnerException) { }
        foreach (var process in processes)
        {
            try { if (!process.HasExited) process.Kill(true); } catch (InvalidOperationException) { }
            process.WaitForExit(5000);
        }
    }
}
