using System.Runtime.InteropServices;

namespace Offload.Core;

/// <summary>Пути Windows: сравнение без учёта регистра (NTFS и exFAT регистр не различают)
/// и разворачивание ссылок в пути, которого ещё может не быть.</summary>
public static class Paths
{
    public static readonly StringComparer Comparer = StringComparer.OrdinalIgnoreCase;
    public const StringComparison Comparison = StringComparison.OrdinalIgnoreCase;

    public static bool Same(string? a, string? b) => a != null && b != null && string.Equals(Trim(a), Trim(b), Comparison);

    /// <summary>Лежит ли путь внутри папки (не совпадая с ней).</summary>
    public static bool IsInside(string path, string folder)
    {
        var root = Trim(folder);
        return Trim(path).StartsWith(root.EndsWith('\\') ? root : root + "\\", Comparison);
    }

    /// <summary>Сама папка или что-то внутри неё.</summary>
    public static bool IsWithin(string path, string folder) => Same(path, folder) || IsInside(path, folder);

    /// <summary>Путь без завершающей черты, кроме корня диска («E:\»).</summary>
    public static string Trim(string path)
    {
        if (path.Length <= 3) return path.Length == 2 && path[1] == ':' ? path + "\\" : path;
        return path.TrimEnd('\\', '/');
    }

    public static string Normalize(string path)
    {
        try { return Trim(Path.GetFullPath(path)); }
        catch (ArgumentException) { return path; }
        catch (NotSupportedException) { return path; }
        catch (PathTooLongException) { return path; }
    }

    /// <summary>Часть пути после папки: «Documents\Фото» для «C:\Users\q\Documents\Фото» и «C:\Users\q».</summary>
    public static string? Relative(string path, string folder)
    {
        if (!IsInside(path, folder)) return null;
        var root = Trim(folder);
        return Trim(path)[(root.EndsWith('\\') ? root.Length : root.Length + 1)..];
    }

    public static string[] Parts(string relative) => relative.Split(['\\', '/'], StringSplitOptions.RemoveEmptyEntries);

    public static string Name(string path) => Path.GetFileName(Trim(path)) is { Length: > 0 } name ? name : Trim(path);

    public static string Parent(string path) => Path.GetDirectoryName(Trim(path)) ?? Trim(path);

    public static string Extension(string name)
    {
        var ext = Path.GetExtension(name);
        return string.IsNullOrEmpty(ext) ? "" : ext[1..].ToLowerInvariant();
    }

    /// <summary>Разворачивает ссылки и точки соединения во всём пути, даже если его конца ещё нет.
    ///
    /// Возврат из журнала пишет ровно туда, где файла ещё нет, — и проверки пути должны смотреть
    /// не на ссылку, а на то, куда она ведёт. Короткие имена 8.3 («PROGRA~1») тоже разворачиваются:
    /// правила сравнивают настоящие имена папок.</summary>
    public static string Resolve(string path)
    {
        var current = Normalize(path);
        var tail = new List<string>();
        while (true)
        {
            if (Final(current) is { } real)
            {
                for (int i = tail.Count - 1; i >= 0; i--) real = Path.Combine(real, tail[i]);
                return Trim(real);
            }
            var parent = Path.GetDirectoryName(current);
            if (parent == null || Same(parent, current)) return Normalize(path);
            tail.Add(Path.GetFileName(current));
            current = parent;
        }
    }

    /// <summary>Настоящий путь существующего объекта — со всеми ссылками, развёрнутыми системой.</summary>
    static string? Final(string path)
    {
        using var handle = Native.CreateFileW(path, 0, Native.FILE_SHARE_ALL, IntPtr.Zero, Native.OPEN_EXISTING,
                                              Native.FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
        if (handle.IsInvalid) return null;
        var final = Native.FinalPath(handle);
        // Том без буквы диска: такой путь с правилами не сравнить — отвечаем как есть.
        if (final == null || final.StartsWith("Volume{", Comparison)) return null;
        return final;
    }

    /// <summary>Похож ли путь на обычный полный путь на диске с буквой: «E:\Offload\Фото».
    /// Без «\\?\», сетевых путей, потоков NTFS («файл:поток») и «..».</summary>
    public static bool IsPlainLocal(string path)
    {
        if (path.Length < 3 || !char.IsAsciiLetter(path[0]) || path[1] != ':' || path[2] != '\\') return false;
        if (path.IndexOf(':', 2) >= 0) return false;
        if (path.Contains('/') || path.Contains("\\\\")) return false;
        foreach (var part in Parts(path[3..]))
        {
            if (part is "." or "..") return false;
            if (part.EndsWith('.') || part.EndsWith(' ')) return false;
        }
        return Normalize(path) == Trim(path);
    }

    /// <summary>Корень диска пути: «E:\».</summary>
    public static string Root(string path) => Path.GetPathRoot(path) ?? path;

    public static string SystemDrive => Path.GetPathRoot(Environment.SystemDirectory) ?? @"C:\";

    public static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>Общая папка всех пользователей — то же, что /Users/Shared на Mac.</summary>
    public static string Public => Environment.GetEnvironmentVariable("PUBLIC") is { Length: > 0 } value
        ? value : Path.Combine(Path.GetDirectoryName(Home) ?? @"C:\Users", "Public");

    public static string LocalAppData => Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
}
