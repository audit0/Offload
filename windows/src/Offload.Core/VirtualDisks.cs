using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Offload.Core;

/// <summary>Виртуальные диски Windows (virtdisk.dll): создать VHDX, подключить, отключить, растянуть, сжать —
/// и узнать, какие образы уже подключены (это можно и без прав администратора).</summary>
public static unsafe class VirtualDisks
{
    [StructLayout(LayoutKind.Sequential)]
    struct VIRTUAL_STORAGE_TYPE
    {
        public uint DeviceId;
        public Guid VendorId;
    }

    const uint VIRTUAL_STORAGE_TYPE_DEVICE_VHDX = 3;
    static readonly Guid VendorMicrosoft = new("EC984AEC-A0F9-47E9-901F-71415A66345B");

    static VIRTUAL_STORAGE_TYPE Vhdx => new() { DeviceId = VIRTUAL_STORAGE_TYPE_DEVICE_VHDX, VendorId = VendorMicrosoft };

    [StructLayout(LayoutKind.Explicit, Size = 128)]
    struct CREATE_VIRTUAL_DISK_PARAMETERS_V2
    {
        [FieldOffset(0)] public int Version;
        [FieldOffset(8)] public Guid UniqueId;
        [FieldOffset(24)] public ulong MaximumSize;
        [FieldOffset(32)] public uint BlockSizeInBytes;
        [FieldOffset(36)] public uint SectorSizeInBytes;
        [FieldOffset(40)] public uint PhysicalSectorSizeInBytes;
        [FieldOffset(48)] public IntPtr ParentPath;
        [FieldOffset(56)] public IntPtr SourcePath;
        [FieldOffset(64)] public uint OpenFlags;
    }

    [StructLayout(LayoutKind.Explicit, Size = 32)]
    struct OPEN_VIRTUAL_DISK_PARAMETERS_V2
    {
        [FieldOffset(0)] public int Version;
        [FieldOffset(8)] public int GetInfoOnly;
        [FieldOffset(12)] public int ReadOnly;
        [FieldOffset(16)] public Guid ResiliencyGuid;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ATTACH_VIRTUAL_DISK_PARAMETERS
    {
        public int Version;
        public int Reserved;
    }

    [StructLayout(LayoutKind.Explicit, Size = 16)]
    struct RESIZE_VIRTUAL_DISK_PARAMETERS
    {
        [FieldOffset(0)] public int Version;
        [FieldOffset(8)] public ulong NewSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct COMPACT_VIRTUAL_DISK_PARAMETERS
    {
        public int Version;
        public int Reserved;
    }

    [DllImport("virtdisk.dll", CharSet = CharSet.Unicode)]
    static extern int CreateVirtualDisk(ref VIRTUAL_STORAGE_TYPE type, string path, uint access, IntPtr security, uint flags,
                                        uint providerFlags, ref CREATE_VIRTUAL_DISK_PARAMETERS_V2 parameters, IntPtr overlapped,
                                        out SafeFileHandle handle);

    [DllImport("virtdisk.dll", CharSet = CharSet.Unicode)]
    static extern int OpenVirtualDisk(ref VIRTUAL_STORAGE_TYPE type, string path, uint access, uint flags,
                                      ref OPEN_VIRTUAL_DISK_PARAMETERS_V2 parameters, out SafeFileHandle handle);

    [DllImport("virtdisk.dll")]
    static extern int AttachVirtualDisk(SafeFileHandle handle, IntPtr security, uint flags, uint providerFlags,
                                        ref ATTACH_VIRTUAL_DISK_PARAMETERS parameters, IntPtr overlapped);

    [DllImport("virtdisk.dll")]
    static extern int DetachVirtualDisk(SafeFileHandle handle, uint flags, uint providerFlags);

    [DllImport("virtdisk.dll", CharSet = CharSet.Unicode)]
    static extern int GetVirtualDiskPhysicalPath(SafeFileHandle handle, ref uint size, char* buffer);

    [DllImport("virtdisk.dll")]
    static extern int ResizeVirtualDisk(SafeFileHandle handle, uint flags, ref RESIZE_VIRTUAL_DISK_PARAMETERS parameters, IntPtr overlapped);

    [DllImport("virtdisk.dll")]
    static extern int CompactVirtualDisk(SafeFileHandle handle, uint flags, ref COMPACT_VIRTUAL_DISK_PARAMETERS parameters, IntPtr overlapped);

    [DllImport("virtdisk.dll")]
    static extern int GetStorageDependencyInformation(SafeFileHandle handle, uint flags, uint size, byte* info, out uint used);

    const uint ATTACH_FLAG_NO_DRIVE_LETTER = 0x2;
    const uint GET_STORAGE_DEPENDENCY_FLAG_HOST_VOLUMES = 0x1;

    static void Check(int code, string what)
    {
        if (code != 0) throw new IOException($"{what}: {new Win32Exception(code).Message} (0x{code:X})", code);
    }

    /// <summary>Новый расширяемый VHDX: места занимает столько, сколько в нём записано.</summary>
    public static void Create(string path, long maxBytes)
    {
        var type = Vhdx;
        var parameters = new CREATE_VIRTUAL_DISK_PARAMETERS_V2
        {
            Version = 2,
            UniqueId = Guid.NewGuid(),
            MaximumSize = (ulong)maxBytes,
            // Блок 8 МБ, как полоса sparsebundle на Mac: пустой сейф занимает меньше, а растёт мельче.
            BlockSizeInBytes = 8 << 20,
            SectorSizeInBytes = 512,
            PhysicalSectorSizeInBytes = 4096,
        };
        Check(CreateVirtualDisk(ref type, path, 0, IntPtr.Zero, 0, 0, ref parameters, IntPtr.Zero, out var handle), "Не удалось создать образ");
        handle.Dispose();
    }

    public static SafeFileHandle Open(string path, bool readOnly = false)
    {
        var type = Vhdx;
        var parameters = new OPEN_VIRTUAL_DISK_PARAMETERS_V2 { Version = 2, ReadOnly = readOnly ? 1 : 0 };
        Check(OpenVirtualDisk(ref type, path, 0, 0, ref parameters, out var handle), "Не удалось открыть образ");
        return handle;
    }

    /// <summary>Подключает образ без буквы диска. Пока жив дескриптор, образ подключён; закрыли — отключился.
    /// Поэтому сейф не может остаться открытым без программы, которая за ним следит.</summary>
    public static SafeFileHandle Attach(string path)
    {
        var handle = Open(path);
        var parameters = new ATTACH_VIRTUAL_DISK_PARAMETERS { Version = 1 };
        int code = AttachVirtualDisk(handle, IntPtr.Zero, ATTACH_FLAG_NO_DRIVE_LETTER, 0, ref parameters, IntPtr.Zero);
        if (code != 0)
        {
            handle.Dispose();
            Check(code, "Не удалось подключить образ");
        }
        return handle;
    }

    public static void Detach(SafeFileHandle handle) => Check(DetachVirtualDisk(handle, 0, 0), "Не удалось отключить образ");

    /// <summary>Отключает образ, кем бы он ни был подключён.</summary>
    public static void Detach(string path)
    {
        using var handle = Open(path);
        Detach(handle);
    }

    /// <summary>Номер подключённого диска: «\\.\PhysicalDrive3» → 3.</summary>
    public static int DiskNumber(SafeFileHandle handle)
    {
        uint size = 520;
        var buffer = stackalloc char[260];
        Check(GetVirtualDiskPhysicalPath(handle, ref size, buffer), "Windows не сообщила, каким диском подключился образ");
        var path = new string(buffer);
        const string prefix = @"\\.\PhysicalDrive";
        if (!path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) || !int.TryParse(path[prefix.Length..], out var number))
            throw new IOException($"Неожиданное имя диска образа: {path}");
        return number;
    }

    public static void Resize(string path, long newSize)
    {
        using var handle = Open(path);
        var parameters = new RESIZE_VIRTUAL_DISK_PARAMETERS { Version = 1, NewSize = (ulong)newSize };
        Check(ResizeVirtualDisk(handle, 0, ref parameters, IntPtr.Zero), "Не удалось растянуть образ");
    }

    public static void Compact(string path)
    {
        using var handle = Open(path);
        var parameters = new COMPACT_VIRTUAL_DISK_PARAMETERS { Version = 1 };
        Check(CompactVirtualDisk(handle, 0, ref parameters, IntPtr.Zero), "Не удалось сжать образ");
    }

    /// <summary>Файл образа, на котором лежит том; null — том не на образе.</summary>
    public static string? BackingFile(string volumeGuidPath)
    {
        var device = volumeGuidPath.TrimEnd('\\');
        using var handle = Native.CreateFileW(device, 0, Native.FILE_SHARE_ALL, IntPtr.Zero, Native.OPEN_EXISTING, 0, IntPtr.Zero);
        if (handle.IsInvalid) return null;
        const int size = 16 * 1024;
        var buffer = stackalloc byte[size];
        *(uint*)buffer = 2;
        if (GetStorageDependencyInformation(handle, GET_STORAGE_DEPENDENCY_FLAG_HOST_VOLUMES, size, buffer, out _) != 0) return null;
        uint count = *(uint*)(buffer + 4);
        // STORAGE_DEPENDENCY_INFO_TYPE_2: флаги (4+4), тип хранилища (20), уровень (4), затем четыре указателя:
        // устройство, том-хозяин («\\?\Volume{…}» — без черты в конце), зависимый том и путь файла образа на хозяине.
        for (uint i = 0; i < count; i++)
        {
            byte* entry = buffer + 8 + i * 64;
            var host = Marshal.PtrToStringUni(*(IntPtr*)(entry + 40));
            var relative = Marshal.PtrToStringUni(*(IntPtr*)(entry + 56));
            if (string.IsNullOrEmpty(host) || string.IsNullOrEmpty(relative)) continue;
            if (!host.EndsWith('\\')) host += "\\";
            var root = Native.VolumeMountPoints(host).FirstOrDefault(m => m.Length == 3);
            if (root == null) continue;
            return Path.Combine(root, relative.TrimStart('\\'));
        }
        return null;
    }

    /// <summary>Все подключённые образы: путь к файлу → где открыт и зашифрован ли.</summary>
    public static Dictionary<string, SecretsVault.Attachment> Attached()
    {
        var result = new Dictionary<string, SecretsVault.Attachment>(Paths.Comparer);
        foreach (var volume in Native.AllVolumeGuidPaths())
        {
            var bus = Native.StorageBus(volume.TrimEnd('\\'));
            if (bus is not { bus: Native.BusType.FileBackedVirtual }) continue;
            if (BackingFile(volume) is not { } image) continue;
            var mount = Native.VolumeMountPoints(volume).FirstOrDefault(m => m.Length == 3);
            var protection = mount != null ? BitLockerShell.Protection(mount) : null;
            bool locked = protection?.IsLocked ?? mount == null;
            // Том без буквы или заблокированный: про шифрование отвечает заголовок в самом образе.
            bool encrypted = protection?.IsEncrypted ?? BitLockerHeader.Info(image)?.OpensWithPassword ?? false;
            var attachment = new SecretsVault.Attachment(locked ? null : mount, encrypted, locked);
            var key = Paths.Resolve(image);
            // У образа может быть несколько томов (служебный раздел): берём том с буквой.
            if (!result.TryGetValue(key, out var known) || known.MountPoint == null) result[key] = attachment;
        }
        return result;
    }
}
