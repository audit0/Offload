using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Offload.Core;

public enum TreeEntryKind { Directory, File, Link }

/// <summary>Один объект дерева, снятый при обходе.</summary>
public sealed record TreeEntry(
    /// <summary>Путь относительно корня, через «\»; пустая строка — сам корень.</summary>
    string RelativePath,
    TreeEntryKind Kind,
    long Size,
    DateTime? Modified,
    DateTime? Created,
    /// <summary>Атрибуты Windows: «только чтение», «скрытый», «системный».</summary>
    uint Attributes,
    LinkInfo? Link = null)
{
    public bool IsDirectory => Kind == TreeEntryKind.Directory;
    public bool IsFile => Kind == TreeEntryKind.File;
    public bool IsLink => Kind == TreeEntryKind.Link;
    public string Name => RelativePath.Length == 0 ? "" : Path.GetFileName(RelativePath);
}

public enum CopyErrorKind { Unreadable, DestinationExists, WriteFailed, VerificationFailed, ChangedDuringCopy }

public sealed class CopyException : Exception
{
    public CopyErrorKind Kind { get; }
    public string Item { get; }

    public CopyException(CopyErrorKind kind, string item, string reason = "") : base(Describe(kind, item, reason))
    {
        Kind = kind;
        Item = item;
    }

    static string Describe(CopyErrorKind kind, string item, string reason) => kind switch
    {
        CopyErrorKind.Unreadable => $"Не удалось прочитать «{item}».",
        CopyErrorKind.DestinationExists => $"На диске назначения уже есть «{item}» — перезаписывать не буду.",
        CopyErrorKind.WriteFailed => $"Не удалось записать «{item}»: {reason}",
        CopyErrorKind.VerificationFailed => $"Копия «{item}» не совпала с оригиналом.",
        _ => $"«{item}» изменился во время переноса — оригинал не тронут.",
    };
}

public static class TreeWalker
{
    /// <summary>Атрибуты, которые копия переносит: остальное (архивный, сжатый, разрежённый) —
    /// дело файловой системы назначения.</summary>
    public const uint KeptAttributes = Native.FILE_ATTRIBUTE_READONLY | Native.FILE_ATTRIBUTE_HIDDEN | Native.FILE_ATTRIBUTE_SYSTEM
                                       | Native.FILE_ATTRIBUTE_NOT_CONTENT_INDEXED;

    /// <summary>Обходит дерево, не переходя по ссылкам и точкам соединения.
    /// Обход — через перечисление .NET, а не FindFirstFile, как у Inspector: перед удалением оригинала
    /// их результаты сверяются, и ошибка одного механизма не пройдёт незамеченной.</summary>
    /// <param name="strict">любая ошибка чтения прерывает обход; иначе ошибки собираются в problems.</param>
    /// <param name="exclude">относительный путь и признак каталога; true — пропустить вместе с содержимым.</param>
    public static (List<TreeEntry> entries, List<string> problems) Walk(string root, bool strict,
        Func<string, bool, bool>? exclude = null, Func<bool>? isCancelled = null)
    {
        isCancelled ??= () => false;
        exclude ??= (_, _) => false;
        var rootPath = Paths.Trim(root);
        var entries = new List<TreeEntry>();
        var problems = new List<string>();

        TreeEntry? Make(string path, string relative, FileStat stat)
        {
            string label = relative.Length == 0 ? Paths.Name(rootPath) : relative;
            if (stat.IsLink)
            {
                var link = Reparse.Read(path);
                if (link == null)
                {
                    if (strict) throw new CopyException(CopyErrorKind.Unreadable, label);
                    problems.Add(label);
                    return null;
                }
                return new TreeEntry(relative, TreeEntryKind.Link, 0, stat.Modified, stat.Created, stat.Attributes & KeptAttributes, link);
            }
            if (stat.IsSpecial)
            {
                // Сокеты и устройства не копируются.
                if (strict) throw new CopyException(CopyErrorKind.Unreadable, $"{label} (особый файл)");
                problems.Add($"{label} (особый файл пропущен)");
                return null;
            }
            return stat.IsDirectory
                ? new TreeEntry(relative, TreeEntryKind.Directory, 0, stat.Modified, stat.Created, stat.Attributes & KeptAttributes)
                : new TreeEntry(relative, TreeEntryKind.File, stat.Size, stat.Modified, stat.Created, stat.Attributes & KeptAttributes);
        }

        var rootStat = FileSystem.Stat(rootPath);
        if (rootStat is not { } rs)
        {
            if (strict) throw new CopyException(CopyErrorKind.Unreadable, Paths.Name(rootPath));
            problems.Add(Paths.Name(rootPath));
            return (entries, problems);
        }
        var rootEntry = Make(rootPath, "", rs);
        if (rootEntry == null) return (entries, problems);
        entries.Add(rootEntry);
        if (!rootEntry.IsDirectory) return (entries, problems);

        var options = new EnumerationOptions
        {
            AttributesToSkip = 0,
            IgnoreInaccessible = false,
            RecurseSubdirectories = false,
            ReturnSpecialDirectories = false,
            MatchType = MatchType.Win32,
        };
        var pending = new Stack<string>();
        pending.Push("");
        while (pending.TryPop(out var directory))
        {
            if (isCancelled()) throw new OperationCanceledException();
            var full = directory.Length == 0 ? rootPath : Path.Combine(rootPath, directory);
            List<string> names;
            try
            {
                names = new DirectoryInfo(full).EnumerateFileSystemInfos("*", options).Select(i => i.Name).ToList();
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                var label = directory.Length == 0 ? Paths.Name(rootPath) : directory;
                if (strict) throw new CopyException(CopyErrorKind.Unreadable, label);
                problems.Add(label);
                continue;
            }
            names.Sort(StringComparer.Ordinal);
            foreach (var name in names)
            {
                var relative = directory.Length == 0 ? name : directory + "\\" + name;
                var path = Path.Combine(rootPath, relative);
                if (FileSystem.Stat(path) is not { } stat)
                {
                    if (strict) throw new CopyException(CopyErrorKind.Unreadable, relative);
                    problems.Add(relative);
                    continue;
                }
                var item = Make(path, relative, stat);
                if (item == null) continue;
                if (exclude(relative, item.IsDirectory)) continue;
                entries.Add(item);
                if (item.IsDirectory) pending.Push(relative);
            }
        }
        return (entries, problems);
    }
}

/// <summary>Копирование, при котором оригинал удаляется только после побайтовой сверки копии.</summary>
public static class VerifiedCopy
{
    public const int ChunkSize = 4 * 1024 * 1024;

    /// <summary>Копирует данные файла (без дополнительных потоков NTFS) и возвращает SHA-256 прочитанных байтов.
    ///
    /// Файл назначения создаётся с CREATE_NEW: существующий файл или подложенная на его месте ссылка
    /// не будут перезаписаны. Источник открывается без перехода по ссылке: если после обхода файл
    /// подменят ссылкой, чтение не уйдёт по ней.</summary>
    public static string CopyFile(string source, string destination, Func<bool>? isCancelled = null, Action<int>? progress = null)
    {
        isCancelled ??= () => false;
        using var input = OpenSource(source);
        var output = Native.CreateFileW(Native.Long(destination), Native.GENERIC_WRITE, 0, IntPtr.Zero, Native.CREATE_NEW,
                                        Native.FILE_FLAG_SEQUENTIAL_SCAN, IntPtr.Zero);
        if (output.IsInvalid)
        {
            int code = Marshal.GetLastWin32Error();
            output.Dispose();
            if (code is Native.ERROR_FILE_EXISTS or Native.ERROR_ALREADY_EXISTS) throw new CopyException(CopyErrorKind.DestinationExists, destination);
            throw new CopyException(CopyErrorKind.WriteFailed, destination, new Win32Exception(code).Message);
        }
        using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[ChunkSize];
        try
        {
            long offset = 0;
            while (true)
            {
                if (isCancelled()) throw new OperationCanceledException();
                int read = RandomAccess.Read(input, buffer, offset);
                if (read == 0) break;
                hasher.AppendData(buffer, 0, read);
                RandomAccess.Write(output, new ReadOnlySpan<byte>(buffer, 0, read), offset);
                offset += read;
                progress?.Invoke(read);
            }
            // Данные должны лечь на носитель до того, как оригинал будет удалён. FlushFileBuffers сбрасывает
            // и кеш Windows, и кеш самого накопителя — выдерни флешку, и без этого данные пропали бы.
            RandomAccess.FlushToDisk(output);
            output.Dispose();
        }
        catch (Exception ex)
        {
            output.Dispose();
            try { File.Delete(destination); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            if (ex is IOException io && ex is not CopyException) throw new CopyException(CopyErrorKind.WriteFailed, destination, io.Message);
            throw;
        }
        return Convert.ToHexStringLower(hasher.GetHashAndReset());
    }

    /// <summary>Открывает файл для чтения, не переходя по ссылке. Файлы со сжатием WOF, дедупликацией
    /// или из OneDrive — тоже точки повторной обработки, но не ссылки: их читаем обычным открытием,
    /// убедившись, что это тот же самый файл.</summary>
    static SafeFileHandle OpenSource(string path)
    {
        const uint share = Native.FILE_SHARE_READ;
        var handle = Native.CreateFileW(Native.Long(path), Native.GENERIC_READ, share, IntPtr.Zero, Native.OPEN_EXISTING,
                                        Native.FILE_FLAG_OPEN_REPARSE_POINT | Native.FILE_FLAG_SEQUENTIAL_SCAN, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            handle.Dispose();
            throw new CopyException(CopyErrorKind.Unreadable, path);
        }
        {
            if (Native.AttributesAndTag(handle) is not { } tag || (tag.FileAttributes & Native.FILE_ATTRIBUTE_DIRECTORY) != 0)
            {
                handle.Dispose();
                throw new CopyException(CopyErrorKind.Unreadable, path);
            }
            if ((tag.FileAttributes & Native.FILE_ATTRIBUTE_REPARSE_POINT) == 0) return handle;
            if (Native.IsNameSurrogate(tag.ReparseTag))
            {
                handle.Dispose();
                throw new CopyException(CopyErrorKind.Unreadable, path);
            }
            Native.GetFileInformationByHandle(handle, out var first);
            var plain = Native.CreateFileW(Native.Long(path), Native.GENERIC_READ, share, IntPtr.Zero, Native.OPEN_EXISTING,
                                           Native.FILE_FLAG_SEQUENTIAL_SCAN, IntPtr.Zero);
            handle.Dispose();
            if (plain.IsInvalid || !Native.GetFileInformationByHandle(plain, out var second)
                || second.FileIndex != first.FileIndex || second.VolumeSerialNumber != first.VolumeSerialNumber)
            {
                plain.Dispose();
                throw new CopyException(CopyErrorKind.Unreadable, path);
            }
            return plain;
        }
    }

    internal static string Url(string root, TreeEntry entry) => entry.RelativePath.Length == 0 ? root : Path.Combine(root, entry.RelativePath);

    static string DisplayName(string root, TreeEntry entry) => entry.RelativePath.Length == 0 ? Paths.Name(root) : entry.RelativePath;

    /// <summary>Создаёт копию дерева в destination (его ещё не должно существовать).
    /// Возвращает SHA-256 исходных байтов каждого файла.</summary>
    /// <param name="didCreateRoot">вызывается сразу после создания корневой папки копии и до того, как в неё
    /// что-то записано. Через него кладётся метка «здесь идёт копирование».</param>
    /// <param name="attributeMask">какие атрибуты переносить. При возврате из недоверенного архива
    /// «системный» не восстанавливается.</param>
    public static Dictionary<string, string> CopyTree(IReadOnlyList<TreeEntry> entries, string source, string destination,
        bool keepAttributes, uint attributeMask = TreeWalker.KeptAttributes, Func<bool>? isCancelled = null,
        Action<string, int>? progress = null, Action<string>? didCreateRoot = null)
    {
        isCancelled ??= () => false;
        var hashes = new Dictionary<string, string>(Paths.Comparer);
        foreach (var entry in entries)
        {
            if (isCancelled()) throw new OperationCanceledException();
            var target = Url(destination, entry);
            switch (entry.Kind)
            {
                case TreeEntryKind.Directory:
                    FileSystem.CreateDirectoryExclusive(target);
                    if (entry.RelativePath.Length == 0) didCreateRoot?.Invoke(destination);
                    break;
                case TreeEntryKind.File:
                    hashes[entry.RelativePath] = CopyFile(Url(source, entry), target, isCancelled, n => progress?.Invoke(entry.RelativePath, n));
                    break;
                case TreeEntryKind.Link:
                    try { Reparse.Create(target, entry.Link!); }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or Win32Exception)
                    {
                        throw new CopyException(CopyErrorKind.WriteFailed, target, $"ссылка не создана: {ex.Message}");
                    }
                    break;
            }
        }
        // Даты и атрибуты — в обратном порядке, чтобы «только чтение» у папок не мешало записи внутрь.
        for (int i = entries.Count - 1; i >= 0; i--)
        {
            var entry = entries[i];
            if (entry.IsLink) continue;
            ApplyMetadata(Url(destination, entry), entry, keepAttributes ? entry.Attributes & attributeMask : 0);
        }
        return hashes;
    }

    internal static void ApplyMetadata(string path, TreeEntry entry, uint attributes)
    {
        try
        {
            if (entry.IsDirectory)
            {
                if (entry.Created is { } created) Directory.SetCreationTimeUtc(path, created);
                if (entry.Modified is { } modified) Directory.SetLastWriteTimeUtc(path, modified);
            }
            else
            {
                if (entry.Created is { } created) File.SetCreationTimeUtc(path, created);
                if (entry.Modified is { } modified) File.SetLastWriteTimeUtc(path, modified);
            }
            if (attributes != 0)
            {
                uint current = Native.GetFileAttributesW(Native.Long(path));
                if (current != Native.INVALID_FILE_ATTRIBUTES) Native.SetFileAttributesW(Native.Long(path), current | attributes);
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        catch (ArgumentException) { }
    }

    /// <summary>Перечитывает копию с диска и сравнивает с хешами оригинала.</summary>
    public static void Verify(IReadOnlyList<TreeEntry> entries, IReadOnlyDictionary<string, string> hashes, string destination,
                              Func<bool>? isCancelled = null, Action<string, int>? progress = null)
    {
        isCancelled ??= () => false;
        foreach (var entry in entries)
        {
            if (isCancelled()) throw new OperationCanceledException();
            var target = Url(destination, entry);
            var name = DisplayName(destination, entry);
            switch (entry.Kind)
            {
                case TreeEntryKind.Directory:
                    if (FileSystem.Stat(target) is not { IsRegularDirectory: true }) throw new CopyException(CopyErrorKind.VerificationFailed, name);
                    break;
                case TreeEntryKind.File:
                    if (FileSystem.Stat(target) is not { IsRegularFile: true } stat || stat.Size != entry.Size
                        || !hashes.TryGetValue(entry.RelativePath, out var expected))
                        throw new CopyException(CopyErrorKind.VerificationFailed, name);
                    string actual;
                    try { actual = FileHasher.Sha256(target, isCancelled, n => progress?.Invoke(entry.RelativePath, n)); }
                    catch (IOException) { throw new CopyException(CopyErrorKind.VerificationFailed, name); }
                    if (actual != expected) throw new CopyException(CopyErrorKind.VerificationFailed, name);
                    break;
                case TreeEntryKind.Link:
                    if (Reparse.Read(target) is not { } link || !Paths.Same(link.Target, entry.Link!.Target) || link.Type != entry.Link.Type)
                        throw new CopyException(CopyErrorKind.VerificationFailed, name);
                    break;
            }
        }
    }

    /// <summary>Проверяет, что источник не менялся с момента обхода: размеры и даты файлов,
    /// а у папок — их состав.
    ///
    /// Дату папки сверять нельзя: Проводник меняет её, просто записав рядом свой desktop.ini или Thumbs.db.
    /// Такой пустяк не должен обрывать многочасовой перенос, поэтому у папки при изменившейся дате
    /// перечитывается список имён — важно только это.</summary>
    /// <param name="ignoring">имена, появление, исчезновение и изменение которых изменением не считается.</param>
    public static void AssertUnchanged(IReadOnlyList<TreeEntry> entries, string source, IReadOnlySet<string>? ignoring = null)
    {
        ignoring ??= Inspector.ExplorerJunk;
        var children = new Dictionary<string, HashSet<string>>(Paths.Comparer);
        foreach (var entry in entries)
        {
            if (entry.RelativePath.Length == 0) continue;
            var parent = Path.GetDirectoryName(entry.RelativePath) ?? "";
            if (!children.TryGetValue(parent, out var set)) children[parent] = set = new HashSet<string>(Paths.Comparer);
            set.Add(Path.GetFileName(entry.RelativePath));
        }
        foreach (var entry in entries)
        {
            // Служебный файл Проводника едет в копию, но сверять его нельзя: Проводник переписывает его сам.
            if (entry.RelativePath.Length > 0 && ignoring.Contains(entry.Name)) continue;
            var name = DisplayName(source, entry);
            var path = Url(source, entry);
            if (FileSystem.Stat(path) is not { } stat) throw new CopyException(CopyErrorKind.ChangedDuringCopy, name);
            switch (entry.Kind)
            {
                case TreeEntryKind.File:
                    if (!stat.IsRegularFile || stat.Size != entry.Size || stat.Modified != entry.Modified)
                        throw new CopyException(CopyErrorKind.ChangedDuringCopy, name);
                    break;
                case TreeEntryKind.Directory:
                    if (!stat.IsRegularDirectory) throw new CopyException(CopyErrorKind.ChangedDuringCopy, name);
                    if (stat.Modified != entry.Modified)
                    {
                        List<string> names;
                        try { names = FileSystem.Names(path); }
                        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                        {
                            throw new CopyException(CopyErrorKind.ChangedDuringCopy, name);
                        }
                        var now = new HashSet<string>(names.Where(n => !ignoring.Contains(n)), Paths.Comparer);
                        var then = new HashSet<string>((children.GetValueOrDefault(entry.RelativePath) ?? []).Where(n => !ignoring.Contains(n)), Paths.Comparer);
                        if (!now.SetEquals(then)) throw new CopyException(CopyErrorKind.ChangedDuringCopy, name);
                    }
                    break;
                case TreeEntryKind.Link:
                    if (Reparse.Read(path) is not { } link || !Paths.Same(link.Target, entry.Link!.Target))
                        throw new CopyException(CopyErrorKind.ChangedDuringCopy, name);
                    break;
            }
        }
    }

    /// <summary>Разбирает список, записанный <see cref="ChecksumList"/>. null — файл не в том формате.
    /// Пути в списке — через «/», как у shasum; список, записанный на Mac, читается так же.</summary>
    public static Dictionary<string, string>? ParseChecksumList(string text, string rootName)
    {
        var hashes = new Dictionary<string, string>(Paths.Comparer);
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.TrimEnd('\r');
            if (line.Length == 0) continue;
            bool escaped = line.StartsWith('\\');
            var body = escaped ? line[1..] : line;
            int separator = body.IndexOf("  ", StringComparison.Ordinal);
            if (separator < 0) return null;
            var hash = body[..separator];
            if (hash.Length != 64 || !hash.All(Uri.IsHexDigit)) return null;
            var path = body[(separator + 2)..];
            if (escaped) path = Unescape(path);
            if (path.StartsWith("*", StringComparison.Ordinal)) path = path[1..];
            if (path == rootName) hashes[""] = hash.ToLowerInvariant();
            else if (path.StartsWith(rootName + "/", StringComparison.Ordinal))
                hashes[path[(rootName.Length + 1)..].Replace('/', '\\')] = hash.ToLowerInvariant();
            else return null;
        }
        return hashes;
    }

    static string Unescape(string text)
    {
        var result = new StringBuilder();
        for (int i = 0; i < text.Length; i++)
        {
            if (text[i] == '\\' && i + 1 < text.Length)
            {
                i++;
                result.Append(text[i] == 'n' ? '\n' : text[i]);
            }
            else result.Append(text[i]);
        }
        return result.ToString();
    }

    /// <summary>Список в формате <c>sha256sum -c</c> (или <c>shasum -a 256 -c</c>): пути через «/»
    /// относительно папки, где лежит перенесённый объект.</summary>
    public static string ChecksumList(IReadOnlyDictionary<string, string> hashes, string rootName)
    {
        var lines = hashes.Keys.OrderBy(k => k, StringComparer.Ordinal).Select(relative =>
        {
            var path = relative.Length == 0 ? rootName : rootName + "/" + relative.Replace('\\', '/');
            var hash = hashes[relative];
            if (path.Contains('\\') || path.Contains('\n'))
                return "\\" + hash + "  " + path.Replace("\\", "\\\\").Replace("\n", "\\n");
            return hash + "  " + path;
        });
        return string.Join("\n", lines) + "\n";
    }
}

/// <summary>Служебные файлы рядом с архивом лежат на недоверенном диске: на месте любого из них может
/// оказаться ссылка на файл с этого компьютера.</summary>
public static class SafeFile
{
    /// <summary>Содержимое обычного файла не больше limit байт. Ссылка, папка или файл больше предела — null.</summary>
    public static byte[]? Read(string path, int limit)
    {
        using var handle = Native.CreateFileW(Native.Long(path), Native.GENERIC_READ, Native.FILE_SHARE_READ | Native.FILE_SHARE_WRITE,
                                              IntPtr.Zero, Native.OPEN_EXISTING, Native.FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
        if (handle.IsInvalid) return null;
        {
            if (Native.AttributesAndTag(handle) is not { } tag) return null;
            if ((tag.FileAttributes & (Native.FILE_ATTRIBUTE_DIRECTORY | Native.FILE_ATTRIBUTE_DEVICE)) != 0) return null;
            if ((tag.FileAttributes & Native.FILE_ATTRIBUTE_REPARSE_POINT) != 0 && Native.IsNameSurrogate(tag.ReparseTag)) return null;
        }
        long length = RandomAccess.GetLength(handle);
        if (length > limit) return null;
        var data = new byte[length];
        int total = 0;
        while (total < length)
        {
            int read = RandomAccess.Read(handle, data.AsSpan(total), total);
            if (read == 0) break;
            total += read;
        }
        return total == length ? data : null;
    }

    /// <summary>Создаёт новый файл: существующий файл или подложенная на его месте ссылка — ошибка, а не перезапись.</summary>
    public static void CreateExclusive(string path, byte[] contents)
    {
        var handle = Native.CreateFileW(Native.Long(path), Native.GENERIC_WRITE, 0, IntPtr.Zero, Native.CREATE_NEW, 0, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int code = Marshal.GetLastWin32Error();
            handle.Dispose();
            if (code is Native.ERROR_FILE_EXISTS or Native.ERROR_ALREADY_EXISTS) throw new CopyException(CopyErrorKind.DestinationExists, path);
            throw new CopyException(CopyErrorKind.WriteFailed, path, new Win32Exception(code).Message);
        }
        try
        {
            RandomAccess.Write(handle, contents, 0);
            RandomAccess.FlushToDisk(handle);
            handle.Dispose();
        }
        catch
        {
            handle.Dispose();
            Native.DeleteFileW(Native.Long(path));
            throw;
        }
    }
}
