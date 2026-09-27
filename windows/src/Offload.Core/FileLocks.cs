using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Offload.Core;

/// <summary>Что показала проверка открытых файлов.</summary>
public sealed class LockReport
{
    /// <summary>Программы, которые держат файлы открытыми.</summary>
    public List<string> Holders { get; } = [];
    /// <summary>Сколько объектов занято.</summary>
    public int Locked { get; set; }
    /// <summary>Что удалить нельзя: нет права на удаление.</summary>
    public List<string> Denied { get; } = [];
    public int DeniedCount { get; set; }
}

/// <summary>Кто держит файлы открытыми — то, что на Mac делает lsof.
///
/// Каждый объект открывается с правом на удаление и разрешением всем остальным делать что угодно.
/// Если его держит программа, не разрешившая удаление (так открывают файлы почти все), Windows
/// отвечает «файл занят» — удалять его сейчас нельзя. Имена таких программ даёт Restart Manager.</summary>
public static class FileLocks
{
    /// <summary>null — проверить не удалось вовсе (папки нет или она не читается).</summary>
    public static LockReport? Scan(string root, Func<bool>? isCancelled = null, int limit = 2_000_000)
    {
        isCancelled ??= () => false;
        var rootPath = Paths.Trim(root);
        if (FileSystem.Stat(rootPath) is not { } rootStat) return null;
        var report = new LockReport();
        var locked = new List<string>();
        int seen = 0;

        void Probe(string path, bool isDirectory)
        {
            using var handle = Native.CreateFileW(Native.Long(path), Native.DELETE | Native.FILE_READ_ATTRIBUTES, Native.FILE_SHARE_ALL,
                                                  IntPtr.Zero, Native.OPEN_EXISTING,
                                                  Native.FILE_FLAG_OPEN_REPARSE_POINT | Native.FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
            if (!handle.IsInvalid) return;
            int code = Marshal.GetLastWin32Error();
            if (code is Native.ERROR_SHARING_VIOLATION or Native.ERROR_LOCK_VIOLATION)
            {
                report.Locked++;
                if (!isDirectory && locked.Count < 64) locked.Add(path);
            }
            else if (code == Native.ERROR_ACCESS_DENIED)
            {
                report.DeniedCount++;
                if (report.Denied.Count < 5) report.Denied.Add(Paths.Relative(path, rootPath) ?? Paths.Name(path));
            }
        }

        Probe(rootPath, rootStat.IsDirectory);
        if (rootStat.IsRegularDirectory)
        {
            var pending = new Stack<string>();
            pending.Push(rootPath);
            while (pending.TryPop(out var directory))
            {
                List<DirItem> items;
                try { items = FileSystem.List(directory); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { continue; }
                foreach (var item in items)
                {
                    if (++seen > limit || isCancelled()) break;
                    var path = Path.Combine(directory, item.Name);
                    Probe(path, item.IsDirectory);
                    if (item.IsDirectory && !item.IsLink) pending.Push(path);
                }
            }
        }
        if (report.Locked > 0)
        {
            // Занятые только самим Offload (например, его же проверкой) — не занятые.
            var names = Holders(locked);
            if (names == null) report.Holders.Add("другая программа");
            else if (names.Count > 0) report.Holders.AddRange(names);
            else if (locked.Count == report.Locked) report.Locked = 0;
            else report.Holders.Add("другая программа");
        }
        return report;
    }

    /// <summary>Какие программы держат эти файлы — по Restart Manager. Сам Offload не в счёт.
    /// null — Restart Manager не ответил; пустой список — файлы не держит никто, кроме Offload.</summary>
    public static unsafe List<string>? Holders(IReadOnlyList<string> files)
    {
        var result = new SortedSet<string>(StringComparer.CurrentCultureIgnoreCase);
        if (files.Count == 0) return null;
        var key = stackalloc char[64];
        if (Native.RmStartSession(out var session, 0, key) != 0) return null;
        try
        {
            if (Native.RmRegisterResources(session, (uint)files.Count, files.ToArray(), 0, IntPtr.Zero, 0, IntPtr.Zero) != 0) return null;
            uint count = 0;
            int status = Native.RmGetList(session, out var needed, ref count, null, out _);
            if (status != Native.ERROR_MORE_DATA && status != 0) return null;
            if (needed == 0) return null;
            var info = new Native.RM_PROCESS_INFO[needed];
            count = needed;
            if (Native.RmGetList(session, out _, ref count, info, out _) != 0) return null;
            int self = Environment.ProcessId;
            foreach (var process in info.Take((int)count))
            {
                if (process.Process.ProcessId == self) continue;
                var name = process.AppName;
                if (string.IsNullOrWhiteSpace(name))
                {
                    try { name = Process.GetProcessById(process.Process.ProcessId).ProcessName; }
                    catch (ArgumentException) { continue; }
                }
                result.Add(name);
            }
        }
        finally { Native.RmEndSession(session); }
        return [.. result];
    }
}
