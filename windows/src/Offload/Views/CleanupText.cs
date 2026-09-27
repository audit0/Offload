using Offload.Core;

namespace Offload;

/// <summary>Как действие разбора выглядит в интерфейсе.</summary>
public static class CleanupActionDisplay
{
    public static string Title(this CleanupAction action) => action switch
    {
        CleanupAction.Trash => "В Корзину",
        CleanupAction.Safe => "В сейф",
        CleanupAction.Backup => "В бэкап",
        _ => "Оставить",
    };

    public static string Glyph(this CleanupAction action) => action switch
    {
        CleanupAction.Trash => Glyphs.Trash,
        CleanupAction.Safe => Glyphs.Lock,
        CleanupAction.Backup => Glyphs.Backup,
        _ => CleanupGlyphs.Pin,
    };

    public static Tone Tone(this CleanupAction action) => action switch
    {
        CleanupAction.Trash => Offload.Tone.Danger,
        CleanupAction.Safe => Offload.Tone.Good,
        CleanupAction.Backup => Offload.Tone.Brand,
        _ => Offload.Tone.Neutral,
    };
}

/// <summary>Как плитка разбора выглядит в интерфейсе.</summary>
public static class CleanupModuleDisplay
{
    public static string Title(this CleanupModule module) => module switch
    {
        CleanupModule.Junk => "Мусор",
        CleanupModule.Safe => "Крупное и старое",
        CleanupModule.Duplicates => "Лишние копии",
        CleanupModule.Installers => "Установщики",
        _ => "Проекты без бэкапа",
    };

    public static string Glyph(this CleanupModule module) => module switch
    {
        CleanupModule.Junk => Glyphs.Trash,
        CleanupModule.Safe => Glyphs.Shield,
        CleanupModule.Duplicates => Glyphs.Copy,
        CleanupModule.Installers => Glyphs.Download,
        _ => Glyphs.Backup,
    };

    public static Tone Tone(this CleanupModule module) => module switch
    {
        CleanupModule.Junk => Offload.Tone.Brand,
        CleanupModule.Safe => Offload.Tone.Good,
        CleanupModule.Duplicates => Offload.Tone.Caution,
        CleanupModule.Installers => Offload.Tone.Info,
        _ => Offload.Tone.Brand,
    };
}

/// <summary>Значки разбора, которых нет в общем наборе, — из того же шрифта Segoe Fluent Icons.</summary>
public static class CleanupGlyphs
{
    public const string Pin = "";
    public const string Video = "";
    public const string Music = "";
    public const string Pictures = "";
    public const string Tools = "";
    public const string Hide = "";
}

/// <summary>Как вопрос звучит и что показывает.</summary>
public static class CleanupQuestionDisplay
{
    public static string Glyph(this CleanupQuestion question) =>
        question.Kind.Type == QuestionKindType.Docker ? Glyphs.Package : question.Kind.Module.Glyph();

    public static Tone Tone(this CleanupQuestion question) =>
        question.Kind.Type == QuestionKindType.Docker ? Offload.Tone.Info : question.Kind.Module.Tone();

    public static string Title(this CleanupQuestion question) => question.Kind.Type == QuestionKindType.Docker ? "Очистить Docker?" : question.Kind.Module switch
    {
        CleanupModule.Junk => "Удалить мусор?",
        CleanupModule.Duplicates => "Удалить лишние копии?",
        CleanupModule.Installers => "Удалить старые установщики?",
        CleanupModule.Safe => "Убрать в сейф крупное и старое?",
        _ => "Добавить проекты в бэкап?",
    };

    /// <summary>Что именно и что будет по «да» — одним абзацем.</summary>
    public static string Text(this CleanupQuestion question)
    {
        var labels = question.Labels;
        if (question.Kind.Type == QuestionKindType.Docker)
        {
            var parts = new List<string>();
            if (question.Docker.TryGetValue(DockerPruneTarget.BuildCache, out var cache)) parts.Add($"кеш сборки ({Format.Bytes(cache)})");
            if (question.Docker.ContainsKey(DockerPruneTarget.DanglingImages)) parts.Add("образы без имени — остатки пересборок");
            var what = string.Join(" и ", parts);
            if (what.Length > 0) what = char.ToUpper(what[0]) + what[1..];
            return $"{what}. Кеш наберётся при следующей сборке. Образы с именем, тома с данными и контейнеры не трогаю; все неиспользуемые образы можно убрать в разделе «Docker».";
        }
        switch (question.Kind.Module)
        {
            case CleanupModule.Junk:
                return $"{List(labels, false)} — программы создадут это заново.";
            case CleanupModule.Duplicates:
            {
                int count = question.Items.Count;
                int groups = question.Items.Select(i => i.DuplicateGroup).Where(g => g != null).Distinct().Count();
                return $"{count} {Plural.Ru(count, "лишняя копия", "лишние копии", "лишних копий")} одинаковых файлов ({groups} {Plural.Ru(groups, "группа", "группы", "групп")}): " +
                       $"{List(labels, true)}. У каждого файла останется одна копия — та, что лежит на своём месте, — и каждая лишняя перед удалением сверяется с ней байт в байт.";
            }
            case CleanupModule.Installers:
                return $"{List(labels, true)} — .exe, .msi и .msix старше недели. Если программа понадобится снова, установщик можно скачать. " +
                       "Посмотрите список ниже: «Разрешить всё» установщики не удаляет, только ответ здесь.";
            case CleanupModule.Safe:
                return $"{List(labels, true)} — не менялось больше трёх месяцев. Перенесу в сейф со сверкой каждого файла и уберу с компьютера; вернуть можно в «Перенесённом».";
            default:
                return $"{List(labels, true)} — папки с git, которых нет в бэкапе. Ничего не удаляется: они только добавятся в список папок бэкапа.";
        }
    }

    public static string YesTitle(this CleanupQuestion question) => question.Kind.Type == QuestionKindType.Docker ? "Очистить" : question.Kind.Module switch
    {
        CleanupModule.Duplicates => "Удалить копии",
        CleanupModule.Safe => "Убрать в сейф",
        CleanupModule.Projects => "Добавить",
        _ => "Удалить",
    };

    public const string NoTitle = "Не сейчас";

    /// <summary>Размер справа: сколько освободится, у проектов — сколько папок.</summary>
    public static string Amount(this CleanupQuestion question)
    {
        if (question.Kind == QuestionKind.Of(CleanupModule.Projects))
            return $"{question.Items.Count} {Plural.Ru(question.Items.Count, "папка", "папки", "папок")}";
        return Format.Bytes(question.Bytes);
    }

    /// <summary>«Кеш npm, кеш pip и ещё 3» или «Датасеты», «Съёмки 2023» и ещё 2».</summary>
    public static string List(IReadOnlyList<string> labels, bool quoted)
    {
        var shown = labels.Take(3).Select((label, index) =>
        {
            if (quoted) return $"«{label}»";
            return index == 0 || label.Length == 0 ? label : char.ToLower(label[0]) + label[1..];
        }).ToList();
        int rest = labels.Count - shown.Count;
        var head = string.Join(", ", shown);
        return rest > 0 ? $"{head} и ещё {rest}" : head;
    }

    /// <summary>Что сделано по ответу «да» — одной строкой.</summary>
    public static string DoneLine(this CleanupQuestion question, CleanupModel.Outcome outcome)
    {
        var parts = new List<string>();
        if (outcome.Done == 0)
        {
            parts.Add(outcome.Cancelled ? "Остановлено, ничего не сделано" : "Не получилось");
        }
        else
        {
            if (question.Kind == QuestionKind.Of(CleanupModule.Projects))
                parts.Add($"Добавлено в бэкап: {outcome.Done}. Обновите бэкап, чтобы они в него попали");
            else if (question.Kind == QuestionKind.Of(CleanupModule.Safe))
                parts.Add($"Убрано в сейф: {Format.Bytes(outcome.Bytes)}, {outcome.Done} из {question.Items.Count}");
            else if (question.Kind.Type == QuestionKindType.Docker)
                parts.Add(outcome.Bytes > 0 ? $"Docker удалил {Format.Bytes(outcome.Bytes)}" : "Docker очищен");
            else
                parts.Add($"В Корзине: {Format.Bytes(outcome.Bytes)}, {outcome.Done} из {question.Items.Count}");
            if (outcome.Cancelled) parts.Add("остальное остановлено");
        }
        if (outcome.Restored > 0) parts.Add($"возвращено на место: {outcome.Restored}");
        return string.Join(" · ", parts);
    }
}
