namespace Offload.Core;

/// <summary>Копия файла, у которого есть точные двойники.</summary>
public sealed record DuplicateCopy(
    string Path,
    /// <summary>Сколько места освободит удаление копии — занятое на диске: у сжатых файлов оно меньше размера.</summary>
    long Allocated,
    DateTime? Modified,
    DateTime? Created,
    Verdict? VerdictOrNull = null,
    /// <summary>Данные общие с другой копией группы (клон блоков ReFS): удаление такой копии места не освободит.</summary>
    bool SharesData = false,
    /// <summary>Зашифрованный образ диска: личные данные. Его копию, как и сам образ, разбор не удаляет.</summary>
    bool IsEncryptedImage = false)
{
    public Verdict Verdict => VerdictOrNull ?? Verdict.Safe;
}

/// <summary>Файлы с одинаковым содержимым: совпали размер и SHA-256 всего файла.</summary>
public sealed record DuplicateGroup(string Id, long Bytes, IReadOnlyList<DuplicateCopy> Copies);

/// <summary>Отпечаток файла для поиска дубликатов. Хранится в базе решений, чтобы при следующем поиске
/// не читать заново файл, который не менялся.</summary>
public sealed record Fingerprint(string Path, long Size, double Modified, long Inode, string? Edges = null, string? Full = null);

/// <summary>Поиск одинаковых файлов в папках человека.
///
/// Файлы сравниваются по нарастающей цене: сначала размер (без чтения), потом первые и последние 64 КБ,
/// и только для совпавших — SHA-256 целиком. Внутрь git-репозиториев, скрытых и восстанавливаемых папок
/// (node_modules…) и окружений Python поиск не заходит: одинаковые файлы там нужны программам. Файлы OneDrive
/// и iCloud, которых нет на этом компьютере, не читаются — чтение скачало бы их.</summary>
public sealed class DuplicateFinder
{
    public sealed record ProgressInfo(int Files, long ReadBytes, string Current);

    public sealed class Result
    {
        /// <summary>Группы по убыванию места, которое освободится.</summary>
        public List<DuplicateGroup> Groups { get; } = [];
        public List<Fingerprint> Fingerprints { get; set; } = [];
        public long ReadBytes { get; set; }
        /// <summary>false — поиск остановлен: итог неполный, и старые отпечатки удалять нельзя.</summary>
        public bool Completed { get; set; }
    }

    public long MinimumBytes { get; init; } = 1_000_000;
    public int EdgeBytes { get; init; } = 64 * 1024;
    public IReadOnlySet<string> SkippedFolders { get; init; } = BackupEngine.DefaultExcludedNames;
    /// <summary>Общий идентификатор содержимого у клонов; null — неизвестно (так на NTFS всегда).</summary>
    public Func<string, long?> ContentIdentifier { get; init; } = _ => null;
    /// <summary>Зашифрован ли образ VHDX. Спрашивается только у копий, которые уже нашлись одинаковыми.</summary>
    public Func<string, bool> EncryptedImage { get; init; } = path => SecretsVault.IsEncryptedImage(path);

    sealed class Entry
    {
        public required string Path;
        public long Size;
        public long Allocated;
        public DateTime? Modified;
        public DateTime? Created;
        public long? Device;
        public long Inode;
        public long? Clone;
        public string? Edges;
        public string? Full;
        public double ModifiedStamp => Modified is { } date ? (date - DateTime.UnixEpoch).TotalSeconds : 0;
    }

    public Result Find(IEnumerable<string> roots, SafetyRules rules, IReadOnlyDictionary<string, Fingerprint>? known = null,
                       Func<bool>? isCancelled = null, Action<ProgressInfo>? progress = null)
    {
        isCancelled ??= () => false;
        known ??= new Dictionary<string, Fingerprint>();
        var result = new Result();
        int files = 0;
        long read = 0;
        string current = "";
        void Report() => progress?.Invoke(new ProgressInfo(files, read, current));

        var entries = Walk(roots, isCancelled, ref files, ref current, Report);
        if (entries == null) return result;

        // 1. Размер: одинаковыми могут быть только файлы одного размера. Читать пока нечего.
        var sized = entries.GroupBy(e => e.Size).Where(g => g.Count() > 1).Select(g => Probe(g.ToList()))
            .Where(g => g.Count > 1).OrderByDescending(g => g[0].Size).ThenByDescending(g => g[0].Path, StringComparer.Ordinal).ToList();

        // 2. Начало и конец: разные файлы одного размера почти всегда расходятся уже здесь.
        var printed = new Dictionary<string, Entry>(Paths.Comparer);
        var byEdges = new List<List<Entry>>();
        foreach (var group in sized)
        {
            var split = new Dictionary<string, List<Entry>>();
            foreach (var entry in group)
            {
                if (isCancelled()) return result;
                string edges;
                if (Cached(entry, known) is { Edges: { } stored } fingerprint)
                {
                    edges = stored;
                    entry.Full = fingerprint.Full;
                }
                else
                {
                    try { edges = FileHasher.Sha256Edges(entry.Path, entry.Size, EdgeBytes); }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { continue; }
                    long count = Math.Min(entry.Size, (long)EdgeBytes * 2);
                    result.ReadBytes += count;
                    read += count;
                }
                entry.Edges = edges;
                printed[entry.Path] = entry;
                if (!split.TryGetValue(edges, out var list)) split[edges] = list = [];
                list.Add(entry);
            }
            current = Paths.Name(Paths.Parent(group[0].Path));
            Report();
            byEdges.AddRange(split.Values.Where(l => l.Count > 1));
        }

        // 3. Содержимое целиком — только у совпавших по краям.
        foreach (var group in byEdges)
        {
            var split = new Dictionary<string, List<Entry>>();
            foreach (var entry in group)
            {
                if (isCancelled()) return result;
                string full;
                if (entry.Full is { } knownFull) full = knownFull;
                else if (entry.Size <= (long)EdgeBytes * 2 && entry.Edges is { } edges) full = edges;
                else
                {
                    current = Paths.Name(entry.Path);
                    Report();
                    try
                    {
                        full = FileHasher.Sha256(entry.Path, isCancelled, n =>
                        {
                            read += n;
                            Report();
                        });
                    }
                    catch (OperationCanceledException) { return result; }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { continue; }
                    result.ReadBytes += entry.Size;
                }
                entry.Full = full;
                printed[entry.Path] = entry;
                if (!split.TryGetValue(full, out var list)) split[full] = list = [];
                list.Add(entry);
            }
            foreach (var (hash, same) in split)
                if (same.Count > 1) result.Groups.Add(new DuplicateGroup(hash, same[0].Size, Copies(same, rules)));
        }

        result.Fingerprints = printed.Values.Select(e => new Fingerprint(e.Path, e.Size, e.ModifiedStamp, e.Inode, e.Edges, e.Full))
                                     .OrderBy(f => f.Path, StringComparer.Ordinal).ToList();
        result.Groups.Sort((a, b) =>
        {
            long left = Savings(a), right = Savings(b);
            return left != right ? right.CompareTo(left) : string.CompareOrdinal(a.Id, b.Id);
        });
        result.Completed = true;
        return result;
    }

    /// <summary>Сколько освободится, если оставить одну копию.</summary>
    public static long Savings(DuplicateGroup group) => group.Copies.Select(c => c.Allocated).OrderBy(b => b).SkipLast(1).Sum();

    // MARK: Обход

    List<Entry>? Walk(IEnumerable<string> roots, Func<bool> isCancelled, ref int files, ref string current, Action report)
    {
        var entries = new List<Entry>();
        var seen = new HashSet<string>(Paths.Comparer);
        foreach (var root in roots)
        {
            // Корень проверяется так же, как вложенные папки: git-репозиторий прямо в домашней папке
            // обходился бы целиком, и файл проекта мог бы стать «лишней копией».
            if (IsSkipped(root)) continue;
            var rootDevice = FileSystem.Stat(root)?.VolumeSerial;
            long cluster = Volumes.ClusterSize(root);
            current = Paths.Name(root);
            report();
            var pending = new Stack<string>();
            pending.Push(root);
            while (pending.TryPop(out var directory))
            {
                List<DirItem> items;
                try { items = FileSystem.List(directory); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { continue; }
                foreach (var item in items)
                {
                    if (isCancelled()) return null;
                    // Скрытые пропускаются целиком: там настройки программ, а не копии человека.
                    if (item.IsLink || item.IsHidden || item.Name.StartsWith('.')) continue;
                    var path = Path.Combine(directory, item.Name);
                    if (item.IsDirectory)
                    {
                        if (!IsSkipped(path)) pending.Push(path);
                        continue;
                    }
                    files++;
                    if (files % 500 == 0)
                    {
                        current = Paths.Name(directory);
                        report();
                    }
                    if (item.Size < MinimumBytes || !seen.Add(path)) continue;
                    // Файл без данных на этом компьютере — в облаке: чтение скачало бы его, а удаление копии места не освободит.
                    if (item.IsCloudOnly) continue;
                    long allocated = FileSystem.Allocated(path, item.Size, item.Attributes, cluster);
                    if (allocated <= 0) continue;
                    entries.Add(new Entry
                    {
                        Path = path, Size = item.Size, Allocated = allocated, Modified = item.Modified, Created = item.Created, Device = rootDevice,
                    });
                }
            }
        }
        return entries;
    }

    internal bool IsSkipped(string directory)
    {
        var name = Paths.Name(directory);
        if (SkippedFolders.Contains(name)) return true;
        if (SafetyRules.IsRegisteredBundle(name)) return true;
        // Окружения Python: pip и conda кладут в каждое свою копию библиотек, и удалённая «копия» ломает окружение.
        if (name.Equals("site-packages", Paths.Comparison) || name.Equals("dist-packages", Paths.Comparison)) return true;
        foreach (var marker in new[] { "pyvenv.cfg", "conda-meta" })
            if (FileSystem.Exists(Path.Combine(directory, marker))) return true;
        // Проект с git: одинаковые файлы в нём — часть проекта, и о нём заботится git.
        return FileSystem.Exists(Path.Combine(directory, ".git"));
    }

    /// <summary>Номер файла и клон: одно и то же содержимое под двумя именами (жёсткая ссылка) — это один файл,
    /// а не две копии. Файлы с другого тома, подключённого внутри домашней папки, отбрасываются.</summary>
    List<Entry> Probe(List<Entry> group)
    {
        var result = new List<Entry>();
        var files = new HashSet<(long, long)>();
        foreach (var entry in group)
        {
            if (FileSystem.Stat(entry.Path) is not { IsRegularFile: true } stat) continue;
            long device = stat.VolumeSerial;
            if (entry.Device is { } root && root != device) continue;
            if (!files.Add((device, stat.FileIndex))) continue;
            entry.Device = device;
            entry.Inode = stat.FileIndex;
            entry.Clone = ContentIdentifier(entry.Path);
            result.Add(entry);
        }
        return result;
    }

    static Fingerprint? Cached(Entry entry, IReadOnlyDictionary<string, Fingerprint> known) =>
        known.TryGetValue(entry.Path, out var stored) && stored.Size == entry.Size && stored.Modified == entry.ModifiedStamp && stored.Inode == entry.Inode
            ? stored : null;

    List<DuplicateCopy> Copies(List<Entry> same, SafetyRules rules)
    {
        var clones = new Dictionary<(long, long), int>();
        foreach (var entry in same)
            if (entry.Clone is { } clone && entry.Device is { } device) clones[(device, clone)] = clones.GetValueOrDefault((device, clone)) + 1;
        return same.OrderBy(e => e.Path, StringComparer.Ordinal).Select(entry =>
        {
            int shared = entry.Clone is { } clone && entry.Device is { } device ? clones.GetValueOrDefault((device, clone)) : 0;
            var ext = Paths.Extension(entry.Path);
            return new DuplicateCopy(entry.Path, entry.Allocated, entry.Modified, entry.Created, rules.PathVerdict(entry.Path), shared > 1,
                                     (ext == "vhdx" || ext == "vhd") && EncryptedImage(entry.Path));
        }).ToList();
    }

    // MARK: Сверка перед удалением

    /// <summary>Совпадают ли два файла байт в байт — прямо сейчас. Сравнивается содержимое, а не отпечаток из базы:
    /// файл могли поменять после поиска, не тронув дату. Одно и то же имя дважды (жёсткая ссылка) копией не считается.</summary>
    public static bool SameContent(string first, string second, Func<bool>? isCancelled = null, Action<int>? progress = null)
    {
        isCancelled ??= () => false;
        var a = FileSystem.Stat(first) ?? throw new FileNotFoundException(first);
        var b = FileSystem.Stat(second) ?? throw new FileNotFoundException(second);
        if (!a.IsRegularFile) throw new IOException($"«{Paths.Name(first)}» — уже не обычный файл.");
        if (!b.IsRegularFile) throw new IOException($"«{Paths.Name(second)}» — уже не обычный файл.");
        if (a.Size != b.Size) return false;
        if (a.VolumeSerial == b.VolumeSerial && a.FileIndex == b.FileIndex) return false;
        using var left = new FileStream(first, FileMode.Open, FileAccess.Read, FileShare.Read, 1, FileOptions.SequentialScan);
        using var right = new FileStream(second, FileMode.Open, FileAccess.Read, FileShare.Read, 1, FileOptions.SequentialScan);
        var one = new byte[FileHasher.ChunkSize];
        var two = new byte[FileHasher.ChunkSize];
        while (true)
        {
            if (isCancelled()) throw new OperationCanceledException();
            int readOne = left.ReadAtLeast(one, one.Length, throwOnEndOfStream: false);
            int readTwo = right.ReadAtLeast(two, two.Length, throwOnEndOfStream: false);
            if (readOne != readTwo || !one.AsSpan(0, readOne).SequenceEqual(two.AsSpan(0, readTwo))) return false;
            if (readOne == 0) return true;
            progress?.Invoke(readOne);
        }
    }
}
