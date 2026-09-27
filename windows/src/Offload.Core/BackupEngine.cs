using System.Text;
using System.Text.RegularExpressions;

namespace Offload.Core;

public sealed class BackupReport
{
    public int Copied { get; set; }
    public int Unchanged { get; set; }
    public long BytesCopied { get; set; }
    /// <summary>Файлы с ключами и токенами, пропущенные в открытом бэкапе.</summary>
    public List<string> SecretsSkipped { get; } = [];
    public List<string> Problems { get; } = [];
}

public sealed class BackupException(string message) : Exception(message)
{
    public static BackupException DestinationInsideSource(string path) => new($"Папка бэкапа не может лежать внутри копируемой папки «{path}».");

    public static BackupException DestinationThroughLink(string path) =>
        new($"Путь к папке бэкапа проходит через ссылку «{path}» — писать по нему не буду: бэкап оказался бы не там, где вы думаете.");
}

/// <summary>Обновляемый бэкап: копируются только новые и изменившиеся файлы, каждый сверяется по SHA-256.
/// Из бэкапа ничего не удаляется — удалённые на компьютере файлы остаются в копии.</summary>
public static class BackupEngine
{
    /// <summary>Папки, которые восстанавливаются одной командой (npm install, pip install, сборка).</summary>
    public static readonly HashSet<string> DefaultExcludedNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "node_modules", ".venv", "venv", "__pycache__", ".next", ".nuxt", "dist", "build", ".build", "target",
        ".turbo", ".cache", ".parcel-cache", "DerivedData", "Pods", ".gradle", ".DS_Store", ".vs",
    };

    static readonly HashSet<string> SecretExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "pem", "key", "p12", "pfx", "pkcs12", "keystore", "jks", "kdbx", "ppk", "p8", "asc", "gpg", "ovpn",
        "tfvars", "tfstate", "keychain", "keychain-db", "snk", "publishsettings",
    };

    static readonly HashSet<string> SecretNames = new(StringComparer.OrdinalIgnoreCase)
    {
        ".npmrc", ".pypirc", ".netrc", "_netrc", ".git-credentials", ".envrc", ".pgpass", ".my.cnf", "credentials",
        "credentials.json", "credentials.toml", "service-account.json", "auth.json", ".yarnrc.yml",
        ".vault-token", ".htpasswd", "terraform.tfstate.backup", "hosts.yml",
        // В истории команд оседают токены, набранные прямо в командной строке.
        ".zsh_history", ".bash_history", ".python_history", ".psql_history", ".mysql_history", ".node_repl_history",
        "ConsoleHost_history.txt",
    };

    /// <summary>Имена ключей SSH; их копии («id_rsa.bak») — тоже ключи. Публичная половина (.pub) — нет.</summary>
    static readonly HashSet<string> SshKeyNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "id_ecdsa_sk", "id_ed25519_sk",
    };

    /// <summary>Каталоги, которые целиком состоят из ключей и учёток.</summary>
    static readonly HashSet<string> SecretFolders = new(StringComparer.OrdinalIgnoreCase)
    {
        ".ssh", ".gnupg", ".aws", ".kube", ".azure", ".gcloud", ".password-store",
    };

    /// <summary>Учётки, которые живут в ~/.config: GitHub CLI (hosts.yml с токеном) и gcloud.</summary>
    static readonly HashSet<string> SecretConfigFolders = new(StringComparer.OrdinalIgnoreCase) { "gh", "gcloud" };
    static readonly string[] TemplateSuffixes = [".example", ".sample", ".template", ".dist"];
    /// <summary>Файлы настроек, внутри которых часто лежит токен: их содержимое проверяется.</summary>
    static readonly HashSet<string> ScannedExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "json", "yml", "yaml", "toml", "ini", "cfg", "conf", "properties", "txt", "config", "xml", "ps1", "cmd", "bat",
    };

    /// <summary>Файлы с ключами и токенами: в открытый бэкап не попадают, только в сейф.</summary>
    public static bool IsSecret(string name)
    {
        var lower = name.ToLowerInvariant();
        // .env, .env.production, .env-local, .env_local, prod.env
        if (lower == ".env" || lower.StartsWith(".env.") || lower.StartsWith(".env-") || lower.StartsWith(".env_")
            || (lower.EndsWith(".env") && lower.Length > 4))
            return !TemplateSuffixes.Any(lower.EndsWith);
        if (SecretNames.Contains(lower)) return true;
        if (lower.StartsWith("client_secret") && lower.EndsWith(".json")) return true;
        if (lower == "terraform.tfstate") return true;
        if (!lower.EndsWith(".pub") && SshKeyNames.Contains(lower.Split('.', 2)[0])) return true;
        return SecretExtensions.Contains(Paths.Extension(lower));
    }

    public static bool IsSecretFolder(string name) => SecretFolders.Contains(name);

    /// <summary>Секрет ли объект по пути относительно корня бэкапа: по каталогу, по имени, а у файлов
    /// без расширения, файлов настроек и .git\config — по содержимому (ключ, токен, пароль в адресе).</summary>
    public static bool IsSecretPath(string relative, string root)
    {
        var parts = Paths.Parts(relative).Select(p => p.ToLowerInvariant()).ToArray();
        if (parts.Length == 0) return false;
        if (parts[..^1].Any(IsSecretFolder)) return true;
        int config = Array.IndexOf(parts[..Math.Max(0, parts.Length - 2)], ".config");
        if (config >= 0 && SecretConfigFolders.Contains(parts[config + 1])) return true;
        var name = parts[^1];
        if (IsSecret(name)) return true;
        var ext = Paths.Extension(name);
        bool isGitConfig = name == "config" && parts.Length >= 2 && parts[^2] == ".git";
        if (ext.Length > 0 && !ScannedExtensions.Contains(ext) && !isGitConfig) return false;
        return ContainsSecret(Path.Combine(root, relative));
    }

    static readonly string[] SecretMarkers =
    [
        "PRIVATE KEY", "\"private_key\"", "client-key-data", "aws_secret_access_key", "npmAuthToken", "_authToken",
        "ghp_", "gho_", "ghu_", "ghs_", "github_pat_", "glpat-", "xoxb-", "xoxp-", "sk-ant-", "sk-proj-",
    ];

    /// <summary>Ключ доступа AWS и пароль прямо в адресе (https://user:token@github.com/…, postgres://user:pass@…).</summary>
    static readonly Regex[] SecretPatterns =
    [
        new("AKIA[0-9A-Z]{16}", RegexOptions.Compiled),
        new(@"[A-Za-z][A-Za-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@", RegexOptions.Compiled),
    ];

    /// <summary>Небольшой обычный файл, в котором видно ключ или токен. Ссылка на месте файла не читается.</summary>
    static bool ContainsSecret(string path)
    {
        if (SafeFile.Read(path, 64 * 1024) is not { } data) return false;
        var text = Encoding.UTF8.GetString(data);
        if (SecretMarkers.Any(m => text.Contains(m, StringComparison.Ordinal))) return true;
        return SecretPatterns.Any(p => p.IsMatch(text));
    }

    public static BackupReport Run(IReadOnlyList<string> sources, string destination, IReadOnlySet<string>? excludedNames = null,
                                   Func<bool>? isCancelled = null, Action<string, long>? progress = null)
    {
        isCancelled ??= () => false;
        excludedNames ??= DefaultExcludedNames;
        var report = new BackupReport();
        var destinationPath = Paths.Normalize(destination);
        foreach (var source in sources)
        {
            var sourcePath = Paths.Normalize(source);
            if (Paths.IsWithin(destinationPath, sourcePath)) throw BackupException.DestinationInsideSource(source);
        }
        AssertNoLinks(destinationPath);
        Directory.CreateDirectory(destinationPath);

        foreach (var source in sources)
        {
            if (!Directory.Exists(source))
            {
                report.Problems.Add($"Нет папки: {source}");
                continue;
            }
            var rootName = Paths.Name(source);
            var target = Path.Combine(destinationPath, rootName);
            var walk = TreeWalker.Walk(source, strict: false, exclude: (relative, isDirectory) =>
            {
                var name = Path.GetFileName(relative);
                if (excludedNames.Contains(name)) return true;
                if (isDirectory)
                {
                    if (!IsSecretFolder(name)) return false;
                    report.SecretsSkipped.Add(rootName + "\\" + relative + "\\");
                    return true;
                }
                if (IsSecretPath(relative, source))
                {
                    report.SecretsSkipped.Add(rootName + "\\" + relative);
                    return true;
                }
                return false;
            }, isCancelled: isCancelled);
            report.Problems.AddRange(walk.problems.Select(p => $"{rootName}\\{p}: нет доступа"));

            // Папки назначения, которые оказались не папками (например, ссылкой на чужом диске).
            // Внутрь такой папки не пишем ничего: иначе файлы ушли бы по ссылке за пределы бэкапа.
            var refused = new List<string>();
            foreach (var entry in walk.entries)
            {
                if (isCancelled()) throw new OperationCanceledException();
                if (refused.Any(r => r.Length == 0 || entry.RelativePath.StartsWith(r + "\\", Paths.Comparison))) continue;
                var from = VerifiedCopy.Url(source, entry);
                var to = VerifiedCopy.Url(target, entry);
                var label = entry.RelativePath.Length == 0 ? rootName : rootName + "\\" + entry.RelativePath;
                try
                {
                    switch (entry.Kind)
                    {
                        case TreeEntryKind.Directory:
                            EnsureDirectory(to);
                            break;
                        case TreeEntryKind.Link:
                            if (Reparse.Read(to) is { } existing && Paths.Same(existing.Target, entry.Link!.Target))
                            {
                                report.Unchanged++;
                                continue;
                            }
                            if (FileSystem.Stat(to) is { } stat)
                            {
                                if (!stat.IsLink) throw new CopyException(CopyErrorKind.DestinationExists, to);
                                FileSystem.DeleteTree(to);
                            }
                            Reparse.Create(to, entry.Link!);
                            report.Copied++;
                            break;
                        case TreeEntryKind.File:
                            bool copied = SyncFile(from, to, entry.Size, entry.Modified, isCancelled, n => progress?.Invoke(label, n));
                            if (copied)
                            {
                                report.Copied++;
                                report.BytesCopied += entry.Size;
                            }
                            else report.Unchanged++;
                            break;
                    }
                }
                catch (OperationCanceledException) { throw; }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or CopyException or System.ComponentModel.Win32Exception)
                {
                    if (entry.IsDirectory) refused.Add(entry.RelativePath);
                    report.Problems.Add($"{label}: {ex.Message}");
                }
            }
        }
        return report;
    }

    /// <summary>Ни один существующий компонент пути назначения на внешнем диске не должен быть ссылкой:
    /// на подготовленном диске «Offload Backup» может вести на папку на этом компьютере.</summary>
    internal static void AssertNoLinks(string destination)
    {
        var root = Paths.Root(destination);
        var current = Paths.Trim(destination);
        while (!Paths.Same(current, root))
        {
            if (FileSystem.Stat(current) is { IsLink: true }) throw BackupException.DestinationThroughLink(current);
            var parent = Path.GetDirectoryName(current);
            if (parent == null) break;
            current = parent;
        }
    }

    static void EnsureDirectory(string path)
    {
        if (FileSystem.Stat(path) is { } stat)
        {
            if (!stat.IsRegularDirectory) throw new CopyException(CopyErrorKind.DestinationExists, path);
            return;
        }
        FileSystem.CreateDirectoryExclusive(path);
    }

    /// <summary>Копирует файл, если копии нет или она отличается размером или датой.
    /// Новая версия пишется во временный файл, сверяется и только потом заменяет старую.</summary>
    public static bool SyncFile(string source, string destination, long size, DateTime? modified,
                                Func<bool>? isCancelled = null, Action<int>? progress = null)
    {
        if (FileSystem.Stat(destination) is { } existing)
        {
            if (!existing.IsRegularFile) throw new CopyException(CopyErrorKind.DestinationExists, destination);
            // exFAT хранит время с точностью до 10 мс, FAT — до 2 секунд.
            if (existing.Size == size && existing.Modified is { } date && modified is { } then && Math.Abs((date - then).TotalSeconds) <= 2)
                return false;
        }
        var temporary = Path.Combine(Paths.Parent(destination), ".offload-" + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            var hash = VerifiedCopy.CopyFile(source, temporary, isCancelled, progress);
            if (FileHasher.Sha256(temporary, isCancelled) != hash) throw new CopyException(CopyErrorKind.VerificationFailed, Paths.Name(destination));
            if (modified is { } stamp) File.SetLastWriteTimeUtc(temporary, stamp);
            if (FileSystem.Exists(destination)) FileSystem.ClearReadOnly(destination);
            File.Move(temporary, destination, overwrite: true);
        }
        catch
        {
            try { if (FileSystem.Exists(temporary)) File.Delete(temporary); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            throw;
        }
        return true;
    }
}
