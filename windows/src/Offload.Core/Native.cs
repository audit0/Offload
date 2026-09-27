using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Offload.Core;

/// <summary>Вызовы Win32, которых нет в .NET: открытие без перехода по ссылке, номер файла,
/// занятое на диске, потоки NTFS, тома.</summary>
internal static unsafe class Native
{
    public const uint GENERIC_READ = 0x80000000;
    public const uint GENERIC_WRITE = 0x40000000;
    public const uint DELETE = 0x00010000;
    public const uint FILE_READ_ATTRIBUTES = 0x80;
    public const uint FILE_WRITE_ATTRIBUTES = 0x100;
    public const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, FILE_SHARE_DELETE = 4;
    public const uint FILE_SHARE_ALL = 7;
    public const uint CREATE_NEW = 1, OPEN_EXISTING = 3;
    public const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    public const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
    public const uint FILE_FLAG_NO_BUFFERING = 0x20000000;
    public const uint FILE_FLAG_SEQUENTIAL_SCAN = 0x08000000;
    public const uint FILE_FLAG_WRITE_THROUGH = 0x80000000;

    public const uint FILE_ATTRIBUTE_READONLY = 0x1;
    public const uint FILE_ATTRIBUTE_HIDDEN = 0x2;
    public const uint FILE_ATTRIBUTE_SYSTEM = 0x4;
    public const uint FILE_ATTRIBUTE_DIRECTORY = 0x10;
    public const uint FILE_ATTRIBUTE_ARCHIVE = 0x20;
    public const uint FILE_ATTRIBUTE_DEVICE = 0x40;
    public const uint FILE_ATTRIBUTE_NORMAL = 0x80;
    public const uint FILE_ATTRIBUTE_SPARSE_FILE = 0x200;
    public const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x400;
    public const uint FILE_ATTRIBUTE_COMPRESSED = 0x800;
    public const uint FILE_ATTRIBUTE_OFFLINE = 0x1000;
    public const uint FILE_ATTRIBUTE_NOT_CONTENT_INDEXED = 0x2000;
    public const uint FILE_ATTRIBUTE_ENCRYPTED = 0x4000;
    public const uint FILE_ATTRIBUTE_PINNED = 0x00080000;
    public const uint FILE_ATTRIBUTE_RECALL_ON_OPEN = 0x00040000;
    public const uint FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS = 0x00400000;
    public const uint INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF;

    public const uint IO_REPARSE_TAG_MOUNT_POINT = 0xA0000003;
    public const uint IO_REPARSE_TAG_SYMLINK = 0xA000000C;
    public const uint IO_REPARSE_TAG_AF_UNIX = 0x80000023;

    public const int ERROR_FILE_NOT_FOUND = 2, ERROR_PATH_NOT_FOUND = 3, ERROR_ACCESS_DENIED = 5;
    public const int ERROR_SHARING_VIOLATION = 32, ERROR_LOCK_VIOLATION = 33;
    public const int ERROR_FILE_EXISTS = 80, ERROR_ALREADY_EXISTS = 183, ERROR_INVALID_PARAMETER = 87;
    public const int ERROR_NOT_SUPPORTED = 50, ERROR_NO_MORE_FILES = 18, ERROR_HANDLE_EOF = 38;
    public const int ERROR_MORE_DATA = 234;

    /// <summary>Ссылка — символическая или точка соединения: имя, за которым стоит другое место.</summary>
    public static bool IsNameSurrogate(uint tag) => (tag & 0x20000000) != 0;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition,
                                                    uint flags, IntPtr template);

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public long CreationTime;
        public long LastAccessTime;
        public long LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;

        public readonly long Size => ((long)FileSizeHigh << 32) | FileSizeLow;
        public readonly long FileIndex => (long)(((ulong)FileIndexHigh << 32) | FileIndexLow);
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetFileInformationByHandle(SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION info);

    [StructLayout(LayoutKind.Sequential)]
    public struct FILE_ATTRIBUTE_TAG_INFO
    {
        public uint FileAttributes;
        public uint ReparseTag;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int infoClass, out FILE_ATTRIBUTE_TAG_INFO info, uint size);

    public const int FileAttributeTagInfo = 9;

    /// <summary>Атрибуты и метка точки повторной обработки открытого объекта. exFAT и FAT этого запроса
    /// не понимают — у них и точек повторной обработки не бывает, поэтому хватает обычных атрибутов.</summary>
    public static FILE_ATTRIBUTE_TAG_INFO? AttributesAndTag(SafeFileHandle handle)
    {
        if (GetFileInformationByHandleEx(handle, FileAttributeTagInfo, out var tag, (uint)sizeof(FILE_ATTRIBUTE_TAG_INFO))) return tag;
        if (!GetFileInformationByHandle(handle, out var info)) return null;
        return new FILE_ATTRIBUTE_TAG_INFO { FileAttributes = info.FileAttributes & ~FILE_ATTRIBUTE_REPARSE_POINT, ReparseTag = 0 };
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetCompressedFileSizeW(string name, out uint high);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetFileAttributesW(string name);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetFileAttributesW(string name, uint attributes);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CreateDirectoryW(string name, IntPtr security);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool RemoveDirectoryW(string name);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool DeleteFileW(string name);

    public const uint MOVEFILE_WRITE_THROUGH = 0x8;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool MoveFileExW(string from, string to, uint flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, char* buffer, uint size, uint flags);

    // Обход каталога.

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 4)]
    public struct WIN32_FIND_DATAW
    {
        public uint FileAttributes;
        public long CreationTime;
        public long LastAccessTime;
        public long LastWriteTime;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint Reserved0;
        public uint Reserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string FileName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string AlternateFileName;
        public uint FileType;
        public uint CreatorType;
        public ushort FinderFlags;

        public readonly long Size => ((long)FileSizeHigh << 32) | FileSizeLow;
    }

    public const int FindExInfoBasic = 1;
    public const int FindExSearchNameMatch = 0;
    public const int FIND_FIRST_EX_LARGE_FETCH = 2;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr FindFirstFileExW(string name, int infoLevel, out WIN32_FIND_DATAW data, int searchOp,
                                                 IntPtr filter, int flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool FindNextFileW(IntPtr handle, out WIN32_FIND_DATAW data);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool FindClose(IntPtr handle);

    public static readonly IntPtr INVALID_HANDLE_VALUE = new(-1);

    // Потоки NTFS.

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WIN32_FIND_STREAM_DATA
    {
        public long StreamSize;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 296)] public string StreamName;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr FindFirstStreamW(string name, int level, out WIN32_FIND_STREAM_DATA data, uint flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool FindNextStreamW(IntPtr handle, out WIN32_FIND_STREAM_DATA data);

    // Тома.

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool GetDiskFreeSpaceExW(string directory, out ulong freeToCaller, out ulong total, out ulong totalFree);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool GetDiskFreeSpaceW(string root, out uint sectorsPerCluster, out uint bytesPerSector,
                                                out uint freeClusters, out uint totalClusters);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool GetVolumeInformationW(string root, char* name, uint nameSize, out uint serial,
                                                    out uint maxComponent, out uint flags, char* fsName, uint fsNameSize);

    public const uint FILE_READ_ONLY_VOLUME = 0x00080000;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool GetVolumePathNameW(string path, char* buffer, uint size);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool GetVolumeNameForVolumeMountPointW(string mountPoint, char* buffer, uint size);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool GetVolumePathNamesForVolumeNameW(string volume, char* buffer, uint size, out uint needed);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr FindFirstVolumeW(char* buffer, uint size);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool FindNextVolumeW(IntPtr handle, char* buffer, uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool FindVolumeClose(IntPtr handle);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetVolumeMountPointW(string mountPoint, string volumeName);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool DeleteVolumeMountPointW(string mountPoint);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool DeviceIoControl(SafeFileHandle device, uint code, void* input, uint inputSize, void* output,
                                              uint outputSize, out uint returned, IntPtr overlapped);

    public const uint IOCTL_STORAGE_QUERY_PROPERTY = 0x002D1400;
    public const uint IOCTL_STORAGE_GET_DEVICE_NUMBER = 0x002D1080;
    public const uint IOCTL_STORAGE_GET_HOTPLUG_INFO = 0x002D0C14;
    public const uint FSCTL_LOCK_VOLUME = 0x00090018;
    public const uint FSCTL_UNLOCK_VOLUME = 0x0009001C;
    public const uint FSCTL_DISMOUNT_VOLUME = 0x00090020;
    public const uint FSCTL_SET_REPARSE_POINT = 0x000900A4;
    public const uint FSCTL_GET_REPARSE_POINT = 0x000900A8;

    [StructLayout(LayoutKind.Sequential)]
    public struct STORAGE_DEVICE_NUMBER
    {
        public uint DeviceType;
        public uint DeviceNumber;
        public uint PartitionNumber;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct STORAGE_HOTPLUG_INFO
    {
        public uint Size;
        public byte MediaRemovable;
        public byte MediaHotplug;
        public byte DeviceHotplug;
        public byte WriteCacheEnableOverride;
    }

    /// <summary>Шина устройства из STORAGE_DEVICE_DESCRIPTOR.</summary>
    public enum BusType : uint
    {
        Unknown = 0, Scsi = 1, Atapi = 2, Ata = 3, Ieee1394 = 4, Ssa = 5, Fibre = 6, Usb = 7, RAID = 8, iScsi = 9,
        Sas = 10, Sata = 11, Sd = 12, Mmc = 13, Virtual = 14, FileBackedVirtual = 15, Spaces = 16, Nvme = 17, SCM = 18, Ufs = 19,
    }

    /// <summary>Шина и «съёмный носитель» для тома или диска: \\.\E: или \\.\PhysicalDrive2.</summary>
    public static (BusType bus, bool removable)? StorageBus(string devicePath)
    {
        using var handle = CreateFileW(devicePath, 0, FILE_SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (handle.IsInvalid) return null;
        // STORAGE_PROPERTY_QUERY: PropertyId = StorageDeviceProperty (0), QueryType = PropertyStandardQuery (0).
        var query = stackalloc uint[3];
        query[0] = 0; query[1] = 0; query[2] = 0;
        var buffer = stackalloc byte[1024];
        if (!DeviceIoControl(handle, IOCTL_STORAGE_QUERY_PROPERTY, query, 12, buffer, 1024, out var returned, IntPtr.Zero) || returned < 32)
            return null;
        // STORAGE_DEVICE_DESCRIPTOR: Version, Size, DeviceType(1), DeviceTypeModifier(1), RemovableMedia(1), CommandQueueing(1),
        // VendorIdOffset, ProductIdOffset, ProductRevisionOffset, SerialNumberOffset, BusType (смещение 28).
        bool removable = buffer[10] != 0;
        var bus = (BusType)(*(uint*)(buffer + 28));
        return (bus, removable);
    }

    public static bool? DeviceHotplug(string devicePath)
    {
        using var handle = CreateFileW(devicePath, 0, FILE_SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (handle.IsInvalid) return null;
        STORAGE_HOTPLUG_INFO info;
        if (!DeviceIoControl(handle, IOCTL_STORAGE_GET_HOTPLUG_INFO, null, 0, &info, (uint)sizeof(STORAGE_HOTPLUG_INFO), out _, IntPtr.Zero))
            return null;
        return info.DeviceHotplug != 0 || info.MediaHotplug != 0;
    }

    public static STORAGE_DEVICE_NUMBER? DeviceNumber(string devicePath)
    {
        using var handle = CreateFileW(devicePath, 0, FILE_SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (handle.IsInvalid) return null;
        STORAGE_DEVICE_NUMBER number;
        if (!DeviceIoControl(handle, IOCTL_STORAGE_GET_DEVICE_NUMBER, null, 0, &number, (uint)sizeof(STORAGE_DEVICE_NUMBER), out _, IntPtr.Zero))
            return null;
        return number;
    }

    // Restart Manager — кто держит файлы открытыми (как lsof на Mac).

    [StructLayout(LayoutKind.Sequential)]
    public struct RM_UNIQUE_PROCESS
    {
        public int ProcessId;
        public long ProcessStartTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct RM_PROCESS_INFO
    {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string AppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string ServiceShortName;
        public int ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool Restartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    public static extern int RmStartSession(out uint session, int flags, char* key);

    [DllImport("rstrtmgr.dll")]
    public static extern int RmEndSession(uint session);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    public static extern int RmRegisterResources(uint session, uint fileCount, string[] files, uint appCount, IntPtr apps,
                                                 uint serviceCount, IntPtr services);

    [DllImport("rstrtmgr.dll")]
    public static extern int RmGetList(uint session, out uint needed, ref uint count, [In, Out] RM_PROCESS_INFO[]? info, out uint reasons);

    // Вспомогательное.

    public static Win32Exception LastError() => new(Marshal.GetLastWin32Error());

    /// <summary>Путь для вызовов Win32 без предела в 260 знаков: «\\?\C:\…». Путь должен быть уже полным
    /// и нормализованным — с префиксом система его не разбирает.</summary>
    public static string Long(string path)
    {
        if (path.StartsWith(@"\\?\", StringComparison.Ordinal) || path.StartsWith(@"\\.\", StringComparison.Ordinal)) return path;
        if (path.StartsWith(@"\\", StringComparison.Ordinal)) return @"\\?\UNC\" + path[2..];
        if (path.Length >= 3 && path[1] == ':' && path[2] == '\\') return @"\\?\" + path;
        return path;
    }

    public static DateTime? FromFileTime(long fileTime) => fileTime <= 0 ? null : DateTime.FromFileTimeUtc(fileTime);

    public static string? FinalPath(SafeFileHandle handle)
    {
        var buffer = stackalloc char[32768];
        uint length = GetFinalPathNameByHandleW(handle, buffer, 32768, 0);
        if (length == 0 || length >= 32768) return null;
        var path = new string(buffer, 0, (int)length);
        if (path.StartsWith(@"\\?\UNC\", StringComparison.Ordinal)) return @"\\" + path[8..];
        if (path.StartsWith(@"\\?\", StringComparison.Ordinal)) return path[4..];
        return path;
    }

    public static string? VolumePathName(string path)
    {
        var buffer = stackalloc char[1024];
        return GetVolumePathNameW(path, buffer, 1024) ? new string(buffer) : null;
    }

    public static string? VolumeGuidPath(string mountPoint)
    {
        var buffer = stackalloc char[128];
        var root = mountPoint.EndsWith('\\') ? mountPoint : mountPoint + "\\";
        return GetVolumeNameForVolumeMountPointW(root, buffer, 128) ? new string(buffer) : null;
    }

    public static List<string> VolumeMountPoints(string volumeGuidPath)
    {
        var buffer = stackalloc char[4096];
        if (!GetVolumePathNamesForVolumeNameW(volumeGuidPath, buffer, 4096, out _)) return [];
        var result = new List<string>();
        var span = new ReadOnlySpan<char>(buffer, 4096);
        int start = 0;
        for (int i = 0; i < span.Length; i++)
        {
            if (span[i] != '\0') continue;
            if (i == start) break;
            result.Add(new string(span[start..i]));
            start = i + 1;
        }
        return result;
    }

    public static List<string> AllVolumeGuidPaths()
    {
        var result = new List<string>();
        var buffer = stackalloc char[128];
        var handle = FindFirstVolumeW(buffer, 128);
        if (handle == INVALID_HANDLE_VALUE) return result;
        try
        {
            do { result.Add(new string(buffer)); } while (FindNextVolumeW(handle, buffer, 128));
        }
        finally { FindVolumeClose(handle); }
        return result;
    }

    /// <summary>Метка тома, файловая система, флаги и серийный номер.</summary>
    public static (string label, string fileSystem, uint flags, uint serial)? VolumeInformation(string root)
    {
        var name = stackalloc char[261];
        var fs = stackalloc char[261];
        if (!GetVolumeInformationW(root, name, 261, out var serial, out _, out var flags, fs, 261)) return null;
        return (new string(name), new string(fs), flags, serial);
    }
}
