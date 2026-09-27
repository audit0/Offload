using System.Text.RegularExpressions;

namespace Offload.Core;

/// <summary>Что сделать с объектом при разборе.</summary>
public enum CleanupAction
{
    /// <summary>В Корзину. Только то, что пересоздаётся или скачивается заново (кеши сборки, установщики),
    /// и лишние копии одинаковых файлов — одна копия при этом всегда остаётся.</summary>
    Trash,
    /// <summary>В сейф со сверкой, оригинал удаляется после неё — как обычный перенос.</summary>
    Safe,
    /// <summary>Добавить в папки бэкапа.</summary>
    Backup,
    /// <summary>Не трогать.</summary>
    Keep,
}

public static class CleanupActionNames
{
    /// <summary>Как действие записано в базе решений — так же, как у версии для Mac.</summary>
    public static string Raw(this CleanupAction action) => action switch
    {
        CleanupAction.Trash => "trash",
        CleanupAction.Safe => "safe",
        CleanupAction.Backup => "backup",
        _ => "keep",
    };

    public static CleanupAction? Parse(string? raw) => raw switch
    {
        "trash" => CleanupAction.Trash,
        "safe" => CleanupAction.Safe,
        "backup" => CleanupAction.Backup,
        "keep" => CleanupAction.Keep,
        _ => null,
    };
}

/// <summary>Какой именно это файл: том и номер файла. Переименование и перенос в Корзину на том же диске
/// их сохраняют, а другой файл, оказавшийся по тому же пути, — нет. Поэтому по нему сверяют, что в Корзине
/// лежит то самое, что туда отправил разбор, прежде чем вернуть или удалить насовсем.</summary>
public readonly record struct FileIdentity(long Device, long Inode)
{
    /// <summary>Ссылка не разворачивается: номер берётся у неё самой.</summary>
    public static FileIdentity? Of(string path) => FileSystem.Stat(path) is { } stat ? new FileIdentity(stat.VolumeSerial, stat.FileIndex) : null;
}

/// <summary>Плитка на экране итогов разбора. Сразу отмечено только то, что программы создадут заново,
/// и то, что ничего не удаляет. Личное — крупное и старое, лишние копии, установщики — OffLoadAI находит
/// и объясняет, а отмечаете вы сами (или ваша прошлая привычка).</summary>
public enum CleanupModule
{
    /// <summary>Кеши и скачанные пакеты: программы создадут их заново. Отмечено сразу.</summary>
    Junk,
    /// <summary>Большое и давно не менявшееся — в сейф, со сверкой. Отмечаете вы.</summary>
    Safe,
    /// <summary>Лишние копии одинаковых файлов — в Корзину; одна копия остаётся всегда. Отмечаете вы.</summary>
    Duplicates,
    /// <summary>Старые установщики — в Корзину. Отмечаете вы.</summary>
    Installers,
    /// <summary>Проекты с git, которых нет в бэкапе, — в список папок бэкапа. Ничего не удаляет, отмечено сразу.</summary>
    Projects,
}

public static class CleanupModules
{
    public static CleanupAction Action(this CleanupModule module) => module switch
    {
        CleanupModule.Junk or CleanupModule.Duplicates or CleanupModule.Installers => CleanupAction.Trash,
        CleanupModule.Safe => CleanupAction.Safe,
        _ => CleanupAction.Backup,
    };

    /// <summary>Отмечается ли сразу по правилам.</summary>
    public static bool IsAutomatic(this CleanupModule module) => module is CleanupModule.Junk or CleanupModule.Projects;

    public static readonly CleanupModule[] All = Enum.GetValues<CleanupModule>();
}

/// <summary>Что сканер узнал об объекте. Из этого, без обращения к диску, складывается предложение.</summary>
public sealed record CleanupObservation(
    string Path,
    long Bytes,
    DateTime? Modified,
    bool IsDirectory,
    Verdict Verdict,
    bool IsProject = false,
    bool InBackup = false,
    /// <summary>Зашифрованный образ диска: такой человек делает сам для своих данных, это не установщик.</summary>
    bool IsEncryptedImage = false,
    /// <summary>Когда файл появился в своей папке. Дату изменения загрузчики ставят по серверу, и только что
    /// скачанный установщик выглядел бы старым; «появился в папке» — то, что видит человек.</summary>
    DateTime? Added = null);

public sealed record CleanupSuggestion
{
    public string Id => Path;
    public required string Path { get; init; }
    public long Bytes { get; init; }
    public DateTime? Modified { get; init; }
    public bool IsDirectory { get; init; }
    /// <summary>Что предлагается сделать.</summary>
    public CleanupAction Action { get; set; }
    /// <summary>Почему — по-человечески, одной фразой.</summary>
    public string Reason { get; set; } = "";
    /// <summary>Что вообще можно выбрать для этого объекта; «оставить» есть всегда.</summary>
    public IReadOnlyList<CleanupAction> Allowed { get; init; } = [CleanupAction.Keep];
    /// <summary>Предложение взято из прошлого решения человека, а не из правил.</summary>
    public bool Learned { get; set; }
    /// <summary>Оговорки правил, которые человек видит до переноса в сейф.</summary>
    public IReadOnlyList<string> Cautions { get; init; } = [];
    /// <summary>Одна из одинаковых копий: SHA-256 содержимого, общий для всей группы.</summary>
    public string? DuplicateGroup { get; init; }
    /// <summary>Предложение взято из привычек человека.</summary>
    public bool Habit { get; set; }
    /// <summary>Что это за объект — пишется вместе с решением, на этом учатся привычки.</summary>
    public DecisionKind Kind { get; init; }
    /// <summary>Плитка, в которой объект показан; null — трогать его незачем.</summary>
    public CleanupModule? Module { get; init; }

    public string Name => Paths.Name(Path);

    /// <summary>Отмечен ли сразу.</summary>
    public bool Preselected => Action != CleanupAction.Keep && Module is { } module && (module.IsAutomatic() || Learned || Habit);

    public CleanupAction DefaultChoice => Preselected ? Action : CleanupAction.Keep;

    public static CleanupSuggestion Make(string path, long bytes, DateTime? modified, bool isDirectory, CleanupAction action, string reason,
        IReadOnlyList<CleanupAction> allowed, bool learned, IReadOnlyList<string> cautions, string? duplicateGroup = null,
        bool habit = false, DecisionKind? kind = null, CleanupModule? module = null) => new()
    {
        Path = path, Bytes = bytes, Modified = modified, IsDirectory = isDirectory, Action = action, Reason = reason, Allowed = allowed,
        Learned = learned, Cautions = cautions, DuplicateGroup = duplicateGroup, Habit = habit,
        Kind = kind ?? (duplicateGroup != null ? DecisionKind.Copy : isDirectory ? DecisionKind.Folder : DecisionKind.File),
        Module = module ?? (duplicateGroup != null ? CleanupModule.Duplicates : ModuleFor(action)),
    };

    /// <summary>Плитка по действию, когда планировщик её не назвал.</summary>
    internal static CleanupModule? ModuleFor(CleanupAction action) => action switch
    {
        CleanupAction.Trash => CleanupModule.Junk,
        CleanupAction.Safe => CleanupModule.Safe,
        CleanupAction.Backup => CleanupModule.Projects,
        _ => null,
    };
}

/// <summary>Раскладывает найденное по действиям. Чистая логика: ни диска, ни времени, кроме переданного.
///
/// Удаление здесь — только в Корзину и только для того, что восстанавливается само (кеши сборки, скачанные
/// пакеты) или скачивается заново (установщики). Личные файлы без копии OffLoadAI не удаляет: для них есть сейф,
/// где оригинал исчезает только после сверки. Лишняя копия одинакового файла — не исключение из этого правила:
/// копия, которая остаётся, и есть сверенная копия, а перед удалением они ещё раз сравниваются байт в байт.</summary>
public sealed class CleanupPlanner
{
    public DateTime Now { get; init; } = DateTime.UtcNow;
    /// <summary>Домашняя папка: от неё считаются Загрузки, Рабочий стол и папки медиатек.</summary>
    public string Home { get; init; } = Paths.Home;
    /// <summary>Восстанавливаемые места: путь → почему их можно удалить.</summary>
    public IReadOnlyDictionary<string, string> Regenerable { get; init; } = new Dictionary<string, string>(Paths.Comparer);
    /// <summary>Последнее решение человека по каждому пути.</summary>
    public IReadOnlyDictionary<string, CleanupAction> Memory { get; init; } = new Dictionary<string, CleanupAction>(Paths.Comparer);
    /// <summary>Что человек обычно выбирает для похожего.</summary>
    public HabitModel? Habits { get; init; }
    /// <summary>Восстанавливаемые места, которые сейчас держит открытая программа: путь → почему не отмечено.</summary>
    public IReadOnlyDictionary<string, string> Busy { get; init; } = new Dictionary<string, string>(Paths.Comparer);
    /// <summary>Что человек просил больше не предлагать: сам путь и всё, что внутри.</summary>
    public IReadOnlySet<string> Ignored { get; init; } = new HashSet<string>(Paths.Comparer);
    public long BigBytes { get; init; } = 1_000_000_000;
    public double StaleDays { get; init; } = 90;
    /// <summary>Установщик, скачанный меньше недели назад, может быть ещё не поставлен.</summary>
    public double InstallerDays { get; init; } = 7;
    public long MinimumBytes { get; init; } = 100_000_000;

    /// <summary>Похоже на установщик. «.iso» сюда не входит: к нему часто подключена виртуальная машина.
    /// «.exe» — только в Загрузках и на Рабочем столе: в других местах это чаще программа без установки.</summary>
    public static readonly HashSet<string> InstallerExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "msi", "msix", "msixbundle", "appx", "appxbundle", "exe", "dmg", "pkg",
    };

    /// <summary>Просил ли человек не предлагать этот путь — его самого или папку, в которой он лежит.</summary>
    public bool IsIgnored(string path)
    {
        if (Ignored.Count == 0) return false;
        var current = Paths.Normalize(path);
        while (true)
        {
            if (Ignored.Contains(current)) return true;
            var parent = System.IO.Path.GetDirectoryName(current);
            if (parent == null || Paths.Same(parent, current)) return false;
            current = parent;
        }
    }

    bool IsInstaller(CleanupObservation item)
    {
        if (item.IsDirectory || item.IsEncryptedImage) return false;
        var ext = Paths.Extension(item.Path);
        if (!InstallerExtensions.Contains(ext)) return false;
        return ext != "exe" || IsTransient(item.Path);
    }

    public CleanupSuggestion Suggest(CleanupObservation item)
    {
        var path = item.Path;
        double? days = item.Modified is { } modified ? Math.Max(0, (Now - modified).TotalDays) : null;
        Regenerable.TryGetValue(path, out var regenerableReason);
        bool isInstaller = IsInstaller(item);

        var allowed = new List<CleanupAction>();
        // Установщик старый, только если он и не менялся, и не появлялся в папке последнюю неделю.
        double? addedDays = item.Added is { } added ? Math.Max(0, (Now - added).TotalDays) : null;
        double? installerAge = null;
        foreach (var age in new[] { days, addedDays })
            if (age is { } value) installerAge = installerAge is { } current ? Math.Min(current, value) : value;
        if (regenerableReason != null || (isInstaller && (installerAge ?? 0) >= InstallerDays)) allowed.Add(CleanupAction.Trash);
        if (regenerableReason == null && !item.Verdict.IsBlocked) allowed.Add(CleanupAction.Safe);
        if (regenerableReason == null && item.IsDirectory && !item.Verdict.IsBlocked && !item.InBackup) allowed.Add(CleanupAction.Backup);
        allowed.Add(CleanupAction.Keep);

        var kind = item.IsProject ? DecisionKind.Project : item.IsDirectory ? DecisionKind.Folder : DecisionKind.File;
        var rule = ByRules(item, allowed, days, regenerableReason);
        // Плитка: по действию, а у «оставить» — по тому, куда объект попал бы по правилам.
        CleanupModule? ModuleOf(CleanupAction action) => action switch
        {
            CleanupAction.Trash => regenerableReason != null ? CleanupModule.Junk : CleanupModule.Installers,
            CleanupAction.Safe => CleanupModule.Safe,
            CleanupAction.Backup => CleanupModule.Projects,
            _ => regenerableReason != null ? CleanupModule.Junk : allowed.Contains(CleanupAction.Trash) ? CleanupModule.Installers : null,
        };
        CleanupSuggestion Make(CleanupAction action, string reason, bool learned = false, bool habit = false) =>
            CleanupSuggestion.Make(item.Path, item.Bytes, item.Modified, item.IsDirectory, action, reason, allowed, learned, item.Verdict.Notes,
                                   habit: habit, kind: kind, module: ModuleOf(action) ?? ModuleOf(rule.action));

        // Кеш открытой программы не отмечается, даже если в прошлый раз его удаляли.
        if (regenerableReason != null && Busy.TryGetValue(path, out var busy)) return Make(CleanupAction.Keep, busy);
        if (Memory.TryGetValue(path, out var remembered) && allowed.Contains(remembered))
            return Make(remembered, "В прошлый раз вы выбрали это же.", learned: true);
        // Привычка решает, когда расходится с правилом. А когда совпадает с тем, что правила только предлагают,
        // не отмечая (сейф), — отмечает сразу: вы так обычно и делаете.
        var features = DecisionFeatures.Of(path, Home, kind, item.Bytes, item.Modified, Now);
        if (Habits?.Predict(features, allowed) is { } prediction)
        {
            bool onlyOffered = prediction.Action != CleanupAction.Keep && ModuleOf(prediction.Action) is { } module && !module.IsAutomatic();
            if (prediction.Action != rule.action || onlyOffered) return Make(prediction.Action, prediction.Reason, habit: true);
        }
        return Make(rule.action, rule.reason);
    }

    (CleanupAction action, string reason) ByRules(CleanupObservation item, List<CleanupAction> allowed, double? days, string? regenerableReason)
    {
        if (regenerableReason != null) return (CleanupAction.Trash, regenerableReason);
        if (item.Verdict.IsBlocked) return (CleanupAction.Keep, item.Verdict.Reason!);
        if (item.IsProject && allowed.Contains(CleanupAction.Backup))
            return (CleanupAction.Backup, "Похоже на проект (внутри git): его лучше держать в бэкапе, а не переносить.");
        if (item.Bytes >= BigBytes && days is { } d && d >= StaleDays && item.Verdict.IsSafe)
            return (CleanupAction.Safe, "Большое и давно не менялось — в сейфе не мешает, а вернуть можно в любой момент.");
        if (allowed.Contains(CleanupAction.Trash)) return (CleanupAction.Keep, "Старый установщик: если программа уже стоит, его можно скачать снова.");
        if (item.IsEncryptedImage)
            return (CleanupAction.Keep, "Зашифрованный образ диска — похоже, в нём ваши данные. Удалить его из разбора нельзя.");
        if (days is { } recent && recent < 30) return (CleanupAction.Keep, "Менялось недавно — похоже, вы этим пользуетесь.");
        if (item.Bytes < BigBytes) return (CleanupAction.Keep, "Места занимает немного.");
        if (item.Verdict.IsCaution) return (CleanupAction.Keep, "Есть оговорки — решите сами.");
        return (CleanupAction.Keep, "Менялось не так давно — решите сами.");
    }

    /// <summary>Предложения по плиткам (мусор, сейф, копии, установщики, проекты), внутри — по размеру.
    /// Копии одинаковых файлов идут в конце, группами, в каждой первой — та, что остаётся.</summary>
    public List<CleanupSuggestion> Suggestions(IEnumerable<CleanupObservation> items, IEnumerable<DuplicateGroup>? duplicates = null)
    {
        var top = items.Where(i => !IsIgnored(i.Path)).Select(Suggest).ToList();
        var byPath = new Dictionary<string, CleanupSuggestion>(Paths.Comparer);
        foreach (var suggestion in top) byPath.TryAdd(suggestion.Id, suggestion);
        var copies = new List<CleanupSuggestion>();
        foreach (var group in duplicates ?? [])
        {
            // Установщик и кеш удаляются по своим правилам, и в группе им делать нечего.
            var rest = group.Copies.Where(c => !(byPath.TryGetValue(c.Path, out var known) && known.Allowed.Contains(CleanupAction.Trash))).ToList();
            if (rest.Count <= 1) continue;
            copies.AddRange(DuplicateSuggestions(group with { Copies = rest }, byPath));
        }
        var taken = new HashSet<string>(copies.Select(c => c.Id), Paths.Comparer);
        return top.Where(s => !taken.Contains(s.Id) && s.Module != null)
            .Where(IsWorthShowing)
            .OrderBy(s => Order(s.Module))
            .ThenByDescending(s => s.Bytes)
            .ThenByDescending(s => s.Id, StringComparer.Ordinal)
            .Concat(copies).ToList();
    }

    /// <summary>Мелочь разбирать дольше, чем она стоит. Удаляемое показывается с 10 МБ, остальное — со 100 МБ;
    /// прошлое решение «убрать» — всегда, человек его ждёт.</summary>
    public bool IsWorthShowing(CleanupSuggestion suggestion) =>
        suggestion.Bytes >= (suggestion.Module?.Action() == CleanupAction.Trash ? 10_000_000 : MinimumBytes)
        || (suggestion.Learned && suggestion.Action != CleanupAction.Keep);

    static int Order(CleanupModule? module) => module is { } m ? Array.IndexOf(CleanupModules.All, m) : CleanupModules.All.Length;

    /// <summary>Место, которое программа пересоздаёт сама: кеш, скачанные пакеты, промежуточные файлы сборки.</summary>
    public sealed record RegenerableLocation(
        /// <summary>Относительно домашней папки.</summary>
        string Path,
        string Reason,
        /// <summary>Программы, которые держат это место, пока открыты: начала имён их процессов.</summary>
        string[]? Apps = null,
        /// <summary>Если не пусто — удаляется не само место, а только эти папки внутри каждой его подпапки.</summary>
        string[]? Children = null);

    /// <summary>Пути места на этом компьютере. У места с Children — только эти папки внутри каждой подпапки:
    /// у JetBrains в папке среды рядом с кешами лежит локальная история правок (LocalHistory), а у Chrome
    /// в папке профиля — закладки и пароли. Удалить их вместе с кешем значило бы потерять их.</summary>
    internal static List<string> PathsOf(RegenerableLocation location, string home)
    {
        var root = System.IO.Path.Combine(home, location.Path);
        if (location.Children is not { Length: > 0 } children) return [root];
        List<DirItem> folders;
        try { folders = FileSystem.List(root).Where(i => i.IsDirectory && !i.IsLink).OrderBy(i => i.Name, StringComparer.Ordinal).ToList(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return []; }
        return folders.SelectMany(f => children.Select(c => System.IO.Path.Combine(root, f.Name, c))).ToList();
    }

    /// <summary>Известные места, которые программы пересоздают сами. Только такие OffLoadAI отмечает сразу:
    /// это его «база безопасности» — не догадки по именам папок.</summary>
    public static readonly RegenerableLocation[] RegenerableLocations =
    [
        new(@"AppData\Local\npm-cache\_cacache", "Кеш npm — пакеты скачаются снова."),
        new(@"AppData\Local\pip\Cache", "Кеш pip — пакеты скачаются снова."),
        new(@"AppData\Local\Yarn\Cache", "Кеш Yarn — пакеты скачаются снова."),
        new(@".yarn\berry\cache", "Кеш Yarn — пакеты скачаются снова."),
        new(@"AppData\Local\NuGet\v3-cache", "Кеш NuGet — пакеты скачаются снова.", ["devenv", "dotnet", "MSBuild"]),
        new(@".nuget\packages", "Пакеты NuGet — восстановятся при следующей сборке (dotnet restore).", ["devenv", "dotnet", "MSBuild"]),
        new(@".gradle\caches", "Кеш Gradle — зависимости скачаются снова.", ["java", "studio64"]),
        new(@".cargo\registry\cache", "Скачанные пакеты Cargo — скачаются снова."),
        new(@"AppData\Local\go-build", "Кеш сборки Go — пересоздаётся при следующей сборке."),
        new(@"AppData\Local\ms-playwright", "Браузеры Playwright — скачаются снова командой «playwright install»."),
        new(@"AppData\Local\JetBrains", "Кеши и индексы сред JetBrains — пересоздаются при следующем запуске. Локальная история правок не затрагивается.",
            ["idea", "pycharm", "webstorm", "rider", "goland", "clion", "phpstorm", "rubymine", "datagrip", "rustrover"], ["caches", "index"]),
        new(@"AppData\Roaming\Code\Cache", "Кеш VS Code — пересоздаётся сам.", ["Code"]),
        new(@"AppData\Roaming\Code\CachedData", "Кеш VS Code — пересоздаётся сам.", ["Code"]),
        new(@"AppData\Local\Google\Chrome\User Data", "Кеш Chrome — страницы подгрузятся снова; закладки, пароли и история не затрагиваются.",
            ["chrome"], ["Cache", "Code Cache"]),
        new(@"AppData\Local\Microsoft\Edge\User Data", "Кеш Edge — страницы подгрузятся снова; закладки, пароли и история не затрагиваются.",
            ["msedge"], ["Cache", "Code Cache"]),
        new(@"AppData\Local\Spotify\Data", "Кеш Spotify — музыка подгрузится снова. Скачанное для прослушивания без сети, возможно, придётся скачать заново.",
            ["Spotify"]),
        new(@"AppData\Roaming\discord\Cache", "Кеш Discord — пересоздаётся сам.", ["Discord"]),
        new(@"AppData\Local\CrashDumps", "Дампы сбоев программ — нужны только разработчикам, чтобы разобрать ошибку."),
        new(@"AppData\Local\D3DSCache", "Кеш шейдеров DirectX — игры и программы соберут его снова."),
        new(@"AppData\Local\NVIDIA\DXCache", "Кеш шейдеров NVIDIA — игры соберут его снова."),
        new(@"AppData\Roaming\Apple Computer\iTunes\iPhone Software Updates", "Прошивки iPhone — iTunes скачает нужную снова."),
    ];

    /// <summary>Восстанавливаемые места, которые действительно есть у этого человека.</summary>
    public static Dictionary<string, string> RegenerableIn(string home)
    {
        var result = new Dictionary<string, string>(Paths.Comparer);
        foreach (var location in RegenerableLocations)
            foreach (var path in PathsOf(location, home))
                if (FileSystem.Stat(path) is { IsLink: false }) result[path] = location.Reason;
        return result;
    }

    /// <summary>Какие восстанавливаемые места сейчас держат открытые программы. running — имя процесса → название
    /// программы. Ответ: путь → почему место не отмечено.</summary>
    public static Dictionary<string, string> BusyIn(string home, IReadOnlyDictionary<string, string> running)
    {
        var result = new Dictionary<string, string>(Paths.Comparer);
        foreach (var location in RegenerableLocations)
        {
            if (location.Apps is not { Length: > 0 } apps) continue;
            var holder = running.Where(p => apps.Any(a => p.Key.StartsWith(a, StringComparison.OrdinalIgnoreCase)))
                                .OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => p.Value).FirstOrDefault();
            if (holder == null) continue;
            foreach (var path in PathsOf(location, home))
                result[path] = $"Сейчас открыт {holder}: кеш занят. Закройте программу — и его можно будет удалить.";
        }
        return result;
    }

    /// <summary>Где искать: содержимое стандартных папок и своих папок в домашней (например, ~\Projects).
    /// AppData и скрытые папки целиком не разбираются — там только известные восстанавливаемые места.</summary>
    public static List<string> Roots(string home)
    {
        var roots = new List<string>();
        foreach (var name in new[] { "Downloads", "Desktop", "Documents", "Videos", "Music", "Pictures" }) roots.Add(System.IO.Path.Combine(home, name));
        try
        {
            foreach (var item in FileSystem.List(home).OrderBy(i => i.Name, StringComparer.Ordinal))
            {
                if (!item.IsDirectory || item.IsLink || item.IsHidden || item.Name.StartsWith('.')) continue;
                if (SafetyRules.StandardFolders.Contains(item.Name) || item.Name.StartsWith("OneDrive", Paths.Comparison)
                    || item.Name.Equals("iCloudDrive", Paths.Comparison) || item.Name.Equals("iCloud Photos", Paths.Comparison)) continue;
                roots.Add(System.IO.Path.Combine(home, item.Name));
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        // Диск, подключённый прямо в домашнюю папку (точка подключения тома), — не этот компьютер:
        // единственная копия могла бы остаться на нём.
        var homeVolume = FileSystem.Stat(home)?.VolumeSerial;
        return roots.Where(r => FileSystem.Stat(r) is { IsRegularDirectory: true } stat && (homeVolume == null || stat.VolumeSerial == homeVolume)).ToList();
    }

    // MARK: Одинаковые файлы

    /// <summary>Папки, где файлы лежат по путям, записанным в медиатеке программы. Копию отсюда не удаляем.</summary>
    public static readonly string[] ManagedFolders = [@"Music\iTunes", @"Music\Apple Music", @"Music\Apple TV", @"Videos\Apple TV"];
    /// <summary>Куда файлы попадают мимоходом: скачали, сохранили на минутку. Лишняя копия — скорее отсюда.</summary>
    public static readonly HashSet<string> TransientFolders = new(StringComparer.OrdinalIgnoreCase) { "Downloads", "Desktop" };

    static readonly Regex[] CopyPatterns =
    [
        new(@"\s?\(\d+\)$", RegexOptions.IgnoreCase),
        new(@"\s(copy|копия)(\s\d+)?$", RegexOptions.IgnoreCase),
        new(@"\s-\s(copy|копия)(\s\(\d+\))?$", RegexOptions.IgnoreCase),
        new(@"\s\d{1,2}$", RegexOptions.IgnoreCase),
        new(@"-\d{1,2}$", RegexOptions.IgnoreCase),
    ];

    /// <summary>Похоже ли имя на копию: «Отчёт (1).pdf», «Отчёт — копия.pdf», «Отчёт - копия (2).pdf», «Отчёт 2.pdf».</summary>
    public static bool LooksLikeCopy(string name)
    {
        var stem = System.IO.Path.GetFileNameWithoutExtension(name);
        return CopyPatterns.Any(p => p.IsMatch(stem));
    }

    /// <summary>Почему эту копию удалять нельзя; null — можно.</summary>
    internal string? KeepReason(DuplicateCopy copy)
    {
        if (IsIgnored(copy.Path)) return "Вы просили не предлагать этот файл — эта копия остаётся.";
        if (copy.Verdict.IsBlocked) return copy.Verdict.Reason;
        if (copy.Verdict.IsCaution) return copy.Verdict.Notes.FirstOrDefault();
        if (copy.SharesData) return "Клон другой копии: данные у них общие, и удаление места не освободит.";
        if (ManagedFolder(copy.Path) is { } folder) return $"Файл медиатеки в ~\\{folder}: программа найдёт его только на этом месте.";
        if (copy.IsEncryptedImage) return "Зашифрованный образ диска — похоже, в нём ваши данные. Удалить его из разбора нельзя.";
        if (Paths.Extension(copy.Path) == "iso") return "Образ .iso: к нему бывает подключена виртуальная машина. Удалить его из разбора нельзя.";
        return null;
    }

    string? HomeRelative(string path) => Paths.Relative(path, Home);

    string? ManagedFolder(string path) =>
        HomeRelative(path) is { } relative ? ManagedFolders.FirstOrDefault(f => relative.StartsWith(f + "\\", Paths.Comparison)) : null;

    bool IsTransient(string path) => HomeRelative(path) is { } relative && TransientFolders.Contains(Paths.Parts(relative)[0]);

    /// <summary>Кому остаться: сначала копиям, которые удалять нельзя, потом лежащим на своём месте
    /// (не в Загрузках и не на Рабочем столе), с именем без «(1)» и появившимся раньше.</summary>
    internal List<DuplicateCopy> KeeperOrder(IEnumerable<DuplicateCopy> copies) =>
        copies.OrderBy(c => KeepReason(c) == null ? 1 : 0)
              .ThenBy(c => IsTransient(c.Path) ? 1 : 0)
              .ThenBy(c => LooksLikeCopy(Paths.Name(c.Path)) ? 1 : 0)
              .ThenBy(c => (c.Created ?? c.Modified) ?? DateTime.MaxValue)
              .ThenBy(c => c.Path, StringComparer.Ordinal)
              .ToList();

    string KeeperReason(DuplicateCopy keeper, IReadOnlyList<DuplicateCopy> others)
    {
        if (KeepReason(keeper) is { } reason) return reason;
        if (!IsTransient(keeper.Path) && others.Any(o => IsTransient(o.Path)))
            return "Лежит на своём месте, а не в Загрузках или на Рабочем столе, — эта копия остаётся.";
        if (!LooksLikeCopy(Paths.Name(keeper.Path)) && others.Any(o => LooksLikeCopy(Paths.Name(o.Path))))
            return "Имя без «(1)» и «копия» — похоже на оригинал, он остаётся.";
        if ((keeper.Created ?? keeper.Modified) is { } date && others.All(o => (o.Created ?? o.Modified) is not { } d || d > date))
            return "Появилась раньше остальных — похоже на оригинал, он остаётся.";
        return "Одна копия остаётся — эта.";
    }

    /// <summary>Строки одной группы: первая — копия, которая остаётся, остальные — лишние.
    /// Если удалить нельзя ни одну (медиатека, клоны), группа не показывается вовсе.</summary>
    internal List<CleanupSuggestion> DuplicateSuggestions(DuplicateGroup group, IReadOnlyDictionary<string, CleanupSuggestion> topLevel)
    {
        var ordered = KeeperOrder(group.Copies);
        if (!ordered.Any(c => KeepReason(c) == null)) return [];
        var result = ordered.Select((copy, index) =>
        {
            topLevel.TryGetValue(copy.Path, out var top);
            var reasonToKeep = KeepReason(copy);
            IReadOnlyList<CleanupAction> allowed = reasonToKeep == null ? [CleanupAction.Trash, CleanupAction.Keep] : [CleanupAction.Keep];
            CleanupAction action;
            string reason;
            bool habit = false;
            if (index == 0)
            {
                action = CleanupAction.Keep;
                reason = KeeperReason(copy, ordered.Skip(1).ToList());
            }
            else if (reasonToKeep != null)
            {
                action = CleanupAction.Keep;
                reason = reasonToKeep;
            }
            else
            {
                action = CleanupAction.Trash;
                reason = "Лишняя копия: содержимое то же, что у копии, которая остаётся.";
                // Привычка может лишнюю копию только оставить, но не удалить.
                var features = DecisionFeatures.Of(copy.Path, Home, DecisionKind.Copy, copy.Allocated, copy.Modified, Now);
                if (Habits?.Predict(features, allowed.Where(a => a != CleanupAction.Trash).ToList()) is { } prediction)
                {
                    action = prediction.Action;
                    reason = prediction.Reason;
                    habit = true;
                }
            }
            bool learned = false;
            if (Memory.TryGetValue(copy.Path, out var remembered) && allowed.Contains(remembered))
            {
                action = remembered;
                reason = "В прошлый раз вы выбрали это же.";
                learned = true;
                habit = false;
            }
            return CleanupSuggestion.Make(copy.Path, copy.Allocated, copy.Modified, false, action, reason, allowed, learned,
                                          top?.Cautions ?? copy.Verdict.Notes, group.Id, habit);
        }).ToList();
        // Прошлые решения не должны отправить в Корзину все копии разом.
        if (result.All(s => s.Action == CleanupAction.Trash))
        {
            result[0].Action = CleanupAction.Keep;
            result[0].Reason = KeeperReason(ordered[0], ordered.Skip(1).ToList());
            result[0].Learned = false;
        }
        return result;
    }

    /// <summary>Что можно выбрать для копии: последнюю остающуюся копию группы убрать в Корзину нельзя.</summary>
    public static List<CleanupAction> Options(CleanupSuggestion copy, IEnumerable<CleanupSuggestion> group, Func<CleanupSuggestion, CleanupAction> effective)
    {
        bool othersStay = group.Any(g => g.Id != copy.Id && effective(g) != CleanupAction.Trash);
        return othersStay ? copy.Allowed.ToList() : copy.Allowed.Where(a => a != CleanupAction.Trash).ToList();
    }

    /// <summary>С чем сверить копию перед удалением: другая копия той же группы, которая остаётся.</summary>
    public static CleanupSuggestion? Reference(CleanupSuggestion copy, IEnumerable<CleanupSuggestion> group, Func<CleanupSuggestion, CleanupAction> effective)
    {
        var staying = group.Where(g => g.Id != copy.Id && effective(g) != CleanupAction.Trash).ToList();
        return staying.FirstOrDefault(g => effective(g) == CleanupAction.Keep) ?? staying.FirstOrDefault();
    }

    /// <summary>Папка из списка, внутри которой лежит объект: копия внутри папки, уезжающей в сейф, едет вместе с ней.</summary>
    public static CleanupSuggestion? Container(CleanupSuggestion suggestion, IEnumerable<CleanupSuggestion> suggestions) =>
        suggestions.FirstOrDefault(s => s.IsDirectory && s.DuplicateGroup == null && Paths.IsInside(suggestion.Id, s.Id));
}
