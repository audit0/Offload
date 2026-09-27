using System.Collections.Concurrent;

namespace Offload.Core;

/// <summary>Сведения о подключённом томе, важные для переноса.</summary>
public sealed record VolumeInfo(
    string MountPoint,
    string Name,
    /// <summary>Файловая система строчными буквами: ntfs, exfat, fat32, fat, refs.</summary>
    string FsType,
    long TotalBytes,
    long AvailableBytes,
    long BlockSize,
    bool IsReadOnly,
    bool IsInternal,
    /// <summary>Том внутри зашифрованного образа — сейф. Всё, что пишется сюда, на внешнем диске
    /// лежит зашифрованным.</summary>
    bool IsEncryptedImage = false)
{
    public string Id => MountPoint;

    /// <summary>Ссылки и точки соединения хранят только NTFS и ReFS.</summary>
    public bool KeepsSymlinks => FsType is "ntfs" or "refs";
    public bool KeepsSparseFiles => FsType is "ntfs" or "refs";
    /// <summary>Атрибуты файлов («только чтение», «скрытый») хранят все файловые системы Windows.</summary>
    public bool KeepsAttributes => FsType is "ntfs" or "refs" or "exfat" or "fat32" or "fat";
    /// <summary>FAT32 не принимает файлы больше 4 ГБ.</summary>
    public long? MaxFileSize => FsType is "fat32" or "fat" ? 4L * 1024 * 1024 * 1024 - 1 : null;
    /// <summary>На exFAT и FAT, где нет расширенных атрибутов, Mac кладёт рядом с файлами служебные «._*».
    /// Диск могли подключать к Mac, поэтому на таких дисках их узнаём и обратно не возим.</summary>
    public bool MayHaveAppleDouble => FsType is "exfat" or "fat32" or "fat";

    public string FsDisplayName => FsType switch
    {
        "ntfs" => "NTFS",
        "exfat" => "exFAT",
        "fat32" => "FAT32",
        "fat" => "FAT",
        "refs" => "ReFS",
        _ => FsType,
    };

    /// <summary>Буква диска для подписи: «E:».</summary>
    public string Letter => MountPoint.Length >= 2 ? MountPoint[..2] : MountPoint;
}

public static class Volumes
{
    static readonly ConcurrentDictionary<string, long> clusters = new(Paths.Comparer);

    /// <summary>Сведения о томе, на котором лежит путь.</summary>
    public static VolumeInfo? Info(string path)
    {
        var root = Native.VolumePathName(Paths.Normalize(path));
        if (root == null) return null;
        var information = Native.VolumeInformation(root);
        if (information is not { } info) return null;
        if (!Native.GetDiskFreeSpaceExW(root, out var free, out var total, out _)) return null;
        long cluster = ClusterSize(root);
        bool isInternal = !IsExternal(root);
        var name = info.label.Length > 0 ? info.label : DefaultName(root);
        return new VolumeInfo(root, name, info.fileSystem.ToLowerInvariant(), (long)total, (long)free, cluster,
                              (info.flags & Native.FILE_READ_ONLY_VOLUME) != 0, isInternal);
    }

    static string DefaultName(string root) => $"Диск {root.TrimEnd('\\')}";

    public static long ClusterSize(string path)
    {
        var root = Native.VolumePathName(Paths.Normalize(path)) ?? Paths.Root(path);
        return clusters.GetOrAdd(root, r =>
            Native.GetDiskFreeSpaceW(r, out var sectors, out var bytes, out _, out _) ? (long)sectors * bytes : 4096);
    }

    public static string? FileSystemName(string path)
    {
        var root = Native.VolumePathName(Paths.Normalize(path));
        return root == null ? null : Native.VolumeInformation(root)?.fileSystem.ToLowerInvariant();
    }

    /// <summary>Внешний ли это диск: съёмный носитель, USB, FireWire, карта памяти или устройство,
    /// которое Windows разрешает «безопасно извлечь». Виртуальные диски (образы VHDX, в том числе сейф)
    /// внешними не считаются.</summary>
    public static bool IsExternal(string root)
    {
        var device = @"\\.\" + root.TrimEnd('\\');
        var bus = Native.StorageBus(device);
        if (bus is { bus: Native.BusType.FileBackedVirtual or Native.BusType.Virtual }) return false;
        if (bus is { removable: true }) return true;
        if (bus is { bus: Native.BusType.Usb or Native.BusType.Ieee1394 or Native.BusType.Sd or Native.BusType.Mmc }) return true;
        return Native.DeviceHotplug(device) == true;
    }

    /// <summary>Образ ли под томом (VHD, VHDX, ISO).</summary>
    public static bool IsVirtual(string root)
    {
        var bus = Native.StorageBus(@"\\.\" + root.TrimEnd('\\'));
        return bus is { bus: Native.BusType.FileBackedVirtual or Native.BusType.Virtual };
    }

    /// <summary>Внешние диски, на которые можно писать. Системный диск не бывает внешним никогда.</summary>
    public static List<VolumeInfo> External()
    {
        var system = Paths.SystemDrive;
        var result = new List<VolumeInfo>();
        foreach (var drive in DriveInfo.GetDrives())
        {
            try
            {
                if (!drive.IsReady || drive.DriveType is not (DriveType.Removable or DriveType.Fixed)) continue;
                if (Paths.Same(drive.RootDirectory.FullName, system)) continue;
                if (!IsExternal(drive.RootDirectory.FullName)) continue;
                if (Info(drive.RootDirectory.FullName) is { IsReadOnly: false } info) result.Add(info);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return result.OrderBy(v => v.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    /// <summary>Сейф как место назначения. Свободное место внутри образа — не то же самое, что место
    /// на диске, где образ лежит: разрежённый образ растёт, пока на диске есть куда, и предел
    /// в полдиска ничего не значит, если сам диск почти полон. Поэтому свободным считается
    /// меньшее из двух, за вычетом запаса на служебные данные образа.</summary>
    public static VolumeInfo? Safe(string mountedAt, VolumeInfo host)
    {
        if (Info(mountedAt) is not { } inside) return null;
        long hostRoom = Math.Max(0, host.AvailableBytes - SafeHostReserve);
        return inside with
        {
            AvailableBytes = Math.Min(inside.AvailableBytes, hostRoom),
            IsInternal = false,
            IsEncryptedImage = true,
        };
    }

    /// <summary>Блоки образа по 32 МБ и его служебные данные: оставляем на диске немного воздуха.</summary>
    public const long SafeHostReserve = 1L << 30;

    /// <summary>Зашифрован ли сам внешний диск целиком (BitLocker To Go). У незашифрованного всё,
    /// что лежит вне сейфа, читается как есть.</summary>
    public static bool IsVolumeEncrypted(VolumeInfo volume) => BitLockerShell.Protection(volume.MountPoint) is { IsEncrypted: true };

    static readonly ConcurrentDictionary<string, bool> symlinkAbility = new(Paths.Comparer);

    /// <summary>Можно ли создать символическую ссылку на этом томе: Windows разрешает это администратору
    /// или в режиме разработчика. Проверяется пробной ссылкой, один раз на том.</summary>
    public static bool CanCreateSymlinks(string directory)
    {
        var root = Native.VolumePathName(Paths.Normalize(directory)) ?? directory;
        return symlinkAbility.GetOrAdd(root, _ =>
        {
            var probe = Path.Combine(directory, ".offload-link-" + Guid.NewGuid().ToString("N"));
            try
            {
                File.CreateSymbolicLink(probe, "offload-probe-target");
                return true;
            }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
            finally
            {
                try { if (FileSystem.Exists(probe)) File.Delete(probe); } catch (IOException) { }
            }
        });
    }
}
