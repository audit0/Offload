namespace Offload.Core;

/// <summary>Что лежит внутри папки: всё, что нужно знать до переноса.</summary>
public sealed record ContentReport
{
    public long AllocatedBytes { get; set; }
    public long LogicalBytes { get; set; }
    public int Files { get; set; }
    /// <summary>Сколько из Files — служебные файлы Проводника и Finder (desktop.ini, Thumbs.db, .DS_Store).
    /// Проводник пишет их в любой момент, в том числе между планом и переносом, поэтому сверка двух
    /// обходов считает файлы, вычтя эти с обеих сторон: иначе открытая человеком папка срывала бы перенос.</summary>
    public int ExplorerJunkFiles { get; set; }
    public int Directories { get; set; }
    /// <summary>Все ссылки: символические и точки соединения.</summary>
    public int SymlinkCount { get; set; }
    /// <summary>Из них символических: создавать такие Windows разрешает не всем.</summary>
    public int SymbolicLinks { get; set; }
    public List<string> SymlinkExamples { get; set; } = [];
    /// <summary>Разрежённые или сжатые файлы: на диске занимают меньше, чем весят.</summary>
    public int SparseFiles { get; set; }
    /// <summary>Файлы, на которые ведёт больше одного имени (жёсткие ссылки): копия сделает из них независимые файлы.</summary>
    public int HardLinkedFiles { get; set; }
    /// <summary>Объекты с дополнительными потоками NTFS, кроме служебных (Zone.Identifier).</summary>
    public int TaggedFiles { get; set; }
    /// <summary>Файлы, которых нет на этом компьютере, — только в облаке (OneDrive, iCloud).</summary>
    public int CloudOnlyFiles { get; set; }
    public long LargestFile { get; set; }
    public DateTime? NewestModification { get; set; }
    /// <summary>Первый найденный файл, зарегистрированный в программе (диск виртуальной машины и т. п.).</summary>
    public string? RegisteredBundle { get; set; }
    /// <summary>Внутри подключён другой том: его содержимое не должно уехать и удалиться вместе с папкой.</summary>
    public string? MountedVolume { get; set; }
    public bool ContainsGitRepo { get; set; }
    public int Unreadable { get; set; }
    public List<string> UnreadableExamples { get; set; } = [];
    public bool Truncated { get; set; }
    /// <summary>Что нельзя удалить: нет права на удаление. Удаление оригинала остановилось бы на нём посередине.</summary>
    public int Undeletable { get; set; }
    public List<string> UndeletableExamples { get; set; } = [];
    /// <summary>Файлы с именем «._X» рядом с файлом X — служебные двойники, которые Mac кладёт на exFAT.</summary>
    public int AppleDoubleNamed { get; set; }
    public List<string> AppleDoubleExamples { get; set; } = [];
}

public static class Inspector
{
    /// <summary>Служебные файлы Проводника и Finder: пишутся и стираются сами, пока человек смотрит в папку.</summary>
    public static readonly HashSet<string> ExplorerJunk = new(StringComparer.OrdinalIgnoreCase) { "desktop.ini", "Thumbs.db", ".DS_Store" };

    /// <summary>Потоки, которые Windows ставит сама и о потере которых человеку говорить незачем:
    /// отметка «скачано из интернета» есть почти у каждого скачанного файла.</summary>
    static readonly HashSet<string> RoutineStreams = new(StringComparer.OrdinalIgnoreCase)
    {
        ":Zone.Identifier:$DATA", ":SmartScreen:$DATA", ":encryptable:$DATA", ":{4c8cc155-6c1e-11d1-8e41-00c04fb9386d}:$DATA",
    };

    static bool HasNotableStreams(string path) => FileSystem.AlternateStreams(path).Any(s => !RoutineStreams.Contains(s));

    /// <summary>Считает содержимое. Это намеренно другой механизм, чем в TreeWalker (там — последовательный
    /// обход с открытием каждого объекта): перед удалением оригинала их результаты сверяются,
    /// и ошибка одного не пройдёт незамеченной.</summary>
    public static ContentReport Inspect(string root, int limit = 2_000_000, Func<bool>? isCancelled = null)
    {
        isCancelled ??= () => false;
        var report = new ContentReport();
        var rootPath = Paths.Trim(root);
        string Relative(string path) => Paths.Relative(path, rootPath) ?? Paths.Name(path);
        void NoteDate(DateTime? date)
        {
            if (date is { } value && (report.NewestModification is not { } newest || value > newest)) report.NewestModification = value;
        }
        void NoteRegistered(string name, string path)
        {
            if (report.RegisteredBundle == null && SafetyRules.IsRegisteredBundle(name)) report.RegisteredBundle = Relative(path);
        }
        void NoteUnreadable(string path)
        {
            report.Unreadable++;
            if (report.UnreadableExamples.Count < 5) report.UnreadableExamples.Add(Relative(path));
        }
        long cluster = Volumes.ClusterSize(rootPath);
        bool ntfs = Volumes.FileSystemName(rootPath) is "ntfs" or "refs";

        var rootStat = FileSystem.Stat(rootPath);
        if (rootStat is not { } rs)
        {
            report.Unreadable = 1;
            report.UnreadableExamples.Add(Paths.Name(rootPath));
            return report;
        }
        int seen = 0;
        var pending = new Stack<string>();

        void Visit(string path, string name, uint attributes, long size, DateTime? modified, uint tag, bool isRoot)
        {
            bool isDirectory = (attributes & Native.FILE_ATTRIBUTE_DIRECTORY) != 0;
            bool isReparse = (attributes & Native.FILE_ATTRIBUTE_REPARSE_POINT) != 0;
            if (isReparse && Native.IsNameSurrogate(tag))
            {
                var link = Reparse.Read(path);
                if (link is { IsVolumeMount: true })
                {
                    report.MountedVolume ??= Relative(path);
                    return;
                }
                report.SymlinkCount++;
                if (link is null || link.Type == LinkType.Symbolic) report.SymbolicLinks++;
                if (report.SymlinkExamples.Count < 5) report.SymlinkExamples.Add(isRoot ? name : Relative(path));
                return;
            }
            if (isReparse && tag == Native.IO_REPARSE_TAG_AF_UNIX)
            {
                NoteUnreadable(path);
                return;
            }
            if (isDirectory)
            {
                report.Directories++;
                if (name.Equals(".git", Paths.Comparison)) report.ContainsGitRepo = true;
                NoteRegistered(name, path);
                NoteDate(modified);
                if (ntfs && HasNotableStreams(path)) report.TaggedFiles++;
                pending.Push(path);
                return;
            }
            report.Files++;
            if (ExplorerJunk.Contains(name)) report.ExplorerJunkFiles++;
            if (name.StartsWith("._", StringComparison.Ordinal) && name.Length > 2
                && FileSystem.Exists(Path.Combine(Paths.Parent(path), name[2..])))
            {
                report.AppleDoubleNamed++;
                if (report.AppleDoubleExamples.Count < 5) report.AppleDoubleExamples.Add(Relative(path));
            }
            NoteRegistered(name, path);
            long allocated = FileSystem.Allocated(path, size, attributes, cluster);
            report.LogicalBytes += size;
            report.AllocatedBytes += allocated;
            report.LargestFile = Math.Max(report.LargestFile, size);
            bool cloud = (attributes & (Native.FILE_ATTRIBUTE_OFFLINE | Native.FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS
                                        | Native.FILE_ATTRIBUTE_RECALL_ON_OPEN)) != 0;
            if (cloud) report.CloudOnlyFiles++;
            else if (size > 16L << 20 && allocated + (1L << 20) < size) report.SparseFiles++;
            // Число имён файла знает только открытый файл: открываем без доступа к данным, никому не мешая.
            if (FileSystem.Stat(path) is { Links: > 1 }) report.HardLinkedFiles++;
            NoteDate(modified);
            if (ntfs && HasNotableStreams(path)) report.TaggedFiles++;
        }

        Visit(rootPath, Paths.Name(rootPath), rs.Attributes, rs.Size, rs.Modified, rs.ReparseTag, isRoot: true);
        while (pending.TryPop(out var directory))
        {
            List<DirItem> items;
            try
            {
                items = FileSystem.List(directory);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                NoteUnreadable(directory);
                continue;
            }
            foreach (var item in items)
            {
                seen++;
                if (seen > limit || isCancelled())
                {
                    report.Truncated = true;
                    return report;
                }
                Visit(Path.Combine(directory, item.Name), item.Name, item.Attributes, item.Size, item.Modified, item.ReparseTag, isRoot: false);
            }
        }
        return report;
    }
}
