namespace Offload.Core;

public enum QuestionKindType { Module, Docker }

/// <summary>Вид вопроса: по плитке разбора или про Docker.</summary>
public readonly record struct QuestionKind(QuestionKindType Type, CleanupModule Module = CleanupModule.Junk)
{
    public static QuestionKind Of(CleanupModule module) => new(QuestionKindType.Module, module);
    public static readonly QuestionKind Docker = new(QuestionKindType.Docker);
    public override string ToString() => Type == QuestionKindType.Docker ? "docker" : Module.ToString();
}

/// <summary>Вопрос после разбора: одно «да» или «нет» на целую группу найденного. Человек не выбирает
/// по файлам и не ходит по папкам — Offload сам собирает, что можно убрать, и спрашивает разрешения.</summary>
public sealed record CleanupQuestion(
    QuestionKind Kind,
    /// <summary>С чем что-то произойдёт при «да». У Docker пусто.</summary>
    IReadOnlyList<CleanupSuggestion> Items,
    /// <summary>Копии, которые остаются: с ними лишние сверяются перед удалением.</summary>
    IReadOnlyList<CleanupSuggestion> Keepers,
    /// <summary>Сколько освободится на компьютере. Бэкап места не освобождает — у проектов ноль.</summary>
    long Bytes,
    /// <summary>Что уберёт Docker и сколько каждого (0 — Docker не сообщает размер).</summary>
    IReadOnlyDictionary<DockerPruneTarget, long> Docker,
    /// <summary>Найдено, но в вопрос не вошло, — и почему (кеш открытой программы).</summary>
    IReadOnlyList<string> Notes)
{
    public QuestionKind Id => Kind;

    public CleanupAction Action => Kind.Type == QuestionKindType.Docker ? CleanupAction.Trash : Kind.Module.Action();

    /// <summary>Отвечается вместе со всеми по «Разрешить всё». Установщики — нет: удалить их решает человек,
    /// глядя на список, поэтому только отдельным «да» на их вопрос.</summary>
    public bool AnsweredTogether => Kind != QuestionKind.Of(CleanupModule.Installers);

    /// <summary>Короткие названия того, что в вопросе, для одной строки: «Кеш npm», «Отпуск 2023.mov».</summary>
    public List<string> Labels => Kind.Type switch
    {
        QuestionKindType.Docker => [],
        _ when Kind.Module == CleanupModule.Junk => Items.Select(item =>
        {
            var known = CleanupPlanner.RegenerableLocations.FirstOrDefault(l =>
                item.Path.EndsWith("\\" + l.Path, Paths.Comparison) || (l.Children != null && item.Path.Contains("\\" + l.Path + "\\", Paths.Comparison)));
            return known?.Reason.Split(" — ")[0] ?? item.Name;
        }).Distinct().ToList(),
        _ => Items.Select(i => i.Name).ToList(),
    };
}

public static class CleanupQuestions
{
    /// <summary>О Docker спрашиваем, если он отдаст хотя бы столько.</summary>
    public const long DockerMinimumBytes = 100_000_000;
    /// <summary>Что убирает Docker по «да»: только то, что точно не нужно. Все неиспользуемые образы — нет:
    /// собранный человеком и никуда не отправленный образ не скачать заново. Остановленных контейнеров тоже нет.</summary>
    public static readonly DockerPruneTarget[] DockerTargets = [DockerPruneTarget.BuildCache, DockerPruneTarget.DanglingImages];

    /// <summary>Вопросы в том порядке, в котором их задавать: сначала то, что пересоздаётся само, потом личное.
    /// Виртуальные машины здесь не удаляются: удалять и переносить их нужно средствами WSL или VirtualBox.</summary>
    public static List<CleanupQuestion> Build(IReadOnlyList<CleanupSuggestion> suggestions, DockerUsage? docker = null)
    {
        List<CleanupSuggestion> Found(CleanupModule module) => suggestions.Where(s => s.Module == module).ToList();
        static long Total(IEnumerable<CleanupSuggestion> items) => items.Sum(i => i.Bytes);
        var empty = new Dictionary<DockerPruneTarget, long>();
        var questions = new List<CleanupQuestion>();

        // Мусор. Кеш открытой программы в вопрос не входит — о нём заметка, чтобы было понятно почему.
        var junk = Found(CleanupModule.Junk);
        var removable = junk.Where(s => s.Action == CleanupAction.Trash).ToList();
        if (removable.Count > 0)
            questions.Add(new CleanupQuestion(QuestionKind.Of(CleanupModule.Junk), removable, [], Total(removable), empty,
                junk.Where(s => s.Action == CleanupAction.Keep && !s.Learned && !s.Habit).Select(s => s.Reason).Distinct().ToList()));

        if (docker != null)
        {
            var parts = new Dictionary<DockerPruneTarget, long>();
            foreach (var target in DockerTargets)
            {
                // Образы без имени: сколько они занимают, docker system df не сообщает, а чистить их надо всё равно.
                if (target == DockerPruneTarget.DanglingImages) { parts[target] = 0; continue; }
                if (docker.Part(target)?.Reclaimable is > 0 and var bytes) parts[target] = bytes;
            }
            long total = parts.Values.Sum();
            if (total >= DockerMinimumBytes) questions.Add(new CleanupQuestion(QuestionKind.Docker, [], [], total, parts, []));
        }

        // Лишние копии. Копия внутри папки, которую можно убрать в сейф, едет вместе с папкой.
        var safe = Found(CleanupModule.Safe).Where(s => s.Action == CleanupAction.Safe).ToList();
        var copies = suggestions.Where(s => s.DuplicateGroup != null).ToList();
        var redundant = copies.Where(s => s.Action == CleanupAction.Trash && CleanupPlanner.Container(s, safe) == null).ToList();
        if (redundant.Count > 0)
        {
            var groups = redundant.Select(r => r.DuplicateGroup!).ToHashSet();
            questions.Add(new CleanupQuestion(QuestionKind.Of(CleanupModule.Duplicates), redundant,
                copies.Where(c => c.Action != CleanupAction.Trash && groups.Contains(c.DuplicateGroup!)).ToList(), Total(redundant), empty, []));
        }

        // Установщики — все старые, кроме тех, что вы уже возвращали из Корзины.
        var installers = Found(CleanupModule.Installers)
            .Where(s => s.Allowed.Contains(CleanupAction.Trash) && !(s.Action == CleanupAction.Keep && (s.Learned || s.Habit))).ToList();
        if (installers.Count > 0) questions.Add(new CleanupQuestion(QuestionKind.Of(CleanupModule.Installers), installers, [], Total(installers), empty, []));

        if (safe.Count > 0) questions.Add(new CleanupQuestion(QuestionKind.Of(CleanupModule.Safe), safe, [], Total(safe), empty, []));

        var projects = Found(CleanupModule.Projects).Where(s => s.Action == CleanupAction.Backup).ToList();
        if (projects.Count > 0) questions.Add(new CleanupQuestion(QuestionKind.Of(CleanupModule.Projects), projects, [], 0, empty, []));
        return questions;
    }
}
