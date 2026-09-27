using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Offload.Core;

/// <summary>Сведения об объекте без перехода по ссылке: атрибуты, даты, размер, число имён, номер файла.</summary>
public readonly record struct FileStat(uint Attributes, long Size, DateTime? Created, DateTime? Modified, uint Links,
                                       uint VolumeSerial, long FileIndex, uint ReparseTag)
{
    public bool IsDirectory => (Attributes & Native.FILE_ATTRIBUTE_DIRECTORY) != 0;
    public bool IsReparse => (Attributes & Native.FILE_ATTRIBUTE_REPARSE_POINT) != 0;
    /// <summary>Символическая ссылка или точка соединения — имя, за которым стоит другое место.
    /// Прочие точки повторной обработки (сжатие WOF, дедупликация, файлы OneDrive) — обычные файлы и папки.</summary>
    public bool IsLink => IsReparse && Native.IsNameSurrogate(ReparseTag);
    public bool IsSpecial => IsReparse && ReparseTag == Native.IO_REPARSE_TAG_AF_UNIX
                             || (Attributes & Native.FILE_ATTRIBUTE_DEVICE) != 0;
    public bool IsRegularFile => !IsDirectory && !IsLink && !IsSpecial;
    public bool IsRegularDirectory => IsDirectory && !IsLink;
    /// <summary>Файл есть только в облаке (OneDrive, iCloud): чтение его скачает.</summary>
    public bool IsCloudOnly => (Attributes & (Native.FILE_ATTRIBUTE_OFFLINE | Native.FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS
                                              | Native.FILE_ATTRIBUTE_RECALL_ON_OPEN)) != 0;
}

/// <summary>Элемент каталога из одного вызова FindNextFile — без открытия файла.</summary>
public readonly record struct DirItem(string Name, uint Attributes, long Size, DateTime? Created, DateTime? Modified, uint ReparseTag)
{
    public bool IsDirectory => (Attributes & Native.FILE_ATTRIBUTE_DIRECTORY) != 0;
    public bool IsReparse => (Attributes & Native.FILE_ATTRIBUTE_REPARSE_POINT) != 0;
    public bool IsLink => IsReparse && Native.IsNameSurrogate(ReparseTag);
    public bool IsHidden => (Attributes & (Native.FILE_ATTRIBUTE_HIDDEN | Native.FILE_ATTRIBUTE_SYSTEM)) != 0;
    public bool IsCloudOnly => (Attributes & (Native.FILE_ATTRIBUTE_OFFLINE | Native.FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS
                                              | Native.FILE_ATTRIBUTE_RECALL_ON_OPEN)) != 0;
    public bool IsSparseOrCompressed => (Attributes & (Native.FILE_ATTRIBUTE_SPARSE_FILE | Native.FILE_ATTRIBUTE_COMPRESSED)) != 0
                                        || (IsReparse && !IsLink);
}

public static unsafe class FileSystem
{
    /// <summary>Сведения об объекте без перехода по ссылке; null — объекта нет или он не открывается.</summary>
    public static FileStat? Stat(string path)
    {
        using var handle = Native.CreateFileW(Native.Long(path), Native.FILE_READ_ATTRIBUTES, Native.FILE_SHARE_ALL, IntPtr.Zero,
                                              Native.OPEN_EXISTING, Native.FILE_FLAG_OPEN_REPARSE_POINT | Native.FILE_FLAG_BACKUP_SEMANTICS,
                                              IntPtr.Zero);
        if (handle.IsInvalid) return null;
        if (!Native.GetFileInformationByHandle(handle, out var info)) return null;
        uint tag = 0;
        if ((info.FileAttributes & Native.FILE_ATTRIBUTE_REPARSE_POINT) != 0
            && Native.GetFileInformationByHandleEx(handle, Native.FileAttributeTagInfo, out var tagInfo, (uint)sizeof(Native.FILE_ATTRIBUTE_TAG_INFO)))
            tag = tagInfo.ReparseTag;
        return new FileStat(info.FileAttributes, info.Size, Native.FromFileTime(info.CreationTime), Native.FromFileTime(info.LastWriteTime),
                            info.NumberOfLinks, info.VolumeSerialNumber, info.FileIndex, tag);
    }

    /// <summary>Есть ли что-нибудь по пути — не переходя по ссылке.</summary>
    public static bool Exists(string path) => Native.GetFileAttributesW(Native.Long(path)) != Native.INVALID_FILE_ATTRIBUTES;

    public static bool IsRegularFile(string path) => Stat(path) is { IsRegularFile: true };
    public static bool IsRegularDirectory(string path) => Stat(path) is { IsRegularDirectory: true };

    /// <summary>Имена в каталоге без «.» и «..», ничего не скрывая: ни скрытых, ни системных.</summary>
    public static List<DirItem> List(string directory)
    {
        var pattern = Native.Long(directory.EndsWith('\\') ? directory + "*" : directory + "\\*");
        var handle = Native.FindFirstFileExW(pattern, Native.FindExInfoBasic, out var data, Native.FindExSearchNameMatch,
                                             IntPtr.Zero, Native.FIND_FIRST_EX_LARGE_FETCH);
        if (handle == Native.INVALID_HANDLE_VALUE)
        {
            int code = Marshal.GetLastWin32Error();
            if (code == Native.ERROR_FILE_NOT_FOUND) return [];
            throw code == Native.ERROR_ACCESS_DENIED
                ? new UnauthorizedAccessException($"Нет доступа к «{directory}».")
                : new IOException($"Не удалось прочитать «{directory}».", new Win32Exception(code));
        }
        var result = new List<DirItem>();
        try
        {
            do
            {
                if (data.FileName is "." or "..") continue;
                result.Add(new DirItem(data.FileName, data.FileAttributes, data.Size, Native.FromFileTime(data.CreationTime),
                                       Native.FromFileTime(data.LastWriteTime),
                                       (data.FileAttributes & Native.FILE_ATTRIBUTE_REPARSE_POINT) != 0 ? data.Reserved0 : 0));
            } while (Native.FindNextFileW(handle, out data));
        }
        finally { Native.FindClose(handle); }
        return result;
    }

    public static List<string> Names(string directory) => List(directory).Select(i => i.Name).ToList();

    /// <summary>Сколько файл занимает на диске: у сжатых и разрежённых меньше размера, у файлов,
    /// которые есть только в облаке, — ноль.</summary>
    public static long Allocated(string path, long size, uint attributes, long clusterSize)
    {
        long used = size;
        bool special = (attributes & (Native.FILE_ATTRIBUTE_SPARSE_FILE | Native.FILE_ATTRIBUTE_COMPRESSED | Native.FILE_ATTRIBUTE_REPARSE_POINT
                                      | Native.FILE_ATTRIBUTE_OFFLINE | Native.FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS
                                      | Native.FILE_ATTRIBUTE_RECALL_ON_OPEN)) != 0;
        if (special)
        {
            uint low = Native.GetCompressedFileSizeW(Native.Long(path), out var high);
            if (low != 0xFFFFFFFF || Marshal.GetLastWin32Error() == 0) used = ((long)high << 32) | low;
        }
        if (clusterSize <= 0) return used;
        return (used + clusterSize - 1) / clusterSize * clusterSize;
    }

    /// <summary>Потоки NTFS кроме основного: имена вида «:Zone.Identifier:$DATA».</summary>
    public static List<string> AlternateStreams(string path)
    {
        var result = new List<string>();
        var handle = Native.FindFirstStreamW(Native.Long(path), 0, out var data, 0);
        if (handle == Native.INVALID_HANDLE_VALUE) return result;
        try
        {
            do
            {
                if (data.StreamName != "::$DATA") result.Add(data.StreamName);
            } while (Native.FindNextStreamW(handle, out data));
        }
        finally { Native.FindClose(handle); }
        return result;
    }

    /// <summary>Новая папка; существующая (или ссылка на её месте) — ошибка, а не «уже есть».</summary>
    public static void CreateDirectoryExclusive(string path)
    {
        if (Native.CreateDirectoryW(Native.Long(path), IntPtr.Zero)) return;
        int code = Marshal.GetLastWin32Error();
        if (code == Native.ERROR_ALREADY_EXISTS) throw new CopyException(CopyErrorKind.DestinationExists, path);
        throw new CopyException(CopyErrorKind.WriteFailed, path, new Win32Exception(code).Message);
    }

    /// <summary>Переименование без замены: если на новом месте уже что-то есть — ошибка.
    /// MoveFileEx без MOVEFILE_REPLACE_EXISTING так и работает на всех файловых системах.</summary>
    public static void RenameExclusive(string from, string to)
    {
        if (Native.MoveFileExW(Native.Long(from), Native.Long(to), Native.MOVEFILE_WRITE_THROUGH)) return;
        int code = Marshal.GetLastWin32Error();
        if (code is Native.ERROR_ALREADY_EXISTS or Native.ERROR_FILE_EXISTS) throw new MoveException(MoveErrorKind.AlreadyExists, to);
        throw new CopyException(CopyErrorKind.WriteFailed, to, new Win32Exception(code).Message);
    }

    /// <summary>Снимает «только чтение»: иначе Windows не удалит файл, а git держит так свои объекты.</summary>
    public static void ClearReadOnly(string path)
    {
        uint attributes = Native.GetFileAttributesW(Native.Long(path));
        if (attributes == Native.INVALID_FILE_ATTRIBUTES || (attributes & Native.FILE_ATTRIBUTE_READONLY) == 0) return;
        Native.SetFileAttributesW(Native.Long(path), attributes & ~Native.FILE_ATTRIBUTE_READONLY);
    }

    /// <summary>Удаляет файл, папку со всем содержимым или ссылку — саму ссылку, не заходя за неё.
    /// Атрибут «только чтение» снимается по дороге.</summary>
    public static void DeleteTree(string path, Func<bool>? isCancelled = null)
    {
        var stat = Stat(path) ?? throw new FileNotFoundException($"Нет «{path}».");
        if (stat.IsDirectory)
        {
            if (!stat.IsLink)
            {
                foreach (var item in List(path))
                {
                    if (isCancelled?.Invoke() == true) throw new OperationCanceledException();
                    DeleteTree(Path.Combine(path, item.Name), isCancelled);
                }
            }
            ClearReadOnly(path);
            if (!Native.RemoveDirectoryW(Native.Long(path))) throw new IOException($"Не удалось удалить «{path}».", Native.LastError());
            return;
        }
        ClearReadOnly(path);
        if (!Native.DeleteFileW(Native.Long(path))) throw new IOException($"Не удалось удалить «{path}».", Native.LastError());
    }

    public static void TryDeleteTree(string path)
    {
        try { if (Exists(path)) DeleteTree(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
