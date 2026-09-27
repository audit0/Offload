using System.Collections.Concurrent;
using System.Diagnostics;
using System.Management;
using System.Runtime.InteropServices;

namespace Offload.Core;

public enum MemoryPressure { Unknown, Normal, Warning, Critical }

public static class MemoryPressureText
{
    public static string Title(this MemoryPressure pressure) => pressure switch
    {
        MemoryPressure.Normal => "Нормальное",
        MemoryPressure.Warning => "Повышенное",
        MemoryPressure.Critical => "Критическое",
        _ => "Неизвестно",
    };
}

public sealed record AppMemory(string Name, ulong Bytes, int Processes)
{
    public string Id => Name;
}

/// <summary>Память компьютера. «Swap» на Windows — файл подкачки, «сжатое» — то, что держит процесс Memory Compression.</summary>
public sealed record MemorySnapshot(ulong PhysicalBytes, ulong FreeBytes, ulong CompressedBytes, ulong SwapUsedBytes, ulong SwapTotalBytes,
                                    MemoryPressure Pressure, TimeSpan Uptime, IReadOnlyList<AppMemory> Apps);

public static class MemoryStats
{
    public const string VirtualMachinesName = "Виртуальные машины (WSL, Docker, Hyper-V)";

    [StructLayout(LayoutKind.Sequential)]
    struct MEMORYSTATUSEX
    {
        public uint Length;
        public uint MemoryLoad;
        public ulong TotalPhys;
        public ulong AvailPhys;
        public ulong TotalPageFile;
        public ulong AvailPageFile;
        public ulong TotalVirtual;
        public ulong AvailVirtual;
        public ulong AvailExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX status);

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_MEMORY_COUNTERS_EX2
    {
        public uint cb;
        public uint PageFaultCount;
        public nuint PeakWorkingSetSize;
        public nuint WorkingSetSize;
        public nuint QuotaPeakPagedPoolUsage;
        public nuint QuotaPagedPoolUsage;
        public nuint QuotaPeakNonPagedPoolUsage;
        public nuint QuotaNonPagedPoolUsage;
        public nuint PagefileUsage;
        public nuint PeakPagefileUsage;
        public nuint PrivateUsage;
        public nuint PrivateWorkingSetSize;
        public ulong SharedCommitUsage;
    }

    [DllImport("psapi.dll", SetLastError = true)]
    static extern bool GetProcessMemoryInfo(IntPtr process, ref PROCESS_MEMORY_COUNTERS_EX2 counters, uint size);

    static DateTime? bootTime;

    public static MemorySnapshot Snapshot(int top = 8)
    {
        var status = new MEMORYSTATUSEX { Length = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
        bool ok = GlobalMemoryStatusEx(ref status);
        var (swapUsed, swapTotal) = PageFile();
        // Своего «давления памяти» у Windows нет. Судим по загрузке: выше 80 % система начинает
        // выгружать программы на диск, выше 90 % — работать заметно медленнее.
        var pressure = !ok ? MemoryPressure.Unknown : status.MemoryLoad >= 90 ? MemoryPressure.Critical
                     : status.MemoryLoad >= 80 ? MemoryPressure.Warning : MemoryPressure.Normal;
        return new MemorySnapshot(ok ? status.TotalPhys : 0, ok ? status.AvailPhys : 0, CompressedBytes(), swapUsed, swapTotal, pressure,
                                  Uptime(), TopApps(top));
    }

    /// <summary>Файл подкачки: сколько занято и сколько отведено.</summary>
    static (ulong used, ulong total) PageFile()
    {
        try
        {
            using var searcher = new ManagementObjectSearcher("SELECT CurrentUsage, AllocatedBaseSize FROM Win32_PageFileUsage");
            ulong used = 0, total = 0;
            foreach (ManagementObject item in searcher.Get())
            {
                used += Convert.ToUInt64(item["CurrentUsage"]) << 20;
                total += Convert.ToUInt64(item["AllocatedBaseSize"]) << 20;
                item.Dispose();
            }
            return (used, total);
        }
        catch (Exception ex) when (ex is ManagementException or COMException or UnauthorizedAccessException) { return (0, 0); }
    }

    static ulong CompressedBytes()
    {
        try
        {
            foreach (var process in Process.GetProcessesByName("Memory Compression"))
                using (process) return (ulong)process.WorkingSet64;
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        return 0;
    }

    /// <summary>Время с загрузки Windows, как «Время работы» в диспетчере задач.</summary>
    static TimeSpan Uptime()
    {
        if (bootTime == null)
        {
            try
            {
                using var searcher = new ManagementObjectSearcher("SELECT LastBootUpTime FROM Win32_OperatingSystem");
                foreach (ManagementObject item in searcher.Get())
                {
                    bootTime = ManagementDateTimeConverter.ToDateTime((string)item["LastBootUpTime"]).ToUniversalTime();
                    item.Dispose();
                }
            }
            catch (Exception ex) when (ex is ManagementException or COMException) { }
        }
        return bootTime is { } boot ? DateTime.UtcNow - boot : TimeSpan.FromMilliseconds(Environment.TickCount64);
    }

    static readonly ConcurrentDictionary<string, string> names = new(Paths.Comparer);

    const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000, PROCESS_VM_READ = 0x10;

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int id);

    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, char[] name, ref uint size);

    /// <summary>Память по программам: частный рабочий набор (как в диспетчере задач), сгруппированный по программе.
    /// Если процесс не отдаёт рабочий набор (чужая учётная запись), берётся его частная выделенная память.</summary>
    static List<AppMemory> TopApps(int limit)
    {
        var totals = new Dictionary<string, (ulong bytes, int processes)>();
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                if (process.Id is 0 or 4) continue;
                ulong bytes;
                try { bytes = (ulong)process.PrivateMemorySize64; }
                catch (InvalidOperationException) { continue; }
                string? path = null;
                var handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, false, process.Id);
                if (handle == IntPtr.Zero) handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, process.Id);
                if (handle != IntPtr.Zero)
                {
                    var counters = new PROCESS_MEMORY_COUNTERS_EX2 { cb = (uint)Marshal.SizeOf<PROCESS_MEMORY_COUNTERS_EX2>() };
                    if (GetProcessMemoryInfo(handle, ref counters, counters.cb) && counters.PrivateWorkingSetSize > 0) bytes = counters.PrivateWorkingSetSize;
                    var buffer = new char[1024];
                    uint size = (uint)buffer.Length;
                    if (QueryFullProcessImageNameW(handle, 0, buffer, ref size)) path = new string(buffer, 0, (int)size);
                    CloseHandle(handle);
                }
                string name;
                try { name = AppName(process.ProcessName, path); }
                catch (InvalidOperationException) { continue; }
                var current = totals.GetValueOrDefault(name);
                totals[name] = (current.bytes + bytes, current.processes + 1);
            }
        }
        return totals.Select(t => new AppMemory(t.Key, t.Value.bytes, t.Value.processes)).OrderByDescending(a => a.Bytes).Take(limit).ToList();
    }

    public static string AppName(string processName, string? path)
    {
        if (processName.StartsWith("vmmem", StringComparison.OrdinalIgnoreCase) || processName.Equals("vmwp", StringComparison.OrdinalIgnoreCase)
            || processName.Equals("VBoxHeadless", StringComparison.OrdinalIgnoreCase) || processName.Equals("vmware-vmx", StringComparison.OrdinalIgnoreCase))
            return VirtualMachinesName;
        if (path == null) return processName;
        return names.GetOrAdd(path, p =>
        {
            try
            {
                var info = FileVersionInfo.GetVersionInfo(p);
                // У системных программ название продукта — «Операционная система Microsoft Windows»: оно ни о чём не говорит.
                bool system = info.ProductName is { } product && (product.Contains("Windows", StringComparison.OrdinalIgnoreCase)
                                                                  && product.Contains("Microsoft", StringComparison.OrdinalIgnoreCase));
                if (!system && info.ProductName is { Length: > 0 } productName) return productName;
                return info.FileDescription is { Length: > 0 } description ? description : processName;
            }
            catch (FileNotFoundException) { return processName; }
        });
    }

    static readonly HashSet<string> Browsers = new(StringComparer.OrdinalIgnoreCase)
    {
        "Google Chrome", "Microsoft Edge", "Firefox", "Mozilla Firefox", "Opera", "Opera Internet Browser", "Brave", "Brave Browser",
        "Yandex", "Яндекс Браузер", "Vivaldi", "Arc",
    };

    /// <summary>Советы на человеческом языке по текущему состоянию памяти.</summary>
    public static List<string> Advice(MemorySnapshot snapshot)
    {
        var tips = new List<string>();
        int days = (int)snapshot.Uptime.TotalDays;
        if (snapshot.SwapUsedBytes > snapshot.PhysicalBytes / 2 && days >= 2)
            tips.Add($"Перезагрузите компьютер: в файле подкачки {Format.Memory(snapshot.SwapUsedBytes)}, и сам он не освободится. Компьютер работает без перезагрузки {days} дн. Именно «Перезагрузка», а не «Завершение работы»: при быстром запуске выключение память не сбрасывает.");
        if (snapshot.Pressure is MemoryPressure.Warning or MemoryPressure.Critical)
            tips.Add("Оперативной памяти не хватает — закройте программы, которыми сейчас не пользуетесь.");
        foreach (var app in snapshot.Apps)
        {
            if (app.Name == VirtualMachinesName && app.Bytes > 2UL << 30)
                tips.Add($"Виртуальные машины занимают {Format.Memory(app.Bytes)}. Закройте Docker Desktop или выключите WSL (wsl --shutdown), если они сейчас не нужны.");
            else if (Browsers.Contains(app.Name) && app.Bytes > 3UL << 30)
                tips.Add($"{app.Name} занимает {Format.Memory(app.Bytes)} — закройте лишние вкладки.");
        }
        return tips;
    }
}
