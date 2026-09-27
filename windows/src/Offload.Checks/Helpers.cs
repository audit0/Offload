using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using Offload.Core;

namespace Offload.Checks;

/// <summary>Общее для проверок: ссылки, жёсткие ссылки, разрежённые файлы, чужой процесс, держащий файл,
/// подделанные записи журнала и прямой доступ к SQLite.</summary>
static class Helpers
{
    /// <summary>Проверки на настоящих образах дисков: нужны права администратора (подключение VHDX).</summary>
    public static bool Integration => !Harness.Env("OFFLOAD_SKIP_INTEGRATION") && VaultOps.IsElevated;

    public static string Room(string name)
    {
        var path = Path.Combine(Harness.Scratch, name);
        Directory.CreateDirectory(path);
        return path;
    }

    public static string? Read(string path)
    {
        try { return File.ReadAllText(path); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; }
    }

    public static bool Exists(string path) => FileSystem.Exists(path);

    public static bool IsMove(Exception ex, MoveErrorKind kind) => ex is MoveException m && m.Kind == kind;
    public static bool IsCopy(Exception ex, CopyErrorKind kind) => ex is CopyException c && c.Kind == kind;

    /// <summary>Символические ссылки Windows разрешает администратору и в режиме разработчика.</summary>
    public static bool CanSymlink => Volumes.CanCreateSymlinks(Harness.Scratch);

    public static void Junction(string path, string target)
    {
        Directory.CreateDirectory(Paths.Parent(path));
        Reparse.CreateJunction(path, target);
    }

    public static void FileLink(string path, string target)
    {
        Directory.CreateDirectory(Paths.Parent(path));
        File.CreateSymbolicLink(path, target);
    }

    public static void DirectoryLink(string path, string target)
    {
        Directory.CreateDirectory(Paths.Parent(path));
        Directory.CreateSymbolicLink(path, target);
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateHardLinkW(string newName, string existing, IntPtr security);

    public static void HardLink(string existing, string newName)
    {
        if (!CreateHardLinkW(newName, existing, IntPtr.Zero)) throw Native.LastError();
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetShortPathNameW(string longPath, StringBuilder shortPath, uint size);

    public static string? ShortPath(string path)
    {
        var buffer = new StringBuilder(1024);
        uint length = GetShortPathNameW(path, buffer, (uint)buffer.Capacity);
        return length == 0 || length >= buffer.Capacity ? null : buffer.ToString();
    }

    /// <summary>Разрежённый файл: весит length, а на диске почти ничего.</summary>
    public static unsafe void Sparse(string path, long length)
    {
        Directory.CreateDirectory(Paths.Parent(path));
        using (var stream = new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite))
        {
            const uint FSCTL_SET_SPARSE = 0x000900C4;
            if (!Native.DeviceIoControl(stream.SafeFileHandle, FSCTL_SET_SPARSE, null, 0, null, 0, out _, IntPtr.Zero))
                throw Native.LastError();
            stream.SetLength(length);
        }
    }

    public static FileAttributes Attributes(string path) => File.GetAttributes(path);

    public static bool Has(string path, FileAttributes flag) => (File.GetAttributes(path) & flag) != 0;

    public static void Add(string path, FileAttributes flag) => File.SetAttributes(path, File.GetAttributes(path) | flag);

    /// <summary>Диск назначения для расчётов, без обращения к диску.</summary>
    public static VolumeInfo Fake(string fs, long free = 100L << 30, bool readOnly = false, string mount = @"Q:\", string name = "Пробный",
                                  long block = 4096) =>
        new(mount, name, fs, 500L << 30, free, block, readOnly, false);

    /// <summary>Запись о ручном переносе — как ImportRecord, но без требования «внешний диск»: пробный образ VHDX
    /// Windows внешним диском не считает (и правильно — так же выглядит и сейф).</summary>
    public static MoveRecord Manual(SafeMover mover, string archived, string original, VolumeInfo volume, string? note = null)
    {
        var content = Inspector.Inspect(archived);
        var record = new MoveRecord
        {
            OriginalPath = Paths.Normalize(original),
            ArchivedPath = Paths.Normalize(archived),
            OriginalRemoved = true,
            Note = note,
            VolumeName = volume.Name,
            Files = content.Files,
            Bytes = content.LogicalBytes,
        };
        mover.Validate(record);
        Journal.Save(record, volume);
        return record;
    }

    /// <summary>Другая программа держит файл открытым без права на удаление — как это делает почти любая
    /// программа. Сам Offload себя в «занятых» не считает, поэтому держит отдельный процесс PowerShell.</summary>
    public sealed class Holder : IDisposable
    {
        readonly Process process;

        public Holder(string path)
        {
            var script = $"$f = [IO.File]::Open('{path.Replace("'", "''")}', 'Open', 'Read', 'Read'); [Console]::Out.WriteLine('open'); [Console]::Out.Flush(); Start-Sleep -Seconds 120; $f.Close()";
            var info = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"))
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-Command", script }) info.ArgumentList.Add(argument);
            process = Process.Start(info)!;
            var line = Task.Run(() => process.StandardOutput.ReadLine());
            if (!line.Wait(TimeSpan.FromSeconds(30)) || line.Result != "open")
            {
                Dispose();
                throw new IOException("процесс, держащий файл, не запустился: " + process.StandardError.ReadToEnd());
            }
        }

        public void Dispose()
        {
            try { if (!process.HasExited) process.Kill(true); } catch (InvalidOperationException) { }
            process.WaitForExit(5000);
            process.Dispose();
        }
    }

    /// <summary>Процесс, которого уже нет: номер завершившегося процесса.</summary>
    public static int DeadPid()
    {
        using var process = Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe"), "/c exit 0")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
        })!;
        process.WaitForExit();
        return process.Id;
    }

    /// <summary>Прямой доступ к SQLite — чтобы положить базу старой версии, как её оставил прошлый Offload.</summary>
    public static class RawSql
    {
        const string Library = "winsqlite3.dll";
        [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_open_v2(byte[] name, out IntPtr db, int flags, IntPtr vfs);
        [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_close(IntPtr db);
        [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_exec(IntPtr db, byte[] sql, IntPtr callback, IntPtr arg, IntPtr error);
        [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int length, out IntPtr statement, IntPtr tail);
        [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_step(IntPtr statement);
        [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_finalize(IntPtr statement);
        [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern long sqlite3_column_int64(IntPtr statement, int column);

        static byte[] Utf8(string text) => [.. Encoding.UTF8.GetBytes(text), 0];

        static IntPtr Open(string path)
        {
            if (sqlite3_open_v2(Utf8(path), out var db, 0x2 | 0x4, IntPtr.Zero) != 0) throw new IOException("база не открылась");
            return db;
        }

        public static bool Exec(string path, string sql)
        {
            var db = Open(path);
            try { return sqlite3_exec(db, Utf8(sql), IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) == 0; }
            finally { sqlite3_close(db); }
        }

        public static long Scalar(string path, string sql)
        {
            var db = Open(path);
            try
            {
                if (sqlite3_prepare_v2(db, Utf8(sql), -1, out var statement, IntPtr.Zero) != 0) return -1;
                try { return sqlite3_step(statement) == 100 ? sqlite3_column_int64(statement, 0) : -1; }
                finally { sqlite3_finalize(statement); }
            }
            finally { sqlite3_close(db); }
        }
    }
}
