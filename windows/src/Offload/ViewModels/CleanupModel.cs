using System.Diagnostics;
using System.IO;
using Offload.Core;

namespace Offload;

/// <summary>Разбор компьютера: поиск → вопросы → ответы. Человек не выбирает по файлам и не ходит по папкам:
/// OffLoadAI сам раскладывает найденное по вопросам («Удалить мусор — 12 ГБ?», «Очистить Docker?»),
/// а на каждый отвечают «да» или «не сейчас». Сделанное по «да» видно сразу у вопроса.
///
/// Удаление — только в Корзину (образы Docker удаляет сам Docker), и ушедшее туда можно вернуть у своего вопроса
/// или удалить насовсем в конце, чтобы место освободилось сразу. Перенос в сейф — тот же, что в «Освободить место»,
/// со сверкой; лишняя копия перед удалением сверяется с остающейся байт в байт.</summary>
public sealed class CleanupModel : Observable
{
    public enum StageKind { Idle, Scanning, Review }

    /// <summary>Поиск: сколько просмотрено, что сейчас и что уже нашлось по видам.</summary>
    public sealed record ScanProgress(int Done = 0, int Total = 0, string Current = "", IReadOnlyDictionary<CleanupModule, long>? Found = null,
                                      bool Duplicates = false, int Files = 0)
    {
        public IReadOnlyDictionary<CleanupModule, long> FoundBytes => Found ?? new Dictionary<CleanupModule, long>();
        public double Fraction => Total > 0 ? Math.Min(1, (double)Done / Total) : 0;
    }

    public sealed record Progress(int Index, int Count, string Item, string Phase, double Fraction);

    /// <summary>Что ушло в Корзину в этот раз: откуда и где лежит теперь.</summary>
    public sealed record TrashedItem(string Original, string InTrash, long Bytes, FileIdentity? Identity)
    {
        /// <summary>По пути в Корзине лежит то самое, что туда отправил разбор.</summary>
        public bool IsStillInTrash => Identity != null && FileIdentity.Of(InTrash) == Identity;
    }

    /// <summary>Что сделано по одному вопросу.</summary>
    public sealed record Outcome
    {
        public int Done { get; init; }
        public long Bytes { get; init; }
        /// <summary>Сколько из сделанного — лишние копии, сверенные с остающейся.</summary>
        public int Duplicates { get; init; }
        public List<TrashedItem> TrashedItems { get; init; } = [];
        public int Restored { get; init; }
        /// <summary>Что не сделано и почему — каждое отдельной строкой.</summary>
        public List<string> Problems { get; init; } = [];
        public bool Cancelled { get; init; }
    }

    public enum AnswerKind { Asking, Queued, Running, Done, Declined }

    public sealed record Answer(AnswerKind Kind, Progress? Running = null, Outcome? Result = null)
    {
        public static readonly Answer Asking = new(AnswerKind.Asking);
        public static readonly Answer Queued = new(AnswerKind.Queued);
        public static readonly Answer Declined = new(AnswerKind.Declined);
    }

    StageKind stage = StageKind.Idle;
    public StageKind Stage { get => stage; private set { Set(ref stage, value); Raise(nameof(IsBusy)); } }
    ScanProgress scan = new();
    public ScanProgress Scan { get => scan; private set => Set(ref scan, value); }
    List<CleanupQuestion> questions = [];
    public List<CleanupQuestion> Questions { get => questions; private set { Set(ref questions, value); RaiseAnswers(); } }
    Dictionary<QuestionKind, Answer> answers = [];
    Dictionary<QuestionKind, string> hints = [];
    public IReadOnlyDictionary<QuestionKind, string> Hints => hints;
    long? dockerIdle;
    /// <summary>Docker стоит, но не запущен: столько занимает его диск, а что в нём можно убрать, не узнать.</summary>
    public long? DockerIdle { get => dockerIdle; private set => Set(ref dockerIdle, value); }
    long? freeBefore, freeNow;
    int erased;
    public int Erased { get => erased; private set => Set(ref erased, value); }
    long erasedBytes;
    public long ErasedBytes { get => erasedBytes; private set => Set(ref erasedBytes, value); }
    List<string> trashProblems = [];
    public List<string> TrashProblems { get => trashProblems; private set => Set(ref trashProblems, value); }
    DecisionStore.Run? lastRun;
    public DecisionStore.Run? LastRun { get => lastRun; private set => Set(ref lastRun, value); }
    string? storeProblem;
    /// <summary>База решений не открылась: разбор работает, но ничего не запоминает.</summary>
    public string? StoreProblem { get => storeProblem; private set => Set(ref storeProblem, value); }
    List<HabitModel.Prediction> habits = [];
    public List<HabitModel.Prediction> Habits { get => habits; private set => Set(ref habits, value); }
    int remembered;
    public int Remembered { get => remembered; private set => Set(ref remembered, value); }
    string? forgetProblem;
    public string? ForgetProblem { get => forgetProblem; private set => Set(ref forgetProblem, value); }
    List<string> ignored = [];
    public List<string> Ignored { get => ignored; private set => Set(ref ignored, value); }
    string? ignoreProblem;
    public string? IgnoreProblem { get => ignoreProblem; private set => Set(ref ignoreProblem, value); }
    string? finishing;
    /// <summary>Что делается с ушедшим в Корзину («Возвращаю…»): пока не null, кнопки заблокированы.</summary>
    public string? Finishing { get => finishing; private set { Set(ref finishing, value); Raise(nameof(IsBusy)); } }

    readonly DecisionStore? store;
    CancelToken scanToken = new();
    CancelToken workToken = new();
    /// <summary>Вопросы, на которые ответили «да», по очереди: диск работает над одним.</summary>
    readonly List<QuestionKind> queue = [];
    bool working;
    /// <summary>Всё найденное: из него вопросы собираются заново, когда человек просит что-то не предлагать.</summary>
    List<CleanupSuggestion> suggestions = [];
    DockerUsage? docker;
    bool runRecorded;

    public CleanupModel()
    {
        try
        {
            // В демонстрации база в памяти: вымышленные решения не должны попасть в настоящую.
            store = new DecisionStore(Demo.IsOn ? null : DecisionStore.DefaultPath);
            if (Demo.IsOn) store.Record(Demo.Decisions());
            lastRun = store.LastRun();
            ignored = store.IgnoredPaths();
        }
        catch (Exception error) { storeProblem = error.Message; }
    }

    /// <summary>Перечитывает, чему научился OffLoadAI: при открытии раздела, после разбора и после «Забыть».</summary>
    public void LoadHabits(string home)
    {
        if (store == null) return;
        try
        {
            Habits = new HabitModel(store.History(), home).Habits();
            Remembered = store.LastDecisions().Count;
        }
        catch (DecisionStore.StoreException) { }
    }

    /// <summary>Забывает все решения — и «как в прошлый раз», и привычки. Итоги прошлых разборов и то,
    /// что вы просили не предлагать, остаются.</summary>
    public void ForgetDecisions(string home)
    {
        if (IsBusy) return;
        try
        {
            store?.ForgetDecisions();
            ForgetProblem = null;
        }
        catch (DecisionStore.StoreException error) { ForgetProblem = error.Message; }
        LoadHabits(home);
    }

    public bool IsBusy => Stage == StageKind.Scanning || working || Finishing != null;

    // MARK: Вопросы и ответы

    public CleanupQuestion? Question(QuestionKind kind) => Questions.FirstOrDefault(q => q.Kind == kind);

    public Answer AnswerFor(QuestionKind kind) => answers.GetValueOrDefault(kind) ?? Answer.Asking;

    /// <summary>На что ещё не ответили.</summary>
    public List<CleanupQuestion> Asking => Questions.Where(q => AnswerFor(q.Kind).Kind == AnswerKind.Asking).ToList();

    /// <summary>Сколько освободится, если на всё неотвеченное сказать «да».</summary>
    public long PendingBytes => Asking.Sum(q => q.Bytes);

    /// <summary>Всё ушедшее в Корзину в этом разборе.</summary>
    public List<TrashedItem> TrashedItems => Questions.SelectMany(q => AnswerFor(q.Kind).Result?.TrashedItems ?? []).ToList();

    public bool HasDone => Questions.Any(q => AnswerFor(q.Kind).Kind == AnswerKind.Done);

    /// <summary>На всё ответили, и ничего не делается.</summary>
    public bool IsSettled => !working && Questions.All(q => AnswerFor(q.Kind).Kind is AnswerKind.Done or AnswerKind.Declined);

    /// <summary>Освободилось на компьютере — по замеру свободного места.</summary>
    public long? Freed => freeBefore is { } before && freeNow is { } now ? now - before : null;

    /// <summary>Свободно на компьютере по последнему замеру.</summary>
    public long? FreeNow => freeNow;

    void SetAnswer(QuestionKind kind, Answer answer)
    {
        answers = new Dictionary<QuestionKind, Answer>(answers) { [kind] = answer };
        RaiseAnswers();
    }

    void RaiseAnswers() => Raise(nameof(Asking), nameof(PendingBytes), nameof(TrashedItems), nameof(HasDone), nameof(IsSettled), nameof(Freed), nameof(FreeNow),
                                 nameof(Hints), "AnswerVersion", nameof(IsBusy));

    /// <summary>«Да» на вопрос о сейфе требует открытого сейфа: сначала спросить пароль.</summary>
    public bool NeedsSafe(QuestionKind kind, AppModel app) => kind == QuestionKind.Of(CleanupModule.Safe) && app.SafeVolume == null && !Demo.IsOn;

    /// <summary>Ответ на вопрос. «Да» ставит его в очередь; «не сейчас» ничего не запоминает — в следующий раз спрошу снова.</summary>
    public void Respond(QuestionKind kind, bool yes, AppModel app)
    {
        if (Stage != StageKind.Review || Question(kind) == null || AnswerFor(kind).Kind != AnswerKind.Asking) return;
        hints = new Dictionary<QuestionKind, string>(hints);
        hints.Remove(kind);
        if (!yes)
        {
            SetAnswer(kind, Answer.Declined);
            Settle(app);
            return;
        }
        if (NeedsSafe(kind, app)) return;
        if (kind.ProFeature() is { } feature && !app.Pro.Allows(feature))
        {
            app.Pro.Offer(feature);
            return;
        }
        SetAnswer(kind, Answer.Queued);
        queue.Add(kind);
        Pump(app);
    }

    /// <summary>Вопрос из OffLoadAI Pro, а Pro на этом компьютере нет: «да» открывает окно Pro, «не сейчас» работает как всегда.</summary>
    public bool IsLocked(QuestionKind kind, AppModel app) => kind.ProFeature() is { } feature && !app.Pro.Allows(feature);

    /// <summary>«Разрешить всё»: «да» на каждый вопрос, кроме установщиков и вопросов из OffLoadAI Pro без ключа.
    /// Ответ — остался ли вопрос о сейфе ждать пароля.</summary>
    public bool RespondAll(AppModel app)
    {
        foreach (var question in Asking.Where(q => q.AnsweredTogether && !NeedsSafe(q.Kind, app) && !IsLocked(q.Kind, app)))
            Respond(question.Kind, true, app);
        return Asking.Any(q => q.Kind == QuestionKind.Of(CleanupModule.Safe));
    }

    /// <summary>Передумал: спросить снова после «не сейчас» или убрать из очереди, пока не начато.</summary>
    public void Reconsider(QuestionKind kind)
    {
        switch (AnswerFor(kind).Kind)
        {
            case AnswerKind.Declined:
                SetAnswer(kind, Answer.Asking);
                break;
            case AnswerKind.Queued:
                queue.RemoveAll(k => k == kind);
                SetAnswer(kind, Answer.Asking);
                break;
        }
    }

    /// <summary>Остановить то, что делается сейчас. Сделанное до остановки остаётся.</summary>
    public void Stop() => workToken.Cancel();

    void Record(IEnumerable<DecisionStore.Decision> decisions)
    {
        try { store?.Record(decisions); }
        catch (DecisionStore.StoreException error) { StoreProblem = error.Message; }
    }

    // MARK: Очередь

    async void Pump(AppModel app)
    {
        if (working || queue.Count == 0) return;
        var kind = queue[0];
        queue.RemoveAt(0);
        if (Question(kind) is not { } question)
        {
            Pump(app);
            return;
        }
        working = true;
        var token = new CancelToken();
        workToken = token;
        // Выход во время работы спросит и доведёт остановку до конца, как при переносе.
        var operation = app.BeginOperation(token.Cancel);
        SetAnswer(kind, new Answer(AnswerKind.Running, new Progress(0, Math.Max(question.Items.Count, 1), "", "Подготовка", 0)));
        var home = app.Rules.Home;
        freeBefore ??= await FreeSpace(home);
        var outcome = await Perform(question, app, token);
        SetAnswer(kind, outcome != null ? new Answer(AnswerKind.Done, Result: outcome) : Answer.Asking);
        // «Остановить» или выход из программы останавливает и очередь: ждавшие своего черёда снова ждут ответа.
        if (token.IsCancelled)
        {
            foreach (var waiting in queue) SetAnswer(waiting, Answer.Asking);
            queue.Clear();
        }
        freeNow = await FreeSpace(home);
        working = false;
        app.EndOperation(operation);
        app.Space.InvalidateAll();
        app.RefreshVolumes();
        if (question.Action == CleanupAction.Safe) app.History.Reload(app.HistoryVolumes);
        RaiseAnswers();
        Settle(app);
        Pump(app);
    }

    /// <summary>null — не выполнено и спросить надо снова.</summary>
    Task<Outcome?> Perform(CleanupQuestion question, AppModel app, CancelToken token) =>
        question.Kind.Type == QuestionKindType.Docker ? PerformDocker(question, app) : PerformItems(question, question.Kind.Module.Action(), app, token);

    void Running(QuestionKind kind, Progress progress) => SetAnswer(kind, new Answer(AnswerKind.Running, progress));

    async Task<Outcome?> PerformItems(CleanupQuestion question, CleanupAction action, AppModel app, CancelToken token)
    {
        var kind = question.Kind;
        // «Да» — решение по каждому объекту вопроса. Запоминается сразу, даже если выполнение потом остановят.
        Record(question.Items.Select(i => new DecisionStore.Decision(i.Id, action, i.Bytes, action, i.Kind, i.Modified)));
        var rules = app.Rules;
        var throttle = new Throttle();
        var items = question.Items;
        int done = 0, duplicates = 0;
        long bytes = 0;
        var trashed = new List<TrashedItem>();
        var problems = new List<string>();
        bool cancelled = false;
        for (int index = 0; index < items.Count; index++)
        {
            if (token.IsCancelled)
            {
                cancelled = true;
                break;
            }
            var item = items[index];
            var name = item.Name;
            Running(kind, new Progress(index + 1, items.Count, name, Phase(action), 0));
            switch (action)
            {
                case CleanupAction.Backup:
                    if (!app.Backup.Sources.Any(s => Paths.Same(s, item.Path))) app.Backup.Sources = [.. app.Backup.Sources, item.Path];
                    done++;
                    break;
                case CleanupAction.Trash when item.DuplicateGroup != null:
                {
                    if (Demo.IsOn)
                    {
                        done++;
                        bytes += item.Bytes;
                        duplicates++;
                        continue;
                    }
                    // Сверяем с копией, которая остаётся и всё ещё на месте (папку с ней могли убрать в сейф).
                    var reference = question.Keepers.FirstOrDefault(k => k.DuplicateGroup == item.DuplicateGroup && File.Exists(k.Path));
                    if (reference == null)
                    {
                        problems.Add($"«{name}» осталось на месте: копии, с которой его можно сверить, на месте уже нет.");
                        continue;
                    }
                    Running(kind, new Progress(index + 1, items.Count, name, "Сверка с копией", 0));
                    long total = Math.Max(item.Bytes, 1);
                    var compared = new Counter();
                    try
                    {
                        // Сверяется содержимое, а не отпечаток из поиска: файл могли изменить после него.
                        var result = await Task.Run(() =>
                        {
                            bool same = DuplicateFinder.SameContent(item.Path, reference.Path, () => token.IsCancelled, read =>
                            {
                                long so = compared.Add(read);
                                if (!throttle.Ready()) return;
                                Ui.Post(() =>
                                {
                                    if (AnswerFor(kind).Running is { } current && current.Item == name)
                                        Running(kind, current with { Fraction = Math.Min(1, (double)so / total) });
                                });
                            });
                            return same ? RecycleBin.Trash(item.Path) : ((string, FileIdentity?)?)null;
                        });
                        if (result is not { } moved)
                        {
                            problems.Add($"«{name}» осталось на месте: после поиска оно изменилось и больше не совпадает с «{reference.Name}».");
                            continue;
                        }
                        done++;
                        bytes += item.Bytes;
                        duplicates++;
                        trashed.Add(new TrashedItem(item.Path, moved.Item1, item.Bytes, moved.Item2));
                    }
                    catch (OperationCanceledException)
                    {
                        cancelled = true;
                        index = items.Count;
                    }
                    catch (Exception error) { problems.Add($"«{name}» не удалось отправить в Корзину: {error.Message}"); }
                    break;
                }
                case CleanupAction.Trash:
                {
                    if (Demo.IsOn)
                    {
                        done++;
                        bytes += item.Bytes;
                        continue;
                    }
                    var path = item.Path;
                    // Программу могли открыть уже после поиска: кеш занятой программы на ходу не удаляем.
                    if (CleanupPlanner.BusyIn(rules.Home, RunningApplications()).TryGetValue(path, out var busy))
                    {
                        problems.Add($"«{name}» осталось на месте. {busy}");
                        continue;
                    }
                    // Кеши npm, pip, NuGet, Gradle держат не программы с окном, а консольные процессы — их видно только по открытым файлам.
                    var holders = await Task.Run(() => SafeMover.OpenFiles(path));
                    if (holders is { Count: > 0 })
                    {
                        problems.Add($"«{name}» осталось на месте: его сейчас использует {string.Join(", ", holders.Take(3))}.");
                        continue;
                    }
                    try
                    {
                        var moved = await Task.Run(() => RecycleBin.Trash(path));
                        done++;
                        bytes += item.Bytes;
                        trashed.Add(new TrashedItem(path, moved.path, item.Bytes, moved.identity));
                    }
                    catch (Exception error) { problems.Add(error is RecycleBin.RecycleException ? error.Message : $"«{name}» не удалось отправить в Корзину: {error.Message}"); }
                    break;
                }
                case CleanupAction.Safe:
                {
                    var volume = app.SafeVolume ?? (Demo.IsOn ? Demo.SafeVolume : null);
                    if (volume == null)
                    {
                        problems.Add($"«{name}»: сейф закрыт — осталось на месте.");
                        continue;
                    }
                    if (Demo.IsOn)
                    {
                        done++;
                        bytes += item.Bytes;
                        continue;
                    }
                    var source = item.Path;
                    var shown = item.Cautions.ToHashSet();
                    var plan = await Task.Run(() => new SafeMover(rules).Plan(source, volume, () => token.IsCancelled));
                    if (token.IsCancelled)
                    {
                        cancelled = true;
                        index = items.Count;
                        break;
                    }
                    if (!plan.CanProceed)
                    {
                        var reason = (plan.Verdict.IsBlocked ? plan.Verdict.Notes : plan.Check.Blockers).FirstOrDefault() ?? "перенос невозможен";
                        problems.Add($"«{name}»: {reason}");
                        continue;
                    }
                    // Оговорки, которых человек не видел, когда разрешал, — повод спросить отдельно, а не перенести молча.
                    if (plan.Verdict.IsCaution && plan.Verdict.Notes.FirstOrDefault(n => !shown.Contains(n)) is { } unseen)
                    {
                        problems.Add($"«{name}» осталось на месте: {unseen} Перенесите вручную в «Освободить место», если уверены.");
                        continue;
                    }
                    try
                    {
                        var moved = await Task.Run(() => new SafeMover(rules).Execute(plan, true, true, () => token.IsCancelled, progress =>
                        {
                            if (!throttle.Ready()) return;
                            Ui.Post(() =>
                            {
                                if (AnswerFor(kind).Running is { } current && current.Item == name)
                                    Running(kind, current with { Phase = progress.Phase.Title(), Fraction = progress.Fraction });
                            });
                        }));
                        done++;
                        bytes += moved.Bytes;
                    }
                    catch (OperationCanceledException)
                    {
                        cancelled = true;
                        index = items.Count;
                    }
                    catch (Exception error) { problems.Add($"«{name}»: {error.Message}"); }
                    break;
                }
            }
        }
        return new Outcome { Done = done, Bytes = bytes, Duplicates = duplicates, TrashedItems = trashed, Problems = problems, Cancelled = cancelled };
    }

    /// <summary>Кеш сборки и образы без контейнеров. Тома не трогаются.</summary>
    async Task<Outcome?> PerformDocker(CleanupQuestion question, AppModel app)
    {
        var kind = question.Kind;
        Running(kind, new Progress(1, 1, "Docker", "Очистка", 0));
        if (Demo.IsOn) return new Outcome { Done = 1, Bytes = question.Bytes };
        var service = new DockerService();
        long? rawBefore = service.RawDiskBytes();
        var targets = question.Docker.Keys.ToHashSet();
        Outcome outcome;
        try
        {
            var reclaimed = await Task.Run(() => service.Prune(targets));
            Running(kind, new Progress(1, 1, "Docker", "Жду, пока Docker вернёт место компьютеру", 1));
            await DockerModel.Settle(service, rawBefore);
            // Не сказал, сколько освободил, — так и пишем, а не подставляем оценку из вопроса.
            outcome = new Outcome { Done = 1, Bytes = reclaimed ?? 0, Problems = reclaimed == null ? ["Docker не сообщил, сколько места освободил."] : [] };
        }
        catch (DockerException error) when (error.Kind == DockerErrorKind.PruneIncomplete)
        {
            outcome = new Outcome { Done = error.Done, Bytes = error.Reclaimed ?? 0, Problems = [$"Docker очистил только часть, дальше остановился: {error.Detail}"] };
        }
        catch (Exception error) { outcome = new Outcome { Problems = [$"Docker: {error.Message}"] }; }
        // Раздел «Docker» показывал размеры до очистки.
        if (app.Docker.Status == DockerStatus.Ready) app.Docker.Reload(app);
        return outcome;
    }

    /// <summary>Ответили на всё и всё сделано — итог разбора запоминается.</summary>
    void Settle(AppModel app)
    {
        if (IsSettled) RecordRun(app.Rules.Home);
    }

    /// <summary>Итог разбора — один раз и только если что-то сделано.</summary>
    void RecordRun(string home)
    {
        if (!HasDone || runRecorded) return;
        runRecorded = true;
        long trashedBytes = 0, moved = 0;
        int added = 0, failures = 0;
        foreach (var question in Questions)
        {
            if (AnswerFor(question.Kind).Result is not { } outcome) continue;
            failures += outcome.Problems.Count;
            switch (question.Action)
            {
                case CleanupAction.Trash: trashedBytes += outcome.Bytes; break;
                case CleanupAction.Safe: moved += outcome.Bytes; break;
                case CleanupAction.Backup: added += outcome.Done; break;
            }
        }
        var run = new DecisionStore.Run(DateTime.UtcNow, trashedBytes, moved, added, failures);
        try { store?.RecordRun(run); } catch (DecisionStore.StoreException) { }
        LastRun = run;
        LoadHabits(home);
    }

    // MARK: Не предлагать

    /// <summary>Больше не предлагать объект (папку — вместе со всем, что внутри). Из вопроса он уходит сразу.</summary>
    public void Ignore(CleanupSuggestion suggestion)
    {
        var path = suggestion.Id;
        try
        {
            store?.Ignore(path);
            IgnoreProblem = null;
        }
        catch (DecisionStore.StoreException error)
        {
            IgnoreProblem = error.Message;
            return;
        }
        try { Ignored = store?.IgnoredPaths() ?? Ignored; } catch (DecisionStore.StoreException) { }
        suggestions = suggestions.Where(s => !Paths.IsWithin(s.Id, path)).ToList();
        // Лишняя копия без остающейся стала бы последней копией файла — такие группы уходят целиком.
        var groups = suggestions.Where(s => s.DuplicateGroup != null).GroupBy(s => s.DuplicateGroup!).ToDictionary(g => g.Key, g => g.Count());
        suggestions = suggestions.Where(s => s.DuplicateGroup is not { } group || groups.GetValueOrDefault(group) >= 2).ToList();
        Rebuild();
    }

    /// <summary>Снова предлагать — со следующего разбора.</summary>
    public void Unignore(string path)
    {
        try
        {
            store?.Unignore(path);
            IgnoreProblem = null;
            Ignored = store?.IgnoredPaths() ?? Ignored;
        }
        catch (DecisionStore.StoreException error) { IgnoreProblem = error.Message; }
    }

    /// <summary>Собирает заново вопросы, на которые ещё не ответили. На что ответили, то остаётся как было.</summary>
    void Rebuild()
    {
        var fresh = CleanupQuestions.Build(suggestions, docker);
        Questions = Questions.Select(old => AnswerFor(old.Kind).Kind != AnswerKind.Asking ? old : fresh.FirstOrDefault(f => f.Kind == old.Kind))
                             .Where(q => q != null).Select(q => q!).ToList();
    }

    // MARK: Поиск

    public async void Start(AppModel app)
    {
        if (IsBusy) return;
        RecordRun(app.Rules.Home);
        Clear();
        var rules = app.Rules;
        var memory = SafeGet(() => store?.LastDecisions()) ?? new Dictionary<string, CleanupAction>(Paths.Comparer);
        // Привычки — в Pro. Решения запоминаются и без него: купил — привычки действуют сразу.
        var habitModel = app.Pro.Allows(ProFeature.Habits) && SafeGet(() => store?.History()) is { } history
            ? new HabitModel(history, rules.Home) : null;
        var ignoredPaths = (SafeGet(() => store?.IgnoredPaths()) ?? []).ToHashSet(Paths.Comparer);
        if (Demo.IsOn)
        {
            Show(Demo.CleanupSuggestions(memory, habitModel), Demo.DockerUsage, null);
            return;
        }
        var token = new CancelToken();
        scanToken = token;
        var sources = app.Backup.Sources.ToList();
        // Кеш открытой программы в вопрос не входит: удалять его на ходу не стоит.
        var busy = CleanupPlanner.BusyIn(rules.Home, RunningApplications());
        var storeRef = store;
        Stage = StageKind.Scanning;
        Scan = new ScanProgress();
        var throttle = new Throttle(0.2);
        var tally = new ScanTally();
        // Docker — параллельно с поиском по папкам: docker system df думает десятки секунд.
        var apps = Task.Run(() =>
        {
            var service = new DockerService();
            DockerUsage? usage = null;
            long? idle = null;
            if (service.IsInstalled)
            {
                try
                {
                    service.EnsureRunning();
                    usage = service.Usage();
                }
                catch (Exception ex) when (ex is DockerException or RunnerException) { idle = service.RawDiskBytes(); }
            }
            return (usage, idle);
        });
        var found = await Task.Run(async () =>
        {
            var regenerable = CleanupPlanner.RegenerableIn(rules.Home);
            var roots = CleanupPlanner.Roots(rules.Home);
            // Папка прямо в домашней может сама быть git-репозиторием: её подпапки — части проекта.
            var gitRoots = roots.Where(r => FileSystem.Exists(Path.Combine(r, ".git"))).ToHashSet(Paths.Comparer);
            var attached = SecretsVault.AttachedImages();
            var seen = new HashSet<string>(Paths.Comparer);
            var paths = roots.SelectMany(SpaceScanner.Children).Concat(regenerable.Keys.Order(StringComparer.Ordinal)).Where(seen.Add).ToList();
            Ui.Post(() => { if (!token.IsCancelled) Scan = new ScanProgress(Total: paths.Count); });
            var planner = new CleanupPlanner { Home = rules.Home, Regenerable = regenerable, Memory = memory, Habits = habitModel, Busy = busy, Ignored = ignoredPaths };
            var collector = new Collector<CleanupObservation>();
            await SpaceScanner.Scan(paths, rules, () => token.IsCancelled, item =>
            {
                var path = item.Path;
                var parent = Paths.Parent(path);
                var ext = Paths.Extension(path);
                var observation = new CleanupObservation(
                    path, item.Bytes, item.Modified, item.IsDirectory,
                    gitRoots.Contains(parent) ? Verdict.Blocked($"Часть git-репозитория «{Paths.Name(parent)}». Переносите и сохраняйте проект целиком.") : item.Verdict,
                    item.IsDirectory && FileSystem.Exists(Path.Combine(path, ".git")),
                    sources.Any(s => Paths.IsWithin(path, s)),
                    !item.IsDirectory && ext is "vhdx" or "vhd" && SecretsVault.IsEncryptedImage(path, attached),
                    item.IsDirectory ? null : FileSystem.Stat(path)?.Created);
                collector.Append(observation);
                // Промежуточный итог — по тем же правилам, что и вопросы: видно, что поиск чего-то стоит.
                var progress = planner.IsIgnored(path) ? tally.Skip() : tally.Add(planner.Suggest(observation), planner.IsWorthShowing);
                if (!throttle.Ready()) return;
                var shown = progress with { Total = paths.Count, Current = item.Name };
                Ui.Post(() => { if (Stage == StageKind.Scanning && !token.IsCancelled) Scan = shown; });
            });
            if (token.IsCancelled) return [];

            // Второй этап — одинаковые файлы. Обход только что прошёл по тем же папкам, и кеш файловой системы тёплый.
            var measured = tally.Snapshot with { Duplicates = true };
            Ui.Post(() => { if (!token.IsCancelled) Scan = measured; });
            var started = DateTime.UtcNow;
            var known = SafeGet(() => storeRef?.Fingerprints()) ?? new Dictionary<string, Fingerprint>(Paths.Comparer);
            var result = new DuplicateFinder().Find(roots, rules, known, () => token.IsCancelled, progress =>
            {
                if (!throttle.Ready()) return;
                var shown = measured with { Files = progress.Files, Current = progress.Current };
                Ui.Post(() => { if (Stage == StageKind.Scanning && !token.IsCancelled) Scan = shown; });
            });
            // Только после законченного поиска: отпечатки прочитанных файлов — в базу, а те, которых поиск не коснулся, — забыть.
            if (result.Completed)
            {
                try
                {
                    storeRef?.SaveFingerprints(result.Fingerprints, started);
                    storeRef?.ForgetFingerprints(started);
                }
                catch (DecisionStore.StoreException) { }
            }
            return planner.Suggestions(collector.All, result.Groups);
        });
        if (Stage == StageKind.Scanning && !token.IsCancelled) Scan = Scan with { Current = "Docker…" };
        var external = await apps;
        if (token.IsCancelled)
        {
            Stage = StageKind.Idle;
            return;
        }
        Show(found, external.usage, external.idle);
    }

    static T? SafeGet<T>(Func<T?> get) where T : class
    {
        try { return get(); } catch (DecisionStore.StoreException) { return null; }
    }

    void Show(List<CleanupSuggestion> found, DockerUsage? usage, long? idle)
    {
        suggestions = found;
        docker = usage;
        DockerIdle = idle;
        Questions = CleanupQuestions.Build(found, usage);
        Stage = StageKind.Review;
    }

    void Clear()
    {
        Questions = [];
        answers = [];
        hints = [];
        queue.Clear();
        suggestions = [];
        docker = null;
        DockerIdle = null;
        freeBefore = null;
        freeNow = null;
        Erased = 0;
        ErasedBytes = 0;
        TrashProblems = [];
        runRecorded = false;
        RaiseAnswers();
    }

    /// <summary>Открытые программы, чьи кеши OffLoadAI умеет удалять: имя процесса → название.</summary>
    static Dictionary<string, string> RunningApplications()
    {
        var watched = CleanupPlanner.RegenerableLocations.SelectMany(l => l.Apps ?? []).ToList();
        var running = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try
                {
                    var name = process.ProcessName;
                    if (running.ContainsKey(name) || !watched.Any(w => name.StartsWith(w, StringComparison.OrdinalIgnoreCase))) continue;
                    running[name] = FriendlyName(process);
                }
                catch (InvalidOperationException) { }
            }
        }
        return running;
    }

    static string FriendlyName(Process process)
    {
        try
        {
            if (process.MainModule?.FileVersionInfo is { } info)
                return info.ProductName is { Length: > 0 } product ? product : info.FileDescription is { Length: > 0 } description ? description : process.ProcessName;
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException) { }
        return process.ProcessName;
    }

    /// <summary>Сколько свободно на системном диске.</summary>
    static async Task<long?> FreeSpace(string home)
    {
        // В демонстрации диск не замеряется: снимок не должен показывать настоящий компьютер.
        if (Demo.IsOn) return null;
        return await Task.Run(() => Volumes.Info(home)?.AvailableBytes);
    }

    // MARK: Вернуть или удалить насовсем

    /// <summary>Возвращает из Корзины на прежние места то, что туда отправил ответ на этот вопрос.
    /// Для вернутого запоминается «оставить»: о нём больше не спрошу.</summary>
    public async void Restore(QuestionKind kind, AppModel app)
    {
        if (AnswerFor(kind).Result is not { } outcome || Finishing != null || outcome.TrashedItems.Count == 0) return;
        Finishing = "Возвращаю из Корзины…";
        var items = outcome.TrashedItems;
        var home = app.Rules.Home;
        var (back, problems) = await Task.Run(() => PutBack(items));
        Record(back.Select(b => new DecisionStore.Decision(b.Original, CleanupAction.Keep, b.Bytes, CleanupAction.Trash)));
        var returned = back.Select(b => b.InTrash).ToHashSet(Paths.Comparer);
        SetAnswer(kind, new Answer(AnswerKind.Done, Result: outcome with
        {
            TrashedItems = outcome.TrashedItems.Where(t => !returned.Contains(t.InTrash)).ToList(),
            Restored = outcome.Restored + back.Count,
            Problems = [.. outcome.Problems, .. problems],
        }));
        freeNow = await FreeSpace(home);
        Finishing = null;
        RaiseAnswers();
        LoadHabits(home);
        app.Space.InvalidateAll();
    }

    /// <summary>Удаляет насовсем из Корзины ровно то, что туда отправил этот разбор: место освобождается сразу.
    /// Остальное в Корзине не трогается.</summary>
    public async void EraseTrashed(AppModel app)
    {
        var items = TrashedItems;
        if (Finishing != null || items.Count == 0) return;
        Finishing = "Удаляю из Корзины…";
        var home = app.Rules.Home;
        var (gone, missing, problems) = await Task.Run(() => Erase(items));
        // Чего в Корзине уже не было, из списка убираем, но в «удалено насовсем» не считаем.
        var erasedPaths = gone.Concat(missing).Select(i => i.InTrash).ToHashSet(Paths.Comparer);
        foreach (var question in Questions)
        {
            if (AnswerFor(question.Kind).Result is not { } outcome) continue;
            SetAnswer(question.Kind, new Answer(AnswerKind.Done, Result: outcome with
            {
                TrashedItems = outcome.TrashedItems.Where(t => !erasedPaths.Contains(t.InTrash)).ToList(),
            }));
        }
        Erased += gone.Count;
        ErasedBytes += gone.Sum(g => g.Bytes);
        TrashProblems = [.. TrashProblems, .. problems];
        freeNow = await FreeSpace(home);
        Finishing = null;
        RaiseAnswers();
    }

    static (List<TrashedItem>, List<string>) PutBack(IReadOnlyList<TrashedItem> items)
    {
        var back = new List<TrashedItem>();
        var problems = new List<string>();
        foreach (var item in items)
        {
            var name = Paths.Name(item.Original);
            if (!FileSystem.Exists(item.InTrash))
            {
                problems.Add($"«{name}»: в Корзине его уже нет.");
                continue;
            }
            if (!item.IsStillInTrash)
            {
                problems.Add($"«{name}»: в Корзине под этим именем теперь другой файл — его не трогаю.");
                continue;
            }
            if (FileSystem.Exists(item.Original))
            {
                problems.Add($"«{name}»: на прежнем месте уже есть файл с таким именем — оставил в Корзине.");
                continue;
            }
            try
            {
                RecycleBin.Restore(item.InTrash, item.Original);
                back.Add(item);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or MoveException or CopyException)
            {
                problems.Add($"«{name}»: {error.Message}");
            }
        }
        return (back, problems);
    }

    static (List<TrashedItem>, List<TrashedItem>, List<string>) Erase(IReadOnlyList<TrashedItem> items)
    {
        var gone = new List<TrashedItem>();
        var missing = new List<TrashedItem>();
        var problems = new List<string>();
        foreach (var item in items)
        {
            var name = Paths.Name(item.Original);
            try
            {
                // Удаляется насовсем, поэтому только то самое, что туда отправил разбор.
                if (!FileSystem.Exists(item.InTrash))
                {
                    missing.Add(item);
                    problems.Add($"«{name}»: в Корзине его уже нет — вернули или Корзину очистили.");
                    continue;
                }
                if (!item.IsStillInTrash)
                {
                    problems.Add($"«{name}»: в Корзине под этим именем теперь другой файл — его не трогаю.");
                    continue;
                }
                RecycleBin.Erase(item.InTrash);
                gone.Add(item);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                problems.Add($"«{name}»: {error.Message}");
            }
        }
        return (gone, missing, problems);
    }

    /// <summary>Остановить поиск.</summary>
    public void Cancel() => scanToken.Cancel();

    /// <summary>К началу: после ответов или чтобы бросить разбор.</summary>
    public void Reset(AppModel app)
    {
        if (IsBusy) return;
        RecordRun(app.Rules.Home);
        Clear();
        Stage = StageKind.Idle;
    }

    static string Phase(CleanupAction action) => action switch
    {
        CleanupAction.Trash => "В Корзину",
        CleanupAction.Safe => "Подготовка",
        CleanupAction.Backup => "В бэкап",
        _ => "",
    };
}

/// <summary>Промежуточный итог поиска: пополняется из параллельных замеров, поэтому под замком.</summary>
sealed class ScanTally
{
    readonly Lock gate = new();
    CleanupModel.ScanProgress progress = new();
    readonly Dictionary<CleanupModule, long> found = [];

    public CleanupModel.ScanProgress Snapshot
    {
        get { lock (gate) return progress with { Found = new Dictionary<CleanupModule, long>(found) }; }
    }

    public CleanupModel.ScanProgress Add(CleanupSuggestion suggestion, Func<CleanupSuggestion, bool> counted)
    {
        lock (gate)
        {
            if (suggestion.Module is { } module && counted(suggestion))
                found[module] = found.GetValueOrDefault(module) + (module == CleanupModule.Projects ? 1 : suggestion.Bytes);
            progress = progress with { Done = progress.Done + 1, Found = new Dictionary<CleanupModule, long>(found) };
            return progress;
        }
    }

    /// <summary>Просмотрено, но человек просил это не предлагать.</summary>
    public CleanupModel.ScanProgress Skip()
    {
        lock (gate)
        {
            progress = progress with { Done = progress.Done + 1 };
            return progress;
        }
    }
}
