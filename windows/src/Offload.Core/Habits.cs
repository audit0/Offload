namespace Offload.Core;

public enum DecisionKind { Folder, Project, File, Copy }
public enum DecisionCategory { Video, Audio, Image, Archive, Installer, Document, Other }
/// <summary>Меньше 100 МБ, до 1 ГБ, до 10 ГБ, больше.</summary>
public enum DecisionSize { Small, Medium, Large, Huge }
/// <summary>Когда менялось к моменту решения: за месяц, за три месяца, за год, давнее.</summary>
public enum DecisionAge { Fresh, Recent, Old, Ancient, Unknown }

public static class DecisionKindNames
{
    public static string Raw(this DecisionKind kind) => kind switch
    {
        DecisionKind.Folder => "folder",
        DecisionKind.Project => "project",
        DecisionKind.File => "file",
        _ => "copy",
    };

    public static DecisionKind? Parse(string? raw) => raw switch
    {
        "folder" => DecisionKind.Folder,
        "project" => DecisionKind.Project,
        "file" => DecisionKind.File,
        "copy" => DecisionKind.Copy,
        _ => null,
    };
}

/// <summary>Чем объект запомнился: признаки, по которым решения человека переносятся на похожее.
/// Считаются из пути, размера и дат — одинаково для прошлых решений и для новых предложений.</summary>
public readonly record struct DecisionFeatures(DecisionKind Kind, DecisionCategory? Category, string Place, DecisionSize Size, DecisionAge Age)
{
    public static DecisionFeatures Of(string path, string home, DecisionKind kind, long bytes, DateTime? modified, DateTime at)
    {
        var place = Paths.Relative(path, home) is { } relative ? Paths.Parts(relative).FirstOrDefault() ?? "" : "";
        var size = bytes < 100_000_000 ? DecisionSize.Small : bytes < 1_000_000_000 ? DecisionSize.Medium
                 : bytes < 10_000_000_000 ? DecisionSize.Large : DecisionSize.Huge;
        DecisionAge age;
        if (modified is { } date)
        {
            double days = (at - date).TotalDays;
            age = days < 30 ? DecisionAge.Fresh : days < 90 ? DecisionAge.Recent : days < 365 ? DecisionAge.Old : DecisionAge.Ancient;
        }
        else age = DecisionAge.Unknown;
        DecisionCategory? category = kind is DecisionKind.Folder or DecisionKind.Project ? null : CategoryOf(Paths.Name(path));
        // Место сравнивается без учёта регистра: «Downloads» и «downloads» — одна папка.
        return new DecisionFeatures(kind, category, place.ToLowerInvariant() is var lower && KnownPlaces.TryGetValue(lower, out var canonical) ? canonical : place,
                                    size, age);
    }

    static readonly Dictionary<string, string> KnownPlaces = new()
    {
        ["downloads"] = "Downloads", ["desktop"] = "Desktop", ["documents"] = "Documents", ["videos"] = "Videos",
        ["music"] = "Music", ["pictures"] = "Pictures", ["appdata"] = "AppData",
    };

    static readonly Dictionary<DecisionCategory, HashSet<string>> Extensions = new()
    {
        [DecisionCategory.Video] = new(StringComparer.OrdinalIgnoreCase) { "mov", "mp4", "m4v", "mkv", "avi", "wmv", "webm", "mts", "m2ts", "3gp", "flv", "mpg", "mpeg" },
        [DecisionCategory.Audio] = new(StringComparer.OrdinalIgnoreCase) { "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "wma" },
        [DecisionCategory.Image] = new(StringComparer.OrdinalIgnoreCase)
        {
            "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "psd", "raw", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2",
        },
        [DecisionCategory.Archive] = new(StringComparer.OrdinalIgnoreCase) { "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst" },
        [DecisionCategory.Installer] = new(StringComparer.OrdinalIgnoreCase) { "exe", "msi", "msix", "appx", "dmg", "pkg", "iso", "img", "vhd", "vhdx" },
        [DecisionCategory.Document] = new(StringComparer.OrdinalIgnoreCase)
        {
            "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf", "md", "epub", "odt", "ods", "csv",
        },
    };

    public static DecisionCategory CategoryOf(string name)
    {
        var ext = Paths.Extension(name);
        foreach (var (category, set) in Extensions) if (set.Contains(ext)) return category;
        return DecisionCategory.Other;
    }
}

/// <summary>Привычки человека: что он обычно выбирает для похожего. Учится на решениях из базы,
/// работает только на этом компьютере и не гадает на пустом месте: пока похожих решений меньше трёх
/// или они расходятся, решают правила. Удалить привычка не предлагает никогда.
///
/// Похожесть — от строгой к широкой: сначала то же место, вид, размер и давность, потом без давности,
/// потом без размера. Берётся самая строгая ступень, где решений хватает; если на ней они расходятся,
/// более широкая не спасает.</summary>
public sealed class HabitModel
{
    public readonly record struct Example(DecisionFeatures Features, CleanupAction Action);

    public sealed record Prediction(CleanupAction Action, int Agreeing, int Total, string Scope)
    {
        /// <summary>Причина для строки предложения.</summary>
        public string Reason => $"Похожее вы обычно {Verb(Action)} ({Agreeing} из {Total}): {Scope}.";

        public static string Verb(CleanupAction action) => action switch
        {
            CleanupAction.Trash => "удаляете",
            CleanupAction.Safe => "убираете в сейф",
            CleanupAction.Backup => "добавляете в бэкап",
            _ => "оставляете",
        };
    }

    enum Level { Exact, Sized, Placed }

    static DecisionFeatures Key(Level level, DecisionFeatures features)
    {
        var key = features;
        if (level != Level.Exact) key = key with { Age = DecisionAge.Unknown };
        if (level == Level.Placed) key = key with { Size = DecisionSize.Small };
        return key;
    }

    public int MinimumSupport { get; init; } = 3;
    public double MinimumShare { get; init; } = 0.75;
    /// <summary>На скольких решениях модель учится.</summary>
    public int Count { get; }
    readonly Dictionary<Level, Dictionary<DecisionFeatures, Dictionary<CleanupAction, int>>> counts = [];

    /// <summary>Модель по истории решений: каждый объект — одно последнее решение, и только если это выбор человека.</summary>
    public HabitModel(IEnumerable<DecisionStore.Decision> history, string home)
        : this(history.Where(d => d.IsChoice).Select(d => new Example(d.Features(home), d.Action))) { }

    public HabitModel(IEnumerable<Example> examples)
    {
        var list = examples.ToList();
        Count = list.Count;
        foreach (var level in Enum.GetValues<Level>())
        {
            var table = new Dictionary<DecisionFeatures, Dictionary<CleanupAction, int>>();
            foreach (var example in list)
            {
                var key = Key(level, example.Features);
                if (!table.TryGetValue(key, out var votes)) table[key] = votes = [];
                votes[example.Action] = votes.GetValueOrDefault(example.Action) + 1;
            }
            counts[level] = table;
        }
    }

    public bool IsEmpty => counts[Level.Exact].Count == 0;

    /// <summary>Что человек, судя по похожему, выберет сам. null — похожих мало, они расходятся или их действие
    /// для этого объекта не разрешено.</summary>
    public Prediction? Predict(DecisionFeatures features, IReadOnlyList<CleanupAction> allowed)
    {
        foreach (var level in Enum.GetValues<Level>())
        {
            var key = Key(level, features);
            if (!counts[level].TryGetValue(key, out var votes)) continue;
            int total = votes.Values.Sum();
            if (total < MinimumSupport) continue;
            var decided = Decided(votes, total, Scope(key, level));
            return decided != null && allowed.Contains(decided.Action) ? decided : null;
        }
        return null;
    }

    /// <summary>Всё, чему модель научилась, — на широкой ступени, самые подкреплённые сначала.</summary>
    public List<Prediction> Habits(int limit = 6) =>
        counts[Level.Placed].Select(p => Decided(p.Value, p.Value.Values.Sum(), Scope(p.Key, Level.Placed)))
            .Where(p => p != null && p.Total >= MinimumSupport).Select(p => p!)
            .OrderByDescending(p => p.Agreeing).ThenByDescending(p => p.Total).ThenBy(p => p.Scope, StringComparer.Ordinal)
            .Take(limit).ToList();

    Prediction? Decided(Dictionary<CleanupAction, int> votes, int total, string scope)
    {
        var top = votes.OrderByDescending(v => v.Value).ThenByDescending(v => v.Key.Raw(), StringComparer.Ordinal).First();
        if (top.Key == CleanupAction.Trash || (double)top.Value / total < MinimumShare) return null;
        return new Prediction(top.Key, top.Value, total, scope);
    }

    // MARK: Слова

    static string Scope(DecisionFeatures key, Level level)
    {
        var parts = new List<string> { Noun(key), Place(key.Place) }.Where(p => p.Length > 0).ToList();
        if (level != Level.Placed) parts.Add(Size(key.Size));
        var text = string.Join(" ", parts);
        if (level == Level.Exact && Age(key.Age) is { } age) text += ", " + age;
        return text;
    }

    static string Noun(DecisionFeatures key) => key.Kind switch
    {
        DecisionKind.Folder => "папки",
        DecisionKind.Project => "проекты с git",
        DecisionKind.Copy => (key.Category ?? DecisionCategory.Other) switch
        {
            DecisionCategory.Video => "копии видео",
            DecisionCategory.Audio => "копии музыки и звука",
            DecisionCategory.Image => "копии фото и картинок",
            DecisionCategory.Archive => "копии архивов",
            DecisionCategory.Installer => "копии образов дисков и установщиков",
            DecisionCategory.Document => "копии документов",
            _ => "копии файлов",
        },
        _ => (key.Category ?? DecisionCategory.Other) switch
        {
            DecisionCategory.Video => "видео",
            DecisionCategory.Audio => "музыка и звук",
            DecisionCategory.Image => "фото и картинки",
            DecisionCategory.Archive => "архивы",
            DecisionCategory.Installer => "образы дисков и установщики",
            DecisionCategory.Document => "документы",
            _ => "файлы",
        },
    };

    static readonly Dictionary<string, string> PlaceNames = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Downloads"] = "в «Загрузках»", ["Desktop"] = "на «Рабочем столе»", ["Documents"] = "в «Документах»",
        ["Videos"] = "в «Видео»", ["Music"] = "в «Музыке»", ["Pictures"] = "в «Изображениях»", ["AppData"] = "в «AppData»",
    };

    static string Place(string name) => name.Length == 0 ? "" : PlaceNames.TryGetValue(name, out var known) ? known : $"в «~\\{name}»";

    static string Size(DecisionSize size) => size switch
    {
        DecisionSize.Small => "меньше 100 МБ",
        DecisionSize.Medium => "от 100 МБ до 1 ГБ",
        DecisionSize.Large => "от 1 до 10 ГБ",
        _ => "больше 10 ГБ",
    };

    static string? Age(DecisionAge age) => age switch
    {
        DecisionAge.Fresh => "менялись в последний месяц",
        DecisionAge.Recent => "менялись 1–3 месяца назад",
        DecisionAge.Old => "не менялись от 3 месяцев до года",
        DecisionAge.Ancient => "не менялись больше года",
        _ => null,
    };
}
