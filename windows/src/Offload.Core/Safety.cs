namespace Offload.Core;

public enum VerdictKind { Safe, Caution, Blocked }

/// <summary>Можно ли трогать объект.</summary>
public sealed class Verdict : IEquatable<Verdict>
{
    public VerdictKind Kind { get; }
    /// <summary>Оговорки (Caution) или причина запрета (Blocked, одна строка).</summary>
    public IReadOnlyList<string> Notes { get; }

    Verdict(VerdictKind kind, IReadOnlyList<string> notes)
    {
        Kind = kind;
        Notes = notes;
    }

    public static readonly Verdict Safe = new(VerdictKind.Safe, []);
    /// <summary>Можно, но есть оговорки — нужно явное подтверждение.</summary>
    public static Verdict Caution(IEnumerable<string> notes) => new(VerdictKind.Caution, notes.ToList());
    public static Verdict Caution(params string[] notes) => new(VerdictKind.Caution, notes);
    public static Verdict Blocked(string reason) => new(VerdictKind.Blocked, [reason]);

    public bool IsBlocked => Kind == VerdictKind.Blocked;
    public bool IsCaution => Kind == VerdictKind.Caution;
    public bool IsSafe => Kind == VerdictKind.Safe;
    public string? Reason => Kind == VerdictKind.Blocked ? Notes[0] : null;

    public bool Equals(Verdict? other) => other is not null && Kind == other.Kind && Notes.SequenceEqual(other.Notes);
    public override bool Equals(object? obj) => Equals(obj as Verdict);
    public override int GetHashCode() => HashCode.Combine(Kind, Notes.Count > 0 ? Notes[0] : "");
    public static bool operator ==(Verdict? a, Verdict? b) => a?.Equals(b) ?? b is null;
    public static bool operator !=(Verdict? a, Verdict? b) => !(a == b);
    public override string ToString() => Kind + (Notes.Count > 0 ? ": " + string.Join(" ", Notes) : "");
}

/// <summary>Правила, выученные на практике: что переносить нельзя, даже если данные останутся целы.</summary>
public sealed class SafetyRules
{
    public string Home { get; }
    public string Public { get; }
    public TimeSpan ActiveWithin { get; set; }

    public SafetyRules(string? home = null, double activeDays = 7, string? publicFolder = null)
    {
        // Домашняя папка и проверяемый путь разворачиваются одинаково, иначе обычный путь
        // выглядел бы лежащим вне дома.
        Home = Paths.Resolve(home ?? Paths.Home);
        Public = Paths.Resolve(publicFolder ?? Paths.Public);
        ActiveWithin = TimeSpan.FromDays(activeDays);
    }

    /// <summary>Файлы и папки, на которые программы хранят ссылки. После переноса программа их теряет:
    /// виртуальные машины и их диски, медиатеки, каталоги Lightroom. «.utm», «.photoslibrary» и другие
    /// пакеты Mac — тоже: внешний диск могли принести с Mac.</summary>
    public static readonly HashSet<string> RegisteredBundleExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "vhd", "vhdx", "avhd", "avhdx", "vmdk", "vdi", "vbox", "vmx", "vmcx", "vmrs", "vmgs", "vmsd", "qcow2", "hdd",
        "lrcat", "lrdata", "itl", "musiclibrary", "tvlibrary",
        "utm", "vmwarevm", "pvm", "photoslibrary", "fcpbundle", "logicx", "imovielibrary", "aplibrary",
    };

    /// <summary>Стандартные папки профиля. На диске они называются по-английски,
    /// по-русски их показывает Проводник.</summary>
    internal static readonly HashSet<string> StandardFolders = new(StringComparer.OrdinalIgnoreCase)
    {
        "Desktop", "Documents", "Downloads", "Music", "Pictures", "Videos", "AppData", "Favorites", "Links", "Contacts",
        "Saved Games", "Searches", "3D Objects", "Application Data", "Local Settings", "My Documents", "Start Menu",
        "Templates", "Cookies", "NetHood", "PrintHood", "Recent", "SendTo",
    };

    /// <summary>Скрытые папки с ключами, настройками и инструментами разработки.</summary>
    internal static readonly HashSet<string> PinnedHiddenFolders = new(StringComparer.OrdinalIgnoreCase)
    {
        ".ssh", ".gnupg", ".config", ".docker", ".kube", ".aws", ".azure", ".gcloud",
        ".local", ".npm", ".cache", ".cargo", ".rustup", ".gradle", ".m2", ".nvm", ".pyenv",
        ".bun", ".deno", ".vscode", ".cursor", ".claude", ".codex", ".nuget", ".dotnet", ".android", ".wslconfig",
    };

    public static bool IsRegisteredBundle(string name) => RegisteredBundleExtensions.Contains(Paths.Extension(name));

    static Verdict BundleBlocked(string bundle) =>
        Verdict.Blocked($"«{bundle}» зарегистрирован в программе (виртуальная машина, её диск, медиатека или каталог). После переноса программа его потеряет, даже если данные целы.");

    /// <summary>Быстрая проверка только по пути, без чтения содержимого.</summary>
    public Verdict PathVerdict(string path)
    {
        var resolved = Paths.Resolve(path);
        string[] parts;
        if (Paths.IsInside(resolved, Home))
        {
            parts = Paths.Parts(Paths.Relative(resolved, Home)!);
        }
        else if (Paths.IsInside(resolved, Public))
        {
            var shared = Paths.Parts(Paths.Relative(resolved, Public)!);
            if (shared.FirstOrDefault(IsRegisteredBundle) is { } sharedBundle) return BundleBlocked(sharedBundle);
            if (shared.Length == 1 && shared[0].Equals("desktop.ini", Paths.Comparison))
                return Verdict.Blocked("Служебный файл Проводника.");
            return Verdict.Safe;
        }
        else if (Paths.Same(resolved, Home))
        {
            return Verdict.Blocked("Домашнюю папку целиком переносить нельзя.");
        }
        else
        {
            return Verdict.Blocked($"Переносить можно только из домашней папки и «{Public}».");
        }
        if (parts.Length == 0) return Verdict.Blocked("Домашнюю папку целиком переносить нельзя.");
        var first = parts[0];

        // Служебная папка git: из неё git сам запускает хуки, а без неё проект — уже не репозиторий.
        if (parts.Any(p => p.Equals(".git", Paths.Comparison)))
            return Verdict.Blocked("Служебная папка git-репозитория. Переносите проект целиком.");

        // Реестр пользователя: без него Windows не войдёт в учётную запись.
        if (parts.Length == 1 && first.StartsWith("ntuser.", Paths.Comparison))
            return Verdict.Blocked("Реестр пользователя Windows. Он нужен системе для входа в учётную запись.");

        if (parts.Length == 1 && StandardFolders.Contains(first))
            return Verdict.Blocked($"«{first}» — стандартная папка Windows. Переносите её содержимое, а не саму папку.");

        if (first.Equals("AppData", Paths.Comparison)) return AppDataVerdict(parts);

        // Облачные папки: перенос удалил бы файлы и из облака, на всех устройствах.
        if (first.StartsWith("OneDrive", Paths.Comparison))
            return Verdict.Blocked("Папка синхронизируется с OneDrive: перенос удалил бы файлы и из облака. Место освобождает сам OneDrive: правый щелчок по папке → «Освободить место».");
        if (first.Equals("iCloudDrive", Paths.Comparison) || first.Equals("iCloud Photos", Paths.Comparison))
            return Verdict.Blocked("Папка синхронизируется с iCloud: перенос удалил бы файлы и из облака. Место освобождает сам iCloud: правый щелчок по папке → «Освободить место».");

        if (first.Equals("VirtualBox VMs", Paths.Comparison))
            return Verdict.Blocked("Виртуальные машины VirtualBox. Переносите их через сам VirtualBox (Машина → Переместить), иначе он их потеряет.");

        if (parts.Length >= 3 && first.Equals("Apple", Paths.Comparison) && parts[1].Equals("MobileSync", Paths.Comparison)
            && parts[2].Equals("Backup", Paths.Comparison) && parts.Length > 3)
            return Verdict.Caution("«Устройства Apple» и iTunes не увидят эту резервную копию iPhone, пока вы не вернёте её на место.");

        if (parts.FirstOrDefault(IsRegisteredBundle) is { } bundle) return BundleBlocked(bundle);

        if (first.StartsWith('.'))
        {
            if (PinnedHiddenFolders.Contains(first))
                return Verdict.Blocked($"«~\\{first}» — настройки, ключи или инструменты разработки. Им нужно оставаться на месте.");
            if (parts.Length == 1)
                return Verdict.Blocked("Скрытая папка программы целиком: программа перестанет работать. Переносите отдельные данные внутри неё.");
            return Verdict.Caution($"Программа, которой принадлежит «~\\{first}», будет искать эти данные по старому пути. Переносите, только если в ней можно указать новую папку (как папку моделей в LM Studio).");
        }
        return Verdict.Safe;
    }

    Verdict AppDataVerdict(string[] parts)
    {
        bool Under(params string[] prefix) =>
            parts.Length >= prefix.Length && prefix.Select((p, i) => parts[i].Equals(p, Paths.Comparison)).All(x => x);
        bool Inside(params string[] prefix) => parts.Length > prefix.Length && Under(prefix);

        // Известные крупные места — с объяснением, как освободить их правильно.
        if (Under("AppData", "Local", "Docker"))
            return Verdict.Blocked("Диск Docker. Место в нём освобождается в разделе «Docker»: очисткой образов и кеша сборки и архивацией неиспользуемых томов.");
        if (Under("AppData", "Local", "wsl") || parts.Any(p => p.Equals("ext4.vhdx", Paths.Comparison))
            || (Under("AppData", "Local", "Packages") && parts.Length >= 4 && parts[3].Contains("Canonical", Paths.Comparison)))
            return Verdict.Blocked("Диск дистрибутива WSL. Переносите его средствами WSL (wsl --manage <имя> --move <папка>), иначе Windows его потеряет.");
        if (Under("AppData", "Roaming", "Telegram Desktop"))
            return Verdict.Blocked("База и кеш Telegram. Кеш очищается в самом Telegram: Настройки → Продвинутые настройки → Управление памятью устройства.");
        if (Under("AppData", "Roaming", "Claude", "vm_bundles") || Under("AppData", "Local", "Claude", "vm_bundles"))
            return Verdict.Blocked("Виртуальная машина приложения Claude — она нужна ему для работы.");

        if (Inside("AppData", "Roaming", "Apple Computer", "iTunes", "iPhone Software Updates")
            || Inside("AppData", "Roaming", "Apple Computer", "iTunes", "iPad Software Updates"))
            return Verdict.Safe;
        if (Inside("AppData", "Roaming", "Apple Computer", "MobileSync", "Backup"))
            return Verdict.Caution("«Устройства Apple» и iTunes не увидят эту резервную копию iPhone, пока вы не вернёте её на место.");

        if (parts.FirstOrDefault(IsRegisteredBundle) is { } bundle) return BundleBlocked(bundle);

        if (Inside("AppData", "Local", "CrashDumps")) return Verdict.Safe;
        var ext = Paths.Extension(parts[^1]);
        if (ext is "log" or "dmp") return Verdict.Safe;
        return Verdict.Blocked("Данные программ в AppData: программа перестанет их находить. Отсюда можно переносить только прошивки iPhone, логи, дампы сбоев и резервные копии iPhone.");
    }

    /// <summary>Итоговое решение с учётом содержимого и открытых файлов.</summary>
    public Verdict FullVerdict(string path, ContentReport? content, IReadOnlyList<string>? openBy = null, DateTime? now = null)
    {
        var notes = new List<string>();
        var byPath = PathVerdict(path);
        if (byPath.IsBlocked) return byPath;
        notes.AddRange(byPath.Notes);
        if (openBy is { Count: > 0 })
            return Verdict.Blocked($"Файлы сейчас открыты: {string.Join(", ", openBy.Take(3))}. Закройте программу и повторите.");
        if (content == null) return notes.Count == 0 ? Verdict.Safe : Verdict.Caution(notes);
        if (content.MountedVolume != null)
            return Verdict.Blocked($"Внутри подключён другой диск («{content.MountedVolume}»). Отключите его или переносите по частям.");
        if (content.RegisteredBundle != null)
            return Verdict.Blocked($"Внутри лежит «{content.RegisteredBundle}» — файл, зарегистрированный в программе (например, диск виртуальной машины). После переноса программа его потеряет.");
        if (content.Unreadable > 0)
            return Verdict.Blocked($"Нет доступа к {content.Unreadable} {Plural.Ru(content.Unreadable, "объекту", "объектам", "объектам")} внутри ({string.Join(", ", content.UnreadableExamples.Take(3))}). Windows не даёт их прочитать — переносите по частям.");
        if (content.Truncated)
            return Verdict.Blocked("Файлов слишком много, проверка не закончена — переносите по частям.");
        if (content.NewestModification is { } date && (now ?? DateTime.UtcNow) - date < ActiveWithin)
            notes.Add($"Менялось {Format.Relative(date, now)} — возможно, ещё используется.");
        if (content.ContainsGitRepo) notes.Add("Внутри git-репозиторий — похоже на рабочий проект.");
        if (content.CloudOnlyFiles > 0)
            notes.Add($"{content.CloudOnlyFiles} {Plural.Ru(content.CloudOnlyFiles, "файл есть", "файла есть", "файлов есть")} только в облаке: при переносе они сначала скачаются.");
        if (content.Undeletable > 0)
            notes.Add($"Удалить оригинал не получится: у части файлов нет права на удаление ({string.Join(", ", content.UndeletableExamples.Take(3))}). Перенести можно только копией, оставив оригинал на месте.");
        return notes.Count == 0 ? Verdict.Safe : Verdict.Caution(notes);
    }

    /// <summary>Подходит ли диск назначения для конкретного содержимого.</summary>
    public static DestinationCheck CheckDestination(VolumeInfo volume, VolumeInfo? sourceVolume, ContentReport content,
                                                    bool? canCreateSymlinks = null)
    {
        var check = new DestinationCheck();
        if (volume.IsReadOnly)
            check.Blockers.Add($"Диск «{volume.Name}» доступен только для чтения ({volume.FsDisplayName}).");
        if (sourceVolume != null && Paths.Same(sourceVolume.MountPoint, volume.MountPoint))
            check.Blockers.Add("Источник и назначение на одном диске — место не освободится.");
        if (content.SymlinkCount > 0)
        {
            if (!volume.KeepsSymlinks)
                check.Blockers.Add($"{volume.FsDisplayName} не хранит символические ссылки и точки соединения, а внутри их {content.SymlinkCount}. Перенос бы их сломал.");
            else if (content.SymbolicLinks > 0 && canCreateSymlinks == false)
                check.Blockers.Add($"Внутри символические ссылки ({content.SymbolicLinks}), а создавать их Windows разрешает только администратору или в режиме разработчика. Включите «Параметры → Для разработчиков → Режим разработчика» и повторите.");
        }
        if (volume.MaxFileSize is { } limit && content.LargestFile > limit)
            check.Blockers.Add($"{volume.FsDisplayName} не принимает файлы больше 4 ГБ, а самый большой здесь — {Format.Bytes(content.LargestFile)}.");
        // Ни одной из двух мер по отдельности верить нельзя, поэтому берём большую.
        // Логический размер мал для дерева из тысяч мелких файлов: каждый занимает на диске
        // целое число кластеров, а у exFAT кластер бывает и 128 КБ. Занятое на диске, наоборот,
        // мало для разрежённых и сжатых файлов: копия пишется обычным чтением и записью и на
        // приёмнике займёт полный логический размер.
        // Недооценка здесь стоит дорого: проверка пропустит перенос, а он упадёт посередине,
        // когда место кончится, — и данные останутся разложенными по двум дискам.
        long overhead = (long)(content.Files + content.Directories) * (volume.BlockSize / 2);
        long margin = 512L * 1024 * 1024;
        check.RequiredBytes = Math.Max(content.LogicalBytes, content.AllocatedBytes) + overhead + margin;
        if (volume.AvailableBytes < check.RequiredBytes)
            check.Blockers.Add($"На «{volume.Name}» свободно {Format.Bytes(volume.AvailableBytes)}, а нужно около {Format.Bytes(check.RequiredBytes)}.");
        if (content.SparseFiles > 0)
            check.Notes.Add($"Разрежённые или сжатые файлы ({content.SparseFiles}) займут на диске полный размер: {Format.Bytes(content.LogicalBytes)} вместо {Format.Bytes(content.AllocatedBytes)}.");
        if (content.HardLinkedFiles > 0)
            check.Notes.Add($"Файлов, на которые ведёт несколько имён (жёсткие ссылки): {content.HardLinkedFiles}. В копии каждое имя станет отдельным файлом: места займёт больше, а правка одного больше не будет видна в остальных.");
        if (content.TaggedFiles > 0)
            check.Notes.Add($"У {content.TaggedFiles} {Plural.Ru(content.TaggedFiles, "объекта", "объектов", "объектов")} есть дополнительные потоки данных NTFS (пометки программ). Данные и атрибуты копируются, а эти потоки — нет: после возврата их не будет.");
        return check;
    }
}

/// <summary>Подходит ли диск назначения для конкретного содержимого.</summary>
public sealed class DestinationCheck
{
    public List<string> Blockers { get; } = [];
    public List<string> Notes { get; } = [];
    public long RequiredBytes { get; set; }
    public bool IsOK => Blockers.Count == 0;
}
