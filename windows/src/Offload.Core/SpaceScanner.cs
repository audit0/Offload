namespace Offload.Core;

/// <summary>Строка обзора «что занимает место».</summary>
public sealed record SpaceItem(string Path, long Bytes, DateTime? Modified, bool IsDirectory, bool AccessDenied, Verdict Verdict, bool IsMeasured)
{
    public string Id => Path;
    public string Name => Paths.Name(Path);
}

public static class SpaceScanner
{
    /// <summary>Содержимое папки без ссылок и точек соединения («Application Data», «My Music»), служебных
    /// файлов Проводника и системных скрытых файлов вроде реестра пользователя (NTUSER.DAT).</summary>
    public static List<string> Children(string directory)
    {
        try
        {
            return FileSystem.List(directory)
                .Where(i => !i.IsLink && !Inspector.ExplorerJunk.Contains(i.Name) && !i.Name.StartsWith("._", StringComparison.Ordinal))
                .Where(i => (i.Attributes & (Native.FILE_ATTRIBUTE_HIDDEN | Native.FILE_ATTRIBUTE_SYSTEM)) != (Native.FILE_ATTRIBUTE_HIDDEN | Native.FILE_ATTRIBUTE_SYSTEM))
                .Select(i => Path.Combine(directory, i.Name)).ToList();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return []; }
    }

    /// <summary>Занятое на диске: обход без перехода по ссылкам и в другие тома — как du -sx на Mac.</summary>
    public static SpaceItem Measure(string path, SafetyRules rules, Func<bool>? isCancelled = null)
    {
        var stat = FileSystem.Stat(path);
        bool denied = stat == null;
        long bytes = 0;
        if (stat is { } s)
        {
            long cluster = Volumes.ClusterSize(path);
            if (!s.IsDirectory) bytes = FileSystem.Allocated(path, s.Size, s.Attributes, cluster);
            else
            {
                var pending = new Stack<string>();
                pending.Push(path);
                while (pending.TryPop(out var directory))
                {
                    if (isCancelled?.Invoke() == true) break;
                    List<DirItem> items;
                    try { items = FileSystem.List(directory); }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                    {
                        denied = true;
                        continue;
                    }
                    foreach (var item in items)
                    {
                        if (item.IsLink) continue;
                        var child = Path.Combine(directory, item.Name);
                        if (item.IsDirectory) pending.Push(child);
                        else bytes += FileSystem.Allocated(child, item.Size, item.Attributes, cluster);
                    }
                }
            }
        }
        return new SpaceItem(path, bytes, stat?.Modified, stat?.IsDirectory ?? false, denied, rules.PathVerdict(path), true);
    }

    /// <summary>Строка без размера — показывается сразу, чтобы список не прыгал, пока размер считается.</summary>
    public static SpaceItem Placeholder(string path, SafetyRules rules)
    {
        var stat = FileSystem.Stat(path);
        return new SpaceItem(path, 0, stat?.Modified, stat?.IsDirectory ?? false, false, rules.PathVerdict(path), false);
    }

    /// <summary>Измеряет объекты параллельно и отдаёт каждый по готовности.</summary>
    public static async Task Scan(IReadOnlyList<string> paths, SafetyRules rules, Func<bool> isCancelled, Action<SpaceItem> onItem, int concurrency = 4)
    {
        using var gate = new SemaphoreSlim(concurrency);
        var tasks = paths.Select(async path =>
        {
            await gate.WaitAsync();
            try
            {
                if (isCancelled()) return;
                var item = await Task.Run(() => Measure(path, rules, isCancelled));
                if (!isCancelled()) onItem(item);
            }
            finally { gate.Release(); }
        });
        await Task.WhenAll(tasks);
    }
}
