using System.Globalization;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Offload.Core;

public enum VaultErrorKind
{
    WeakPassword, AlreadyExists, NotEncrypted, WrongPassword, MountFailed, Busy, HeaderRejected, GrowFailed, CloseFailed, Unavailable,
}

public sealed class VaultException : Exception
{
    public VaultErrorKind Kind { get; }
    public string Detail { get; }

    public VaultException(VaultErrorKind kind, string detail = "") : base(Describe(kind, detail))
    {
        Kind = kind;
        Detail = detail;
    }

    static string Describe(VaultErrorKind kind, string detail) => kind switch
    {
        VaultErrorKind.WeakPassword =>
            $"Пароль слишком слабый: нужно не меньше {SecretsVault.MinimumPasswordLength} символов и стойкость от {(int)PasswordStrength.AcceptableBits} бит.",
        VaultErrorKind.AlreadyExists => "Сейф уже существует.",
        // Говорим именно «не подтверждено»: снаружи случай «образ без шифрования» и случай
        // «подделанный заголовок, BitLocker шифрования не видит» выглядят одинаково.
        VaultErrorKind.NotEncrypted => "Шифрование образа не подтверждено — складывать в него данные нельзя.",
        VaultErrorKind.WrongPassword => "Неверный пароль.",
        VaultErrorKind.MountFailed => $"Не удалось открыть сейф: {detail}",
        VaultErrorKind.Busy => "В сейфе открыты файлы. Закройте их в других программах и повторите.",
        VaultErrorKind.HeaderRejected => $"Заголовок не восстановлен: {detail}",
        VaultErrorKind.GrowFailed => $"Предел сейфа не увеличен: {detail}",
        VaultErrorKind.CloseFailed => $"Не удалось закрыть сейф: {detail}",
        _ => detail,
    };
}

public sealed class SecretsReport
{
    public int Copied { get; set; }
    public int Unchanged { get; set; }
    /// <summary>Приватные SSH-ключи без парольной фразы.</summary>
    public List<string> UnprotectedKeys { get; set; } = [];
    public List<string> Problems { get; } = [];
}

/// <summary>Операции с сейфом, которым нужны права администратора: подключить образ, открыть BitLocker,
/// отключить. В программе их выполняет отдельный процесс с повышенными правами (один запрос UAC за сеанс),
/// в проверках — сам процесс.</summary>
public interface IVaultBackend
{
    void Create(string image, long maxBytes, string label, string password, string userSid);
    /// <summary>Подключает и открывает; ответ — корень тома («S:\»).</summary>
    string Attach(string image, string password, string userSid);
    void Detach(string mountRoot, bool force);
    void Grow(string image, long maxBytes, string password);
    string Compact(string image, string password);
    void ChangePassword(string image, string oldPassword, string newPassword);
    /// <summary>Подключает, пробует пароль и отключает — для проверки восстановленного заголовка.</summary>
    void TryUnlock(string image, string password);
}

/// <summary>Сейф — зашифрованный BitLocker (XTS-AES-256) образ VHDX с NTFS внутри на внешнем диске.
///
/// Пароль задаёт человек; OffLoadAI его не хранит и не пишет в командную строку, которую видят другие
/// программы: он уходит напрямую в BitLocker через WMI. Своего шифрования OffLoadAI не изобретает —
/// шифрует и проверяет Windows.</summary>
public sealed class SecretsVault
{
    public const string VolumeName = "Offload Safe";
    public const int MinimumPasswordLength = 16;
    /// <summary>Имя, под которым OffLoadAI создаёт сейф в корне внешнего диска.</summary>
    public const string SafeImageName = "Offload Safe.vhdx";
    public const string SafeVolumeName = "Offload Safe";

    public static IVaultBackend? Backend { get; set; }

    static IVaultBackend RequireBackend() =>
        Backend ?? throw new VaultException(VaultErrorKind.Unavailable, "Операции с сейфом недоступны.");

    public string ImagePath { get; }

    public SecretsVault(string imagePath) => ImagePath = imagePath;

    /// <summary>Где на диске лежит сейф: выбранный человеком образ, затем свой, затем любой зашифрованный
    /// образ в корне. Если нет ни одного — путь, по которому сейф будет создан.</summary>
    public SecretsVault(VolumeInfo volume, string? preferred = null, Dictionary<string, Attachment>? attached = null)
    {
        var own = Path.Combine(volume.MountPoint, SafeImageName);
        if (preferred != null && Paths.Same(Paths.Parent(preferred), volume.MountPoint) && File.Exists(preferred)) ImagePath = preferred;
        else if (File.Exists(own)) ImagePath = own;
        else ImagePath = Candidates(volume.MountPoint, attached).FirstOrDefault() ?? own;
    }

    /// <summary>Все зашифрованные образы в корне диска — чтобы человек сам выбрал, какой из них его сейф,
    /// если их несколько. Свой первым, остальные по имени.</summary>
    public static List<string> Candidates(string root, Dictionary<string, Attachment>? attached = null)
    {
        List<string> images;
        try { images = Directory.EnumerateFiles(root, "*.vhdx").ToList(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return []; }
        if (images.Count == 0) return [];
        attached ??= AttachedImages();
        return images.Where(i => new SecretsVault(i).GetStatus(attached).IsEncrypted)
            .OrderBy(i => Paths.Name(i).Equals(SafeImageName, Paths.Comparison) ? 0 : 1)
            .ThenBy(i => Paths.Name(i), StringComparer.CurrentCultureIgnoreCase)
            .ToList();
    }

    public bool Exists => File.Exists(ImagePath);

    // MARK: Открыт ли и зашифрован ли

    /// <summary>Образ, который Windows уже подключила.</summary>
    public sealed record Attachment(
        /// <summary>Корень открытого тома; null — подключён, но заблокирован или без буквы.</summary>
        string? MountPoint,
        /// <summary>BitLocker на томе, как его видит Windows. Подложенным файлом его не подделать.</summary>
        bool Encrypted,
        bool Locked);

    /// <summary>Все подключённые образы: путь к файлу образа → подключение. Прав администратора не нужно.</summary>
    public static Dictionary<string, Attachment> AttachedImages() => AttachedImagesIfKnown() ?? new(Paths.Comparer);

    /// <summary>То же, но null, если Windows не ответила: «не знаю» — не то же самое, что «ничего не подключено».</summary>
    public static Dictionary<string, Attachment>? AttachedImagesIfKnown()
    {
        try { return VirtualDisks.Attached(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception) { return null; }
    }

    /// <summary>Что с сейфом сейчас — без пароля и без системных окон.</summary>
    public sealed record Status(bool Exists, bool IsEncrypted, EncryptionInfo? Info, string? MountPoint, bool IsAttached);

    /// <summary>Открыт ли сейф и зашифрован ли он.
    ///
    /// Закрытый образ разбирается прямо из файла (<see cref="BitLockerHeader"/>): требуются оба признака —
    /// шифрование и хотя бы один пароль, которым его можно открыть, и никакого «открытого ключа».
    /// Про подключённый образ отвечает сама Windows: состояние BitLocker тома.</summary>
    public Status GetStatus(Dictionary<string, Attachment>? attached = null)
    {
        if (!Exists) return new Status(false, false, null, null, false);
        attached ??= AttachedImages();
        if (attached.TryGetValue(Paths.Resolve(ImagePath), out var attachment))
            return new Status(true, attachment.Encrypted, null, attachment.Locked ? null : attachment.MountPoint, true);
        var info = BitLockerHeader.Info(ImagePath);
        return new Status(true, info?.OpensWithPassword ?? false, info, null, false);
    }

    public bool IsEncrypted => GetStatus().IsEncrypted;

    /// <summary>Предел роста образа — из самого файла VHDX, пароль не нужен.</summary>
    public long? SizeLimit
    {
        get
        {
            using var disk = Vhdx.Open(ImagePath);
            return disk?.DiskSize;
        }
    }

    /// <summary>Сколько образ занимает на внешнем диске сейчас.</summary>
    public long AllocatedBytes => FileSystem.Stat(ImagePath) is { } stat
        ? FileSystem.Allocated(ImagePath, stat.Size, stat.Attributes, 0) : 0;

    // MARK: Создать, увеличить, пароль

    /// <summary>Разрежённый образ: места он занимает столько, сколько в нём лежит, а предел —
    /// сколько выбрал человек. Мало окажется — предел увеличивается (<see cref="Grow"/>), данные остаются.</summary>
    public void Create(string password, long maxBytes, string volumeName = VolumeName)
    {
        if (!PasswordStrength.Evaluate(password).IsAcceptable) throw new VaultException(VaultErrorKind.WeakPassword);
        if (Exists) throw new VaultException(VaultErrorKind.AlreadyExists);
        long bytes = Math.Max(64L << 20, maxBytes) / (1 << 20) * (1 << 20);
        RequireBackend().Create(ImagePath, bytes, volumeName, password, CurrentUserSid);
        if (!IsEncrypted) throw new VaultException(VaultErrorKind.NotEncrypted);
    }

    /// <summary>Увеличивает предел сейфа, не трогая содержимое. Нужны пароль и закрытый сейф.</summary>
    public void Grow(long maxBytes, string password)
    {
        var status = GetStatus();
        if (status.IsAttached) throw new VaultException(VaultErrorKind.Busy);
        if (!status.IsEncrypted) throw new VaultException(VaultErrorKind.NotEncrypted);
        long current = SizeLimit ?? 0;
        if (maxBytes < current - (64L << 20)) throw new VaultException(VaultErrorKind.GrowFailed, "уменьшать сейф нельзя — только увеличивать");
        RequireBackend().Grow(ImagePath, Math.Max(maxBytes, current) / (1 << 20) * (1 << 20), password);
    }

    /// <summary>Смена пароля. Ключ шифрования данных при этом не меняется — перешифровывается только
    /// ключ тома, поэтому это быстро. Та же оговорка, что у VeraCrypt: копия заголовка, снятая раньше,
    /// по-прежнему открывается СТАРЫМ паролем.</summary>
    public void ChangePassword(string oldPassword, string newPassword)
    {
        if (!PasswordStrength.Evaluate(newPassword).IsAcceptable) throw new VaultException(VaultErrorKind.WeakPassword);
        var status = GetStatus();
        if (status.IsAttached) throw new VaultException(VaultErrorKind.Busy);
        if (!status.IsEncrypted) throw new VaultException(VaultErrorKind.NotEncrypted);
        RequireBackend().ChangePassword(ImagePath, oldPassword, newPassword);
    }

    /// <summary>Возвращает внешнему диску место, освободившееся внутри сейфа. Само оно не возвращается:
    /// удалённые внутри файлы продолжают занимать блоки образа, пока его не сжать. Нужны пароль и закрытый сейф.</summary>
    public string Compact(string password)
    {
        var status = GetStatus();
        if (status.IsAttached) throw new VaultException(VaultErrorKind.Busy);
        if (!status.IsEncrypted) throw new VaultException(VaultErrorKind.NotEncrypted);
        return RequireBackend().Compact(ImagePath, password);
    }

    // MARK: Резервная копия заголовка

    /// <summary>Копия заголовка, как в VeraCrypt: в метаданных BitLocker лежит ключ тома, зашифрованный паролем.
    /// Испортятся они все три — пропадёт всё содержимое, даже при верном пароле. Копия защищена паролем так же,
    /// как сами метаданные, и хранить её можно где угодно (но лучше не на том же диске). Оговорка: после смены
    /// пароля старая копия открывается старым паролем — её надо снять заново, а прежнюю удалить.</summary>
    public sealed class HeaderBackup
    {
        [JsonPropertyName("format")] public int Format { get; set; } = 2;
        [JsonPropertyName("kind")] public string Kind { get; set; } = "bitlocker-vhdx";
        [JsonPropertyName("imageName")] public string ImageName { get; set; } = "";
        [JsonPropertyName("uuid")] public string? Uuid { get; set; }
        [JsonPropertyName("created")] public DateTime Created { get; set; }
        [JsonPropertyName("partitionOffset")] public long PartitionOffset { get; set; }
        [JsonPropertyName("offsets")] public long[] Offsets { get; set; } = [];
        [JsonPropertyName("blocks")] public byte[][] Blocks { get; set; } = [];
    }

    /// <summary>Только у закрытого сейфа: у открытого метаданные держит BitLocker.</summary>
    public string BackupHeader(string directory)
    {
        var status = GetStatus();
        if (status.IsAttached) throw new VaultException(VaultErrorKind.Busy);
        if (!status.IsEncrypted) throw new VaultException(VaultErrorKind.NotEncrypted);
        var (layout, blocks) = BitLockerHeader.Snapshot(ImagePath);
        var backup = new HeaderBackup
        {
            ImageName = Paths.Name(ImagePath),
            Uuid = layout.VolumeGuid.ToString("D").ToUpperInvariant(),
            Created = DateTime.UtcNow,
            PartitionOffset = layout.PartitionOffset,
            Offsets = layout.BlockOffsets,
            Blocks = blocks,
        };
        var stamp = backup.Created.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var path = Path.Combine(directory, $"{Path.GetFileNameWithoutExtension(ImagePath)} — заголовок {stamp}.offload-header");
        if (FileSystem.Exists(path)) throw new VaultException(VaultErrorKind.AlreadyExists);
        try { SafeFile.CreateExclusive(path, JsonSerializer.SerializeToUtf8Bytes(backup, HeaderOptions)); }
        catch (CopyException ex) when (ex.Kind == CopyErrorKind.DestinationExists) { throw new VaultException(VaultErrorKind.AlreadyExists); }
        // Копия заголовка — материал для перебора пароля: доступ только владельцу.
        RestrictFileToOwner(path);
        return path;
    }

    static readonly JsonSerializerOptions HeaderOptions = new() { WriteIndented = true };

    /// <summary>Отложенные на время восстановления метаданные: если работа оборвётся, по ним сейф вернут вручную.</summary>
    public string PreviousHeaderPath => ImagePath + ".offload-previous-header";

    /// <summary>Возвращает заголовок из копии. Прежние метаданные откладываются рядом, копия ставится на место,
    /// и сейф пробуется открыть паролем; не открылся — прежние метаданные возвращаются как были.</summary>
    public void RestoreHeader(string file, string password)
    {
        if (GetStatus().IsAttached) throw new VaultException(VaultErrorKind.Busy);
        HeaderBackup? backup = null;
        try
        {
            var data = SafeFile.Read(file, 4 << 20);
            if (data != null) backup = JsonSerializer.Deserialize<HeaderBackup>(data, HeaderOptions);
        }
        catch (JsonException) { }
        if (backup is not { Kind: "bitlocker-vhdx", Offsets.Length: 3, Blocks.Length: 3 }
            || backup.Blocks.Any(b => b.Length != BitLockerHeader.BlockRegion
                                      || System.Text.Encoding.ASCII.GetString(b, 0, 8) != "-FVE-FS-"))
            throw new VaultException(VaultErrorKind.HeaderRejected, "файл не похож на копию заголовка OffLoadAI");
        // Разметку берём из самого образа: раздел и места блоков. Испорчены блоки — места всё равно известны
        // из загрузочного сектора, а испорчен и он — из копии, если раздел тот же.
        var (partitionOffset, _, located) = BitLockerHeader.Locate(ImagePath);
        if (backup.PartitionOffset != partitionOffset || (located != null && !located.SequenceEqual(backup.Offsets)))
            throw new VaultException(VaultErrorKind.HeaderRejected, "копия не подходит к разметке этого сейфа");
        var offsets = located ?? backup.Offsets;
        var previousBlocks = BitLockerHeader.ReadRaw(ImagePath, partitionOffset, offsets);
        if (BitLockerHeader.VolumeGuid(previousBlocks) is { } currentGuid && backup.Uuid != null
            && !backup.Uuid.Equals(currentGuid.ToString("D"), StringComparison.OrdinalIgnoreCase))
            throw new VaultException(VaultErrorKind.HeaderRejected, "копия снята с другого сейфа");
        if (BitLockerHeader.VolumeGuid(backup.Blocks) is { } backupGuid && backup.Uuid != null
            && !backup.Uuid.Equals(backupGuid.ToString("D"), StringComparison.OrdinalIgnoreCase))
            throw new VaultException(VaultErrorKind.HeaderRejected, "копия повреждена");
        // Отложенные метаданные от прерванного восстановления могут оказаться единственными настоящими:
        // молча удалить их значило бы потерять сейф.
        if (FileSystem.Exists(PreviousHeaderPath))
            throw new VaultException(VaultErrorKind.HeaderRejected,
                $"рядом с сейфом остались метаданные от прерванного восстановления («{Paths.Name(PreviousHeaderPath)}»). Если сейф не открывается, восстановите заголовок из этого файла");
        var aside = new HeaderBackup
        {
            ImageName = Paths.Name(ImagePath), Uuid = BitLockerHeader.VolumeGuid(previousBlocks)?.ToString("D").ToUpperInvariant(),
            Created = DateTime.UtcNow, PartitionOffset = partitionOffset, Offsets = offsets, Blocks = previousBlocks,
        };
        SafeFile.CreateExclusive(PreviousHeaderPath, JsonSerializer.SerializeToUtf8Bytes(aside, HeaderOptions));
        RestrictFileToOwner(PreviousHeaderPath);
        try
        {
            BitLockerHeader.Write(ImagePath, partitionOffset, offsets, backup.Blocks);
            RequireBackend().TryUnlock(ImagePath, password);
        }
        catch (Exception error)
        {
            try { BitLockerHeader.Write(ImagePath, partitionOffset, offsets, previousBlocks); }
            catch (Exception restore)
            {
                throw new VaultException(VaultErrorKind.HeaderRejected,
                    $"копия не подошла, а прежние метаданные вернуть не удалось: {restore.Message}. Они лежат в «{Paths.Name(PreviousHeaderPath)}» — восстановите заголовок из этого файла");
            }
            TryDeleteFile(PreviousHeaderPath);
            if (error is VaultException { Kind: VaultErrorKind.WrongPassword }) throw new VaultException(VaultErrorKind.HeaderRejected, "пароль к этой копии не подходит");
            throw;
        }
        // Прежние метаданные рядом не оставляем: они открылись бы старым паролем.
        TryDeleteFile(PreviousHeaderPath);
    }

    // MARK: Открыть и закрыть

    public string Attach(string password)
    {
        var status = GetStatus();
        // Уже открыт — OffLoadAI или Проводником: второй раз не подключаем, берём тот же том.
        if (status.MountPoint is { } mount)
        {
            if (!status.IsEncrypted) throw new VaultException(VaultErrorKind.NotEncrypted);
            return mount;
        }
        // Дешёвый отсев до подключения: образ без BitLocker открывать незачем.
        if (!status.IsEncrypted) throw new VaultException(VaultErrorKind.NotEncrypted);
        return RequireBackend().Attach(ImagePath, password, CurrentUserSid);
    }

    public string? CurrentMountPoint() => GetStatus().MountPoint;

    /// <summary>Закрыть сейф. Без force: если в нём открыты файлы, закрытие откажет с Busy, и чужая
    /// работа не оборвётся. Сразу после записи том на несколько секунд держат индексатор и антивирус:
    /// первая попытка тогда отвечает «занят», хотя человек ничего не открывал. Поэтому занятый том
    /// пробуем закрыть ещё несколько раз с паузой.</summary>
    public static void Detach(string mountPoint, bool force = false, int attempts = 5)
    {
        // Том уже закрыли в обход OffLoadAI (Проводник, «Извлечь»): закрывать нечего.
        if (!Directory.Exists(mountPoint)) return;
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                RequireBackend().Detach(mountPoint, force);
                return;
            }
            catch (VaultException ex) when (ex.Kind == VaultErrorKind.Busy && !force && attempt < Math.Max(1, attempts))
            {
                Thread.Sleep(1500);
            }
        }
    }

    /// <summary>Закрыть том во что бы то ни стало и молча — там, где мы сами его только что открыли
    /// и уже решили, что пользоваться им нельзя.</summary>
    public static void DetachIgnoringErrors(string mountPoint)
    {
        try { Detach(mountPoint, attempts: 1); return; } catch (Exception) { }
        try { Detach(mountPoint, force: true, attempts: 1); } catch (Exception) { }
    }

    /// <summary>Зашифрованный ли это образ диска — VHDX в Загрузках, копия в группе одинаковых файлов.
    /// Нет ответа — считаем зашифрованным: ответ нужен разбору, чтобы не удалить личный образ.</summary>
    public static bool IsEncryptedImage(string path, Dictionary<string, Attachment>? attached = null)
    {
        if ((attached ?? AttachedImages()).TryGetValue(Paths.Resolve(path), out var attachment)) return attachment.Encrypted;
        return BitLockerHeader.Info(path)?.Encrypted ?? true;
    }

    // MARK: Ключи и токены

    public static readonly string[] Dotfiles =
        [".gitconfig", ".npmrc", ".pypirc", ".netrc", "_netrc", ".git-credentials", ".bashrc", ".bash_profile", ".zshrc", ".wslconfig"];

    /// <summary>Складывает в открытый сейф: ~\.ssh, дотфайлы, учётку GitHub CLI, профили PowerShell,
    /// базы KeePass и секреты проектов с сохранением относительных путей.</summary>
    public static SecretsReport Fill(string mountPoint, string home, IReadOnlyList<string> projectRoots, Func<bool>? isCancelled = null)
    {
        isCancelled ??= () => false;
        var report = new SecretsReport();

        void Sync(IEnumerable<TreeEntry> entries, string source, string target)
        {
            foreach (var entry in entries)
            {
                if (isCancelled()) return;
                var from = VerifiedCopy.Url(source, entry);
                var to = VerifiedCopy.Url(target, entry);
                try
                {
                    switch (entry.Kind)
                    {
                        case TreeEntryKind.Directory:
                            Directory.CreateDirectory(to);
                            break;
                        case TreeEntryKind.File:
                            Directory.CreateDirectory(Paths.Parent(to));
                            if (BackupEngine.SyncFile(from, to, entry.Size, entry.Modified, isCancelled: isCancelled)) report.Copied++;
                            else report.Unchanged++;
                            break;
                        case TreeEntryKind.Link:
                            // Дотфайлы бывают ссылками (chezmoi, stow). Копируем то, на что ссылка ведёт, если это обычный файл.
                            var real = ResolveLinkTarget(from);
                            if (real == null || FileSystem.Stat(real) is not { IsRegularFile: true } stat)
                            {
                                report.Problems.Add($"{from}: ссылка не на обычный файл — не скопирована");
                                continue;
                            }
                            Directory.CreateDirectory(Paths.Parent(to));
                            if (BackupEngine.SyncFile(real, to, stat.Size, stat.Modified, isCancelled: isCancelled)) report.Copied++;
                            else report.Unchanged++;
                            break;
                    }
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or CopyException)
                {
                    report.Problems.Add($"{from}: {ex.Message}");
                }
            }
        }

        List<TreeEntry>? Walk(string path, bool strict)
        {
            try { return TreeWalker.Walk(path, strict, isCancelled: isCancelled).entries; }
            catch (Exception ex) when (ex is CopyException or IOException or UnauthorizedAccessException)
            {
                if (FileSystem.Exists(path)) report.Problems.Add($"{path}: {ex.Message}");
                return null;
            }
        }
        static bool IsFileOrLink(TreeEntry entry) => entry.IsFile || entry.IsLink;

        var ssh = Path.Combine(home, ".ssh");
        if (FileSystem.Exists(ssh))
        {
            try
            {
                var walk = TreeWalker.Walk(ssh, strict: false, isCancelled: isCancelled);
                Sync(walk.entries, ssh, Path.Combine(mountPoint, "ssh"));
                report.Problems.AddRange(walk.problems.Select(p => ".ssh\\" + p));
                report.UnprotectedKeys = UnprotectedKeys(walk.entries, ssh);
            }
            catch (Exception ex) when (ex is CopyException or IOException or UnauthorizedAccessException)
            {
                report.Problems.Add($"{ssh}: {ex.Message}");
            }
        }

        var dotfilesTarget = Path.Combine(mountPoint, "dotfiles");
        foreach (var name in Dotfiles)
        {
            var path = Path.Combine(home, name);
            if (!FileSystem.Exists(path) || Walk(path, strict: true)?.FirstOrDefault() is not { } entry || !IsFileOrLink(entry)) continue;
            Sync([entry], path, Path.Combine(dotfilesTarget, name));
        }

        // Учётка GitHub CLI: на Windows она в %APPDATA%\GitHub CLI, у перенесённых настроек — в ~\.config\gh.
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        foreach (var (gh, target) in new[] { (Path.Combine(appData, "GitHub CLI"), "config\\GitHub CLI"), (Path.Combine(home, ".config", "gh"), "config\\gh") })
        {
            if (FileSystem.Exists(gh) && Walk(gh, strict: false) is { } entries) Sync(entries, gh, Path.Combine(mountPoint, target));
        }

        // Профили PowerShell: в них бывают токены, прописанные в переменные окружения.
        foreach (var folder in new[] { "PowerShell", "WindowsPowerShell" })
        {
            var documents = Path.Combine(home, "Documents", folder);
            if (!Directory.Exists(documents)) continue;
            foreach (var profile in Directory.EnumerateFiles(documents, "*profile.ps1"))
            {
                if (Walk(profile, strict: true)?.FirstOrDefault() is { } entry && IsFileOrLink(entry))
                    Sync([entry], profile, Path.Combine(mountPoint, "powershell", folder, Paths.Name(profile)));
            }
        }

        // Пути внутри project-secrets — относительно папки с проектами, чтобы вернуть всё одним копированием.
        // Если две папки дают один и тот же путь, второй файл не пишется.
        var projectTarget = Path.Combine(mountPoint, "project-secrets");
        var claimed = new Dictionary<string, string>(Paths.Comparer);
        foreach (var root in projectRoots)
        {
            (List<TreeEntry> entries, List<string> problems) walk;
            try
            {
                walk = TreeWalker.Walk(root, strict: false,
                    exclude: (relative, isDirectory) => isDirectory && BackupEngine.DefaultExcludedNames.Contains(Path.GetFileName(relative)),
                    isCancelled: isCancelled);
            }
            catch (Exception ex) when (ex is CopyException or IOException or UnauthorizedAccessException)
            {
                report.Problems.Add($"{root}: {ex.Message}");
                continue;
            }
            var secrets = new List<TreeEntry>();
            foreach (var entry in walk.entries.Where(e => e.IsFile && BackupEngine.IsSecretPath(e.RelativePath, root)))
            {
                if (claimed.TryGetValue(entry.RelativePath, out var owner) && !Paths.Same(owner, root))
                {
                    report.Problems.Add($"{Paths.Name(root)}\\{entry.RelativePath}: такой же путь уже есть в «{Paths.Name(owner)}» — пропущен, чтобы не затереть");
                    continue;
                }
                claimed[entry.RelativePath] = root;
                secrets.Add(entry);
            }
            Sync(secrets, root, projectTarget);
        }

        var keepassTarget = Path.Combine(mountPoint, "keepass");
        foreach (var folder in new[] { "Downloads", "Documents", "Desktop" })
        {
            var directory = Path.Combine(home, folder);
            List<string> names;
            try { names = FileSystem.Names(directory); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { continue; }
            foreach (var name in names.Where(n => Paths.Extension(n) == "kdbx").OrderBy(n => n, StringComparer.Ordinal))
            {
                var path = Path.Combine(directory, name);
                if (Walk(path, strict: true)?.FirstOrDefault() is not { } entry || !IsFileOrLink(entry)) continue;
                Sync([entry], path, Path.Combine(keepassTarget, name));
            }
        }

        // Свою инструкцию не пишем поверх чужой: в сейф могли положить заметки вручную.
        var note = Path.Combine(mountPoint, "КАК-ВОССТАНОВИТЬ.txt");
        if (!FileSystem.Exists(note))
        {
            try { File.WriteAllText(note, RestoreNote, new System.Text.UTF8Encoding(true)); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return report;
    }

    static string? ResolveLinkTarget(string path)
    {
        try { return File.ResolveLinkTarget(path, returnFinalTarget: true)?.FullName; }
        catch (IOException) { return null; }
    }

    /// <summary>Приватные ключи без парольной фразы: ssh-keygen прочитает такой с пустым паролем.</summary>
    internal static List<string> UnprotectedKeys(IEnumerable<TreeEntry> entries, string root)
    {
        var result = new List<string>();
        foreach (var entry in entries.Where(e => e.IsFile && e.Size < 64 * 1024))
        {
            var path = Path.Combine(root, entry.RelativePath);
            var head = SafeFile.Read(path, 64 * 1024);
            if (head == null || !System.Text.Encoding.UTF8.GetString(head, 0, Math.Min(head.Length, 128)).Contains("PRIVATE KEY")) continue;
            try
            {
                var result2 = Runner.Run("ssh-keygen", ["-y", "-P", "", "-f", path], timeout: TimeSpan.FromSeconds(10));
                if (result2.Succeeded) result.Add(entry.RelativePath);
            }
            catch (RunnerException) { }
        }
        return result;
    }

    internal const string RestoreNote = """
        СЕЙФ OFFLOAD
        ============
        ssh\              → в %USERPROFILE%\.ssh
                            (права: только вы — icacls "%USERPROFILE%\.ssh\id_*" /inheritance:r /grant:r "%USERNAME%:F",
                            иначе ssh откажется использовать ключи)
        dotfiles\         → в домашнюю папку (.gitconfig, .npmrc, .netrc…)
        config\GitHub CLI\ → в %APPDATA%\GitHub CLI (авторизация GitHub CLI)
        powershell\       → профили PowerShell в «Документы»
        keepass\          → базы паролей KeePass (зашифрованы сами по себе)
        project-secrets\  → наложить поверх папки с проектами, пути сохранены:
                            robocopy project-secrets <папка с проектами> /E

        Закрывайте сейф после работы: пока он открыт, файлы не защищены.
        """;

    // MARK: Служебное

    public static string CurrentUserSid => WindowsIdentity.GetCurrent().User?.Value ?? "";

    /// <summary>Файл только для владельца: без наследования, одна запись — сам человек.</summary>
    internal static void RestrictFileToOwner(string path)
    {
        try
        {
            var owner = WindowsIdentity.GetCurrent().User;
            if (owner == null) return;
            var security = new FileSecurity();
            security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
            security.AddAccessRule(new FileSystemAccessRule(owner, FileSystemRights.FullControl, AccessControlType.Allow));
            new FileInfo(path).SetAccessControl(security);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or SystemException) { }
    }

    static void TryDeleteFile(string path)
    {
        try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
