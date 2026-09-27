using Microsoft.Win32;

namespace Offload.Core;

/// <summary>Крупные данные программ, место из-под которых освобождается не переносом, а средствами самих
/// программ: OffLoadAI показывает, как это сделать.</summary>
public enum AppDataKind { Docker, VirtualMachines }

public static class AppDataKinds
{
    /// <summary>К чему относится объект: папка Docker Desktop, машины WSL, VirtualBox, VMware или диск машины.</summary>
    public static AppDataKind? Of(string path, string home)
    {
        var relative = Paths.Relative(Paths.Normalize(path), home);
        if (relative == null) return null;
        var parts = Paths.Parts(relative);
        bool Under(params string[] prefix) => parts.Length >= prefix.Length && prefix.Select((p, i) => parts[i].Equals(p, Paths.Comparison)).All(x => x);
        if (Under("AppData", "Local", "Docker")) return AppDataKind.Docker;
        if (Under("AppData", "Local", "wsl") || Under("VirtualBox VMs") || Under("Documents", "Virtual Machines")) return AppDataKind.VirtualMachines;
        if (Under("AppData", "Local", "Packages") && parts.Length >= 4 && parts[3].Contains("Canonical", Paths.Comparison)) return AppDataKind.VirtualMachines;
        if (VirtualMachines.IsMachineFile(path)) return AppDataKind.VirtualMachines;
        return null;
    }
}

public enum MachineKind { Wsl, VirtualBox, VMware }

/// <summary>Виртуальная машина: дистрибутив WSL, машина VirtualBox или VMware.</summary>
public sealed record VirtualMachine(
    string Name,
    MachineKind Kind,
    /// <summary>Папка машины или файл диска WSL.</summary>
    string Path,
    /// <summary>Сколько занимает на диске сейчас.</summary>
    long Bytes,
    /// <summary>Полный объём файлов. Диски машин растут по мере записи, а на exFAT и FAT займут полный объём.</summary>
    long LogicalBytes,
    /// <summary>Самый большой файл — обычно диск машины. FAT32 больше 4 ГБ в одном файле не примет.</summary>
    long LargestFile,
    DateTime? Modified)
{
    public string Id => Path;

    public string KindTitle => Kind switch
    {
        MachineKind.Wsl => "WSL",
        MachineKind.VirtualBox => "VirtualBox",
        _ => "VMware",
    };
}

public static class VirtualMachines
{
    static readonly HashSet<string> DiskExtensions = new(StringComparer.OrdinalIgnoreCase) { "vhdx", "vhd", "vdi", "vmdk", "vbox", "vmx" };

    public static bool IsMachineFile(string path) => DiskExtensions.Contains(Paths.Extension(path)) && !path.StartsWith(Paths.Public, Paths.Comparison)
        && !Paths.Name(path).Equals(SecretsVault.SafeImageName, Paths.Comparison);

    /// <summary>Все машины этого пользователя по убыванию размера.</summary>
    public static List<VirtualMachine> List(string home, Func<bool>? isCancelled = null)
    {
        var machines = new List<VirtualMachine>();
        machines.AddRange(Wsl());
        machines.AddRange(InFolder(System.IO.Path.Combine(home, "VirtualBox VMs"), "*.vbox", MachineKind.VirtualBox, isCancelled));
        machines.AddRange(InFolder(System.IO.Path.Combine(home, "Documents", "Virtual Machines"), "*.vmx", MachineKind.VMware, isCancelled));
        return machines.OrderByDescending(m => m.Bytes).ThenBy(m => m.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    /// <summary>Дистрибутивы WSL — из реестра, как их знает сама WSL. Служебные дистрибутивы Docker Desktop
    /// не показываются: их место освобождается в разделе «Docker».</summary>
    public static List<VirtualMachine> Wsl()
    {
        var result = new List<VirtualMachine>();
        using var root = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Lxss");
        if (root == null) return result;
        foreach (var id in root.GetSubKeyNames())
        {
            using var key = root.OpenSubKey(id);
            if (key?.GetValue("DistributionName") is not string name || key.GetValue("BasePath") is not string basePath) continue;
            if (name.StartsWith("docker-desktop", StringComparison.OrdinalIgnoreCase)) continue;
            var folder = basePath.StartsWith(@"\\?\", StringComparison.Ordinal) ? basePath[4..] : basePath;
            var disk = System.IO.Path.Combine(folder, key.GetValue("VhdFileName") as string ?? "ext4.vhdx");
            if (FileSystem.Stat(disk) is not { } stat) continue;
            long allocated = FileSystem.Allocated(disk, stat.Size, stat.Attributes, 0);
            result.Add(new VirtualMachine(name, MachineKind.Wsl, disk, allocated, stat.Size, stat.Size, stat.Modified));
        }
        return result;
    }

    static List<VirtualMachine> InFolder(string folder, string marker, MachineKind kind, Func<bool>? isCancelled)
    {
        var result = new List<VirtualMachine>();
        if (!Directory.Exists(folder)) return result;
        try
        {
            foreach (var directory in Directory.EnumerateDirectories(folder))
            {
                if (!Directory.EnumerateFiles(directory, marker).Any()) continue;
                result.Add(Machine(directory, kind, isCancelled));
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        return result;
    }

    public static VirtualMachine Machine(string path, MachineKind kind, Func<bool>? isCancelled = null)
    {
        var report = Inspector.Inspect(path, isCancelled: isCancelled);
        return new VirtualMachine(Paths.Name(path), kind, path, report.AllocatedBytes, report.LogicalBytes, report.LargestFile, report.NewestModification);
    }
}
