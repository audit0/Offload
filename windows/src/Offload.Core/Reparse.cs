using System.Runtime.InteropServices;
using System.Text;

namespace Offload.Core;

/// <summary>Что за ссылка: символическая (файл или папка) или точка соединения папки.</summary>
public enum LinkType { Symbolic, Junction }

/// <summary>Ссылка на диске: куда ведёт и какая.</summary>
public sealed record LinkInfo(LinkType Type, string Target, bool IsRelative, bool IsDirectory)
{
    /// <summary>Точка подключения другого тома («\??\Volume{…}\»): внутри папки другой диск.</summary>
    public bool IsVolumeMount => Type == LinkType.Junction && Target.StartsWith("Volume{", StringComparison.OrdinalIgnoreCase);
}

/// <summary>Чтение и создание ссылок NTFS напрямую — .NET не умеет ни точек соединения, ни чтения
/// ссылки без перехода по ней.</summary>
public static unsafe class Reparse
{
    /// <summary>Ссылка по пути; null — это не ссылка (или не прочиталась).</summary>
    public static LinkInfo? Read(string path)
    {
        using var handle = Native.CreateFileW(path, 0, Native.FILE_SHARE_ALL, IntPtr.Zero, Native.OPEN_EXISTING,
                                              Native.FILE_FLAG_OPEN_REPARSE_POINT | Native.FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
        if (handle.IsInvalid) return null;
        if (Native.AttributesAndTag(handle) is not { } tagInfo) return null;
        if ((tagInfo.FileAttributes & Native.FILE_ATTRIBUTE_REPARSE_POINT) == 0) return null;
        bool isDirectory = (tagInfo.FileAttributes & Native.FILE_ATTRIBUTE_DIRECTORY) != 0;
        const int size = 16 * 1024;
        var buffer = stackalloc byte[size];
        if (!Native.DeviceIoControl(handle, Native.FSCTL_GET_REPARSE_POINT, null, 0, buffer, size, out var returned, IntPtr.Zero))
            return null;
        uint tag = *(uint*)buffer;
        int headerSize;
        uint flags = 0;
        LinkType type;
        if (tag == Native.IO_REPARSE_TAG_SYMLINK)
        {
            headerSize = 20;
            flags = *(uint*)(buffer + 16);
            type = LinkType.Symbolic;
        }
        else if (tag == Native.IO_REPARSE_TAG_MOUNT_POINT)
        {
            headerSize = 16;
            type = LinkType.Junction;
        }
        else
        {
            return null;
        }
        ushort substituteOffset = *(ushort*)(buffer + 8);
        ushort substituteLength = *(ushort*)(buffer + 10);
        ushort printOffset = *(ushort*)(buffer + 12);
        ushort printLength = *(ushort*)(buffer + 14);
        string Name(ushort offset, ushort length) =>
            offset + length + headerSize <= returned ? new string((char*)(buffer + headerSize + offset), 0, length / 2) : "";
        var substitute = Name(substituteOffset, substituteLength);
        var print = Name(printOffset, printLength);
        bool relative = (flags & 1) != 0;
        string target;
        if (relative)
        {
            target = print.Length > 0 ? print : substitute;
        }
        else
        {
            // «\??\C:\папка» — служебное имя, «C:\папка» — то же для человека.
            target = substitute.StartsWith(@"\??\", StringComparison.Ordinal) ? substitute[4..] : (print.Length > 0 ? print : substitute);
        }
        return new LinkInfo(type, target, relative, isDirectory);
    }

    /// <summary>Воссоздаёт ссылку. Точка соединения создаётся без особых прав;
    /// символической ссылке нужен режим разработчика или права администратора.</summary>
    public static void Create(string path, LinkInfo link)
    {
        if (link.Type == LinkType.Junction)
        {
            CreateJunction(path, link.Target);
            return;
        }
        if (link.IsDirectory) Directory.CreateSymbolicLink(path, link.Target);
        else File.CreateSymbolicLink(path, link.Target);
    }

    /// <summary>Точка соединения: пустая папка и в ней указатель на другую папку.</summary>
    public static void CreateJunction(string path, string target)
    {
        if (!Native.CreateDirectoryW(path, IntPtr.Zero)) throw Native.LastError();
        try
        {
            using var handle = Native.CreateFileW(path, Native.GENERIC_WRITE, 0, IntPtr.Zero, Native.OPEN_EXISTING,
                                                  Native.FILE_FLAG_OPEN_REPARSE_POINT | Native.FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
            if (handle.IsInvalid) throw Native.LastError();
            // Для точки подключения тома («Volume{…}\») служебное имя — «\??\Volume{…}\».
            var substitute = @"\??\" + target;
            var print = target.StartsWith("Volume{", StringComparison.OrdinalIgnoreCase) ? "" : target;
            var substituteBytes = Encoding.Unicode.GetBytes(substitute);
            var printBytes = Encoding.Unicode.GetBytes(print);
            int pathBytes = substituteBytes.Length + 2 + printBytes.Length + 2;
            int dataLength = 8 + pathBytes;
            var buffer = new byte[8 + dataLength];
            fixed (byte* raw = buffer)
            {
                *(uint*)raw = Native.IO_REPARSE_TAG_MOUNT_POINT;
                *(ushort*)(raw + 4) = (ushort)dataLength;
                *(ushort*)(raw + 8) = 0;
                *(ushort*)(raw + 10) = (ushort)substituteBytes.Length;
                *(ushort*)(raw + 12) = (ushort)(substituteBytes.Length + 2);
                *(ushort*)(raw + 14) = (ushort)printBytes.Length;
                Marshal.Copy(substituteBytes, 0, (IntPtr)(raw + 16), substituteBytes.Length);
                Marshal.Copy(printBytes, 0, (IntPtr)(raw + 16 + substituteBytes.Length + 2), printBytes.Length);
                if (!Native.DeviceIoControl(handle, Native.FSCTL_SET_REPARSE_POINT, raw, (uint)buffer.Length, null, 0, out _, IntPtr.Zero))
                    throw Native.LastError();
            }
        }
        catch
        {
            Native.RemoveDirectoryW(path);
            throw;
        }
    }
}
