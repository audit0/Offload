using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Offload.Core;

/// <summary>Восстановление из бэкапа restic — например, из хранилища в iCloud Drive. OffLoadAI хранилище только
/// читает: все команды идут с --no-lock, в хранилище не пишется ничего, даже файл блокировки. Восстановленное
/// ложится в новую папку, поэтому ничего существующего не перезаписывается.</summary>
public static class CloudRestore
{
    /// <summary>Пароль хранилища. Набранный передаётся restic только через stdin; файл с паролем restic читает сам.</summary>
    public abstract record Password
    {
        public sealed record Typed(string Text) : Password;
        public sealed record FromFile(string Path) : Password;
    }

    public sealed record Repository
    {
        public string Path { get; }
        public Repository(string path) => Path = Paths.Normalize(path);
        public string Id => Path;
        public string Name => Paths.Name(Path);
        public bool Equals(Repository? other) => other != null && Paths.Same(Path, other.Path);
        public override int GetHashCode() => Path.ToLowerInvariant().GetHashCode();
    }

    public sealed record Snapshot(string Id, string ShortId, DateTime Time, IReadOnlyList<string> PathsInSnapshot, string Hostname,
                                  IReadOnlyList<string> Tags, long? TotalBytes)
    {
        /// <summary>С какой папки начинать просмотр: общая часть путей снимка.</summary>
        public string Root => CommonDirectory(PathsInSnapshot);
    }

    /// <summary>Файл или папка внутри снимка. Путь — как в снимке, от корня: «/Volumes/SSD/Проекты» или «/C/Users/…».</summary>
    public sealed record Entry(string Path, bool IsDirectory, long? Size, DateTime? Modified)
    {
        public string Id => Path;
        public string Name => Path.TrimEnd('/').Split('/').LastOrDefault() ?? Path;
    }

    public readonly record struct Progress(double Fraction, long BytesDone, long BytesTotal);

    /// <summary>Problems — что восстановить не удалось, по файлу на строку; такие файлы убраны: restic оставляет их с дырами.
    /// Verified — сверено ли восстановленное с бэкапом (--verify): после ошибок restic сверку не делает.</summary>
    public sealed record Report(string Item, long Bytes, int Files, IReadOnlyList<string> Problems, bool Verified);

    public enum RestoreErrorKind { ResticMissing, WrongPassword, NotARepository, NotEnoughSpace, Failed }

    public sealed class RestoreException : Exception
    {
        public RestoreErrorKind Kind { get; }

        public RestoreException(RestoreErrorKind kind, string detail = "", long needed = 0, long available = 0)
            : base(kind switch
            {
                RestoreErrorKind.ResticMissing => "Для восстановления нужна программа restic. Установите её: winget install restic.restic — и нажмите «Проверить снова».",
                RestoreErrorKind.WrongPassword => "Пароль не подходит к этому хранилищу.",
                RestoreErrorKind.NotARepository => $"В папке «{detail}» нет хранилища restic.",
                RestoreErrorKind.NotEnoughSpace => $"Не хватает места: нужно {Format.Bytes(needed)}, свободно {Format.Bytes(available)}.",
                _ => detail,
            }) => Kind = kind;
    }

    // MARK: Где искать

    /// <summary>iCloud Drive для Windows кладёт файлы сюда.</summary>
    public static string ICloudDrive => System.IO.Path.Combine(Paths.Home, "iCloudDrive");

    /// <summary>Хранилище restic узнаётся по файлу config и папкам keys и data рядом.</summary>
    public static bool IsRepository(string path) =>
        FileSystem.Stat(System.IO.Path.Combine(path, "config")) is { IsDirectory: false }
        && FileSystem.Stat(System.IO.Path.Combine(path, "keys")) is { IsDirectory: true }
        && FileSystem.Stat(System.IO.Path.Combine(path, "data")) is { IsDirectory: true };

    /// <summary>Хранилища в папке и на два уровня вглубь. Внутрь найденного хранилища не заходит.</summary>
    public static List<Repository> Discover(string? root = null, int depth = 2)
    {
        root ??= ICloudDrive;
        if (IsRepository(root)) return [new Repository(root)];
        if (depth <= 0) return [];
        List<DirItem> children;
        try { children = FileSystem.List(root); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return []; }
        return children.Where(c => c.IsDirectory && !c.IsLink && !c.IsHidden)
                       .OrderBy(c => c.Name, StringComparer.CurrentCultureIgnoreCase)
                       .SelectMany(c => Discover(System.IO.Path.Combine(root, c.Name), depth - 1)).ToList();
    }

    // MARK: Команды

    public static bool IsResticInstalled => Runner.Locate("restic") != null;

    /// <summary>Общие аргументы: хранилище, пароль и то, что OffLoadAI его только читает.</summary>
    internal static (List<string> arguments, byte[]? stdin) Invocation(IEnumerable<string> command, Repository repository, Password password)
    {
        var arguments = command.Concat(["--repo", repository.Path, "--no-lock", "--json"]).ToList();
        switch (password)
        {
            case Password.Typed typed:
                return (arguments, Encoding.UTF8.GetBytes(typed.Text));
            case Password.FromFile file:
                arguments.AddRange(["--password-file", file.Path]);
                return (arguments, null);
            default:
                throw new ArgumentException("пароль");
        }
    }

    static CommandResult Run(IEnumerable<string> command, Repository repository, Password password, TimeSpan? timeout = null)
    {
        if (!IsResticInstalled) throw new RestoreException(RestoreErrorKind.ResticMissing);
        var (arguments, stdin) = Invocation(command, repository, password);
        var result = Runner.Run("restic", arguments, stdin, timeout ?? TimeSpan.FromMinutes(15));
        if (!result.Succeeded) throw Error(result.Status, result.Stderr, repository);
        return result;
    }

    /// <summary>Коды restic: 10 — хранилища нет, 12 — пароль не подошёл.</summary>
    internal static RestoreException Error(int status, string stderr, Repository repository)
    {
        switch (status)
        {
            case 12: return new RestoreException(RestoreErrorKind.WrongPassword);
            case 10: return new RestoreException(RestoreErrorKind.NotARepository, repository.Path);
        }
        var message = string.Join(" ", Readable(stderr).TakeLast(3));
        if (message.Contains("wrong password", StringComparison.OrdinalIgnoreCase)) return new RestoreException(RestoreErrorKind.WrongPassword);
        return new RestoreException(RestoreErrorKind.Failed, $"restic завершился с кодом {status}" + (message.Length == 0 ? "." : $": {message}"));
    }

    /// <summary>Строки stderr restic для человека: из JSON — только сообщение («There were 3 errors»), без служебных полей;
    /// повторы чтения, которых ждёт облако, — не ошибка и не показываются.</summary>
    public static List<string> Readable(string stderr)
    {
        var result = new List<string>();
        foreach (var raw in stderr.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.Contains("returned error, retrying", StringComparison.Ordinal)) continue;
            if (ParseProblem(line) is { } problem) { result.Add(problem); continue; }
            if (line.StartsWith('{'))
            {
                try
                {
                    using var document = JsonDocument.Parse(line);
                    if (document.RootElement.ValueKind == JsonValueKind.Object && document.RootElement.TryGetProperty("message", out var message)
                        && message.ValueKind == JsonValueKind.String)
                        result.Add(message.GetString()!);
                    continue;
                }
                catch (JsonException) { }
            }
            result.Add(line);
        }
        return result;
    }

    /// <summary>Снимки хранилища, новые сверху. Проверяет и пароль: с неверным restic не отдаст ничего.</summary>
    public static List<Snapshot> Snapshots(Repository repository, Password password) =>
        ParseSnapshots(Run(["snapshots"], repository, password).Stdout).OrderByDescending(s => s.Time).ToList();

    /// <summary>Содержимое папки снимка: сначала папки, потом файлы, по имени.</summary>
    public static List<Entry> List(Repository repository, Password password, string snapshot, string directory)
    {
        var output = Run(["ls", snapshot, directory], repository, password).Output;
        return Sorted(ParseEntries(output).Where(e => e.Path != directory && ParentDirectory(e.Path) == directory));
    }

    /// <summary>Поиск по имени во всём снимке. Без * и ? ищется часть имени, без учёта регистра.</summary>
    public static List<Entry> Search(Repository repository, Password password, string snapshot, string query, int limit = 500)
    {
        var trimmed = query.Trim();
        if (trimmed.Length == 0) return [];
        var pattern = trimmed.IndexOfAny(['*', '?', '[']) >= 0 ? trimmed : $"*{trimmed}*";
        var output = Run(["find", "--ignore-case", "--snapshot", snapshot, pattern], repository, password).Stdout;
        return ParseFind(output).Take(limit).ToList();
    }

    /// <summary>Сколько займёт восстановление: у файла — его размер, у папки — сумма всех файлов внутри.</summary>
    public static long SizeOf(Entry entry, Repository repository, Password password, string snapshot)
    {
        if (!entry.IsDirectory) return entry.Size ?? 0;
        var output = Run(["ls", "--recursive", snapshot, entry.Path], repository, password).Output;
        return ParseEntries(output).Where(e => !e.IsDirectory && e.Path.StartsWith(entry.Path + "/", StringComparison.Ordinal)).Sum(e => e.Size ?? 0);
    }

    /// <summary>Восстанавливает файл или папку из снимка в новую папку внутри folder и сверяет восстановленное
    /// с хранилищем (--verify). Существующее не трогается: новая папка создаётся всегда своя. Прерванное — убирается целиком.
    /// Если не прочитались отдельные файлы, они убираются, а остальное остаётся (см. Report.Problems и Report.Verified).</summary>
    public static Report Restore(Entry entry, Repository repository, Password password, Snapshot snapshot, string folder,
                                 Func<bool>? isCancelled = null, Action<string>? waitingForCloud = null, Action<Progress>? progress = null)
    {
        if (!IsResticInstalled) throw new RestoreException(RestoreErrorKind.ResticMissing);
        long needed = SizeOf(entry, repository, password, snapshot.Id);
        Directory.CreateDirectory(folder);
        if (Volumes.Info(folder) is { } volume)
        {
            // Запас: на восстановление не должен уйти последний свободный гигабайт.
            long reserve = 1L << 30;
            if (needed + reserve > volume.AvailableBytes)
                throw new RestoreException(RestoreErrorKind.NotEnoughSpace, needed: needed + reserve, available: volume.AvailableBytes);
        }
        var target = UniqueFolder(folder, snapshot);
        FileSystem.CreateDirectoryExclusive(target);

        var parent = ParentDirectory(entry.Path);
        var (arguments, stdin) = Invocation(["restore", $"{snapshot.Id}:{parent}", "--include", "/" + EscapePattern(entry.Name),
                                             "--target", target, "--verify"], repository, password);
        var problems = new LineLog(20);
        // Все пути, а не первые сколько-то: каждый такой файл испорчен и будет убран.
        var broken = new LineLog(int.MaxValue);
        void Note(string line)
        {
            if (FailedItem(line) is not { } failure) return;
            var (failedPath, message) = failure;
            problems.AppendUnique(failedPath.Length == 0 ? message : $"{failedPath}: {message}");
            if (failedPath.Length > 0) broken.Append(failedPath);
        }
        CommandResult result;
        try
        {
            result = Runner.Stream("restic", arguments, stdin, isCancelled, onErrorLine: line =>
            {
                // Ошибки с отдельными файлами restic пишет в stderr.
                Note(line);
                // Кусок бэкапа есть только в облаке: просим iCloud скачать его (атрибут «Всегда хранить на этом устройстве»).
                if (StalledFile(line) is not { } pack) return;
                RequestDownload(pack);
                waitingForCloud?.Invoke(pack);
            }, onLine: line =>
            {
                if (ParseProgress(line) is { } update) progress?.Invoke(update);
                Note(line);
            });
        }
        catch
        {
            FileSystem.TryDeleteTree(target);
            throw;
        }
        var item = System.IO.Path.Combine(target, entry.Name);
        RestoreException Fail(RestoreException error)
        {
            FileSystem.TryDeleteTree(target);
            return error;
        }
        // Не прочитались отдельные файлы — restic выходит с 1 (кода «восстановлено не всё» у restore нет).
        // Такие файлы он оставляет полного размера, но с нулями на месте недочитанного: их убираем, а остальное
        // оставляем — повтор, скорее всего, упрётся в то же место. Сверку (--verify) после ошибок restic не делает.
        if (!result.Succeeded)
        {
            if (result.Status != 1 || broken.All.Count == 0 || !FileSystem.Exists(item))
                throw Fail(Error(result.Status, result.Stderr, repository));
            foreach (var path in broken.All) RemoveBroken(path, target);
        }
        if (!FileSystem.Exists(item))
            throw Fail(result.Succeeded ? new RestoreException(RestoreErrorKind.Failed, $"restic ничего не восстановил: «{entry.Path}» нет в снимке.")
                                        : Error(result.Status, result.Stderr, repository));
        var (files, bytes) = Count(item);
        // Из папки не восстановилось ни одного файла — это не «не целиком», а неудача.
        if (!result.Succeeded && files == 0) throw Fail(Error(result.Status, result.Stderr, repository));
        return new Report(item, bytes, files, problems.All, result.Succeeded);
    }

    /// <summary>Убирает файл, который restic восстановил не целиком. Путь пришёл из вывода restic, поэтому — только
    /// обычный файл и только внутри папки восстановления; папки с ошибкой (например, прав) остаются.</summary>
    public static void RemoveBroken(string item, string target)
    {
        string full;
        try { full = System.IO.Path.GetFullPath(System.IO.Path.Combine(target, item.TrimStart('/').Replace('/', System.IO.Path.DirectorySeparatorChar))); }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException) { return; }
        if (Paths.Same(full, target) || !Paths.IsWithin(full, target) || !FileSystem.IsRegularFile(full)) return;
        try { File.Delete(full); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>Попросить облако скачать файл: атрибут «закреплён» — то же, что «Всегда хранить на этом устройстве».</summary>
    static void RequestDownload(string path)
    {
        uint attributes = Native.GetFileAttributesW(Native.Long(path));
        if (attributes == Native.INVALID_FILE_ATTRIBUTES) return;
        Native.SetFileAttributesW(Native.Long(path), attributes | Native.FILE_ATTRIBUTE_PINNED);
    }

    // MARK: Разбор вывода restic

    public static List<Snapshot> ParseSnapshots(byte[] data)
    {
        var result = new List<Snapshot>();
        try
        {
            using var document = JsonDocument.Parse(data);
            foreach (var item in document.RootElement.EnumerateArray())
            {
                if (!item.TryGetProperty("id", out var id) || !item.TryGetProperty("time", out var timeText)
                    || ParseTime(timeText.GetString()) is not { } time) continue;
                long? total = item.TryGetProperty("summary", out var summary) && summary.TryGetProperty("total_bytes_processed", out var processed)
                    ? processed.GetInt64() : null;
                result.Add(new Snapshot(id.GetString()!, item.TryGetProperty("short_id", out var shortId) ? shortId.GetString()! : id.GetString()![..8], time,
                    Strings(item, "paths"), item.TryGetProperty("hostname", out var host) ? host.GetString() ?? "" : "", Strings(item, "tags"), total));
            }
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException) { }
        return result;
    }

    static List<string> Strings(JsonElement item, string name) =>
        item.TryGetProperty(name, out var array) && array.ValueKind == JsonValueKind.Array
            ? array.EnumerateArray().Select(e => e.GetString() ?? "").ToList() : [];

    /// <summary>Вывод restic ls --json: строка на объект; первая — сам снимок, её пропускаем.</summary>
    public static List<Entry> ParseEntries(string output)
    {
        var result = new List<Entry>();
        foreach (var line in output.Split('\n'))
        {
            if (line.Trim().Length == 0) continue;
            try
            {
                using var document = JsonDocument.Parse(line);
                if (EntryFrom(document.RootElement) is { } entry) result.Add(entry);
            }
            catch (JsonException) { }
        }
        return result;
    }

    /// <summary>Вывод restic find --json: массив по снимкам, в каждом — совпадения.</summary>
    public static List<Entry> ParseFind(byte[] data)
    {
        var result = new List<Entry>();
        try
        {
            using var document = JsonDocument.Parse(data);
            foreach (var snapshot in document.RootElement.EnumerateArray())
                if (snapshot.TryGetProperty("matches", out var matches))
                    foreach (var match in matches.EnumerateArray())
                        if (EntryFrom(match) is { } entry) result.Add(entry);
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException) { }
        return result;
    }

    static Entry? EntryFrom(JsonElement item)
    {
        if (item.ValueKind != JsonValueKind.Object || !item.TryGetProperty("path", out var path) || !item.TryGetProperty("type", out var typeElement)) return null;
        if (item.TryGetProperty("struct_type", out var structType) && structType.GetString() == "snapshot") return null;
        var type = typeElement.GetString();
        if (type is not ("dir" or "file" or "symlink")) return null;
        long? size = type == "dir" ? null : item.TryGetProperty("size", out var s) && s.ValueKind == JsonValueKind.Number ? s.GetInt64() : 0;
        return new Entry(path.GetString()!, type == "dir", size, item.TryGetProperty("mtime", out var mtime) ? ParseTime(mtime.GetString()) : null);
    }

    public static Progress? ParseProgress(string line)
    {
        try
        {
            using var document = JsonDocument.Parse(line);
            var item = document.RootElement;
            if (!item.TryGetProperty("message_type", out var typeElement)) return null;
            var type = typeElement.GetString();
            if (type is not ("status" or "summary")) return null;
            long total = item.TryGetProperty("total_bytes", out var t) ? t.GetInt64() : 0;
            long done = item.TryGetProperty("bytes_restored", out var d) ? d.GetInt64() : 0;
            double fraction = type == "summary" ? 1
                : item.TryGetProperty("percent_done", out var p) ? p.GetDouble() : total > 0 ? (double)done / total : 0;
            return new Progress(Math.Clamp(fraction, 0, 1), done, total);
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or FormatException) { return null; }
    }

    /// <summary>Сообщение restic об ошибке с конкретным файлом: «путь: что случилось».</summary>
    public static string? ParseProblem(string line) =>
        FailedItem(line) is { } failure ? (failure.item.Length == 0 ? failure.message : $"{failure.item}: {failure.message}") : null;

    /// <summary>То же по частям: путь внутри восстанавливаемого (с «/» в начале; пустой — ошибка не с файлом) и что случилось.
    /// restic 0.17 и новее пишет такую ошибку строкой JSON, 0.16 — текстом «ignoring error for /путь: что случилось».</summary>
    public static (string item, string message)? FailedItem(string line)
    {
        line = line.TrimEnd('\r');
        if (line.StartsWith('{'))
        {
            try
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("message_type", out var type)
                    || type.ValueKind != JsonValueKind.String || type.GetString() != "error") return null;
                var message = root.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.Object
                    && error.TryGetProperty("message", out var text) && text.ValueKind == JsonValueKind.String ? text.GetString() ?? "ошибка" : "ошибка";
                var item = root.TryGetProperty("item", out var name) && name.ValueKind == JsonValueKind.String ? name.GetString() ?? "" : "";
                return (item, message);
            }
            catch (JsonException) { return null; }
        }
        const string prefix = "ignoring error for ";
        if (!line.StartsWith(prefix, StringComparison.Ordinal)) return null;
        var rest = line[prefix.Length..];
        int colon = rest.IndexOf(": ", StringComparison.Ordinal);
        return colon < 0 ? (rest, "ошибка") : (rest[..colon], rest[(colon + 2)..]);
    }

    static readonly Regex StalledPattern = new(@"returned error, retrying.*?: read (?<path>(?:[A-Za-z]:\\|/).+): [^:]+$", RegexOptions.Compiled);

    /// <summary>Строка restic о том, что файл хранилища не прочитался и чтение будет повторено:
    /// «Load(&lt;data/a08d98&gt;, …) returned error, retrying after 926ms: read C:\…\data\a0\a08d…: …».
    /// Так выглядит кусок бэкапа, который облако убрало с компьютера и ещё не скачало обратно.</summary>
    public static string? StalledFile(string line)
    {
        var match = StalledPattern.Match(line.TrimEnd('\r'));
        return match.Success ? match.Groups["path"].Value : null;
    }

    /// <summary>Время restic — с долями секунды до наносекунд.</summary>
    public static DateTime? ParseTime(string? text)
    {
        if (string.IsNullOrEmpty(text)) return null;
        var trimmed = Regex.Replace(text, @"\.\d+", "");
        return DateTime.TryParse(trimmed, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal, out var date) ? date : null;
    }

    // MARK: Пути снимка (всегда через «/»)

    /// <summary>Шаблоны restic (--include) понимают *, ?, [ ] и \ — в имени файла они должны значить сами себя.</summary>
    public static string EscapePattern(string name)
    {
        var escaped = new StringBuilder();
        foreach (var character in name)
        {
            if ("*?[]\\".Contains(character)) escaped.Append('\\');
            escaped.Append(character);
        }
        return escaped.ToString();
    }

    public static string ParentDirectory(string path)
    {
        var trimmed = path.TrimEnd('/');
        int slash = trimmed.LastIndexOf('/');
        return slash <= 0 ? "/" : trimmed[..slash];
    }

    /// <summary>Общая папка нескольких путей: для «/Volumes/SSD» — она сама, для разных дисков — «/».</summary>
    public static string CommonDirectory(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return "/";
        // Пути снимков Windows restic хранит без двоеточия у буквы диска: «C:\\Users\\q» лежит в дереве как «/C/Users/q».
        static string[] Components(string p)
        {
            var path = p.Length >= 2 && char.IsAsciiLetter(p[0]) && p[1] == ':' ? p[0] + p[2..] : p;
            return path.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        }
        var common = Components(paths[0]).ToList();
        foreach (var path in paths.Skip(1))
        {
            var components = Components(path);
            int length = 0;
            while (length < common.Count && length < components.Length && common[length] == components[length]) length++;
            common = common.Take(length).ToList();
        }
        return common.Count == 0 ? "/" : "/" + string.Join("/", common);
    }

    /// <summary>Хлебные крошки: «/Volumes/SSD/Проекты» → «/», «/Volumes», «/Volumes/SSD», «/Volumes/SSD/Проекты».</summary>
    public static List<string> Ancestors(string path)
    {
        var result = new List<string> { "/" };
        var current = "";
        foreach (var component in path.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            current += "/" + component;
            result.Add(current);
        }
        return result;
    }

    static List<Entry> Sorted(IEnumerable<Entry> entries) =>
        entries.OrderByDescending(e => e.IsDirectory).ThenBy(e => e.Name, StringComparer.CurrentCultureIgnoreCase).ToList();

    /// <summary>«Из бэкапа 26.09.2026 20-23», при совпадении — с номером.</summary>
    internal static string UniqueFolder(string folder, Snapshot snapshot)
    {
        var name = $"Из бэкапа {snapshot.Time.ToLocalTime().ToString("dd.MM.yyyy HH-mm", CultureInfo.InvariantCulture)}";
        var candidate = System.IO.Path.Combine(folder, name);
        for (int number = 2; FileSystem.Exists(candidate); number++) candidate = System.IO.Path.Combine(folder, $"{name} ({number})");
        return candidate;
    }

    static (int files, long bytes) Count(string path)
    {
        if (FileSystem.Stat(path) is not { } stat) return (0, 0);
        if (!stat.IsDirectory) return (1, stat.Size);
        var report = Inspector.Inspect(path);
        return (report.Files, report.LogicalBytes);
    }
}
