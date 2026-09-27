using Offload.Core;
using static Offload.Checks.Harness;

namespace Offload.Checks;

// Привычки: что считается похожим, когда модель берётся решать и когда молчит.
static partial class All
{
    static DecisionFeatures Features(string relative, DecisionKind kind = DecisionKind.Folder, double gb = 20, double? daysAgo = 400) =>
        DecisionFeatures.Of(HomePath(relative), FakeHome, kind, (long)(gb * 1_000_000_000), daysAgo is { } days ? CleanupNow.AddDays(-days) : null, CleanupNow);

    static HabitModel.Example Example(string relative, CleanupAction action, DecisionKind kind = DecisionKind.Folder, double gb = 20, double daysAgo = 400) =>
        new(Features(relative, kind, gb, daysAgo), action);

    static HabitModel Model(params HabitModel.Example[] examples) => new(examples);

    static CleanupObservation Observation(string relative, double gb = 80, double daysAgo = 500, bool directory = true, Verdict? verdict = null) =>
        new(HomePath(relative), (long)(gb * 1_000_000_000), CleanupNow.AddDays(-daysAgo), directory, verdict ?? Verdict.Safe);

    static CleanupPlanner Planner(HabitModel? habits = null) => new() { Now = CleanupNow, Home = FakeHome, Habits = habits };

    static void ChecksHabits()
    {
        Section("Привычки: признаки", () =>
        {
            Check(Features(@"Downloads\film.MKV", DecisionKind.File, 4) == new DecisionFeatures(DecisionKind.File, DecisionCategory.Video, "Downloads",
                                                                                                DecisionSize.Large, DecisionAge.Ancient),
                  "видео в Загрузках: вид, место, размер и давность");
            Check(Features(@"Projects\app", DecisionKind.Project, 0.05, 3) == new DecisionFeatures(DecisionKind.Project, null, "Projects", DecisionSize.Small, DecisionAge.Fresh),
                  "у папок и проектов вида по расширению нет, место — своя папка в домашней");
            Check(Features(@"downloads\x.pdf", DecisionKind.File).Place == "Downloads", "место сравнивается без учёта регистра");
            Check(DecisionFeatures.CategoryOf("scan.PDF") == DecisionCategory.Document && DecisionFeatures.CategoryOf("Setup.MSI") == DecisionCategory.Installer
                  && DecisionFeatures.CategoryOf("IMG_1.HEIC") == DecisionCategory.Image && DecisionFeatures.CategoryOf("notes") == DecisionCategory.Other,
                  "вид файла — по расширению, без учёта регистра");
            var undated = Features(@"Videos\x", daysAgo: null);
            Check(undated.Age == DecisionAge.Unknown && undated.Size == DecisionSize.Huge, "без даты давность неизвестна");
            var old = new DecisionStore.Decision(HomePath(@"Videos\Съёмки"), CleanupAction.Safe, 20_000_000_000, DecidedAt: CleanupNow);
            Check(old.Features(FakeHome).Kind == DecisionKind.Folder && old.Features(FakeHome).Age == DecisionAge.Unknown,
                  "у решений, записанных до привычек, папка угадывается по имени без расширения");
        });

        Section("Привычки: когда модель решает", () =>
        {
            var target = Features(@"Videos\Новая");
            var few = Model(Example(@"Videos\a", CleanupAction.Keep), Example(@"Videos\b", CleanupAction.Keep));
            Check(few.Predict(target, [CleanupAction.Safe, CleanupAction.Keep]) == null, "двух похожих решений мало — решают правила");

            var three = Model(Example(@"Videos\a", CleanupAction.Keep), Example(@"Videos\b", CleanupAction.Keep), Example(@"Videos\c", CleanupAction.Keep));
            var prediction = three.Predict(target, [CleanupAction.Safe, CleanupAction.Backup, CleanupAction.Keep]);
            Check(prediction is { Action: CleanupAction.Keep, Agreeing: 3, Total: 3 }, "три похожие папки из трёх оставили — модель предлагает оставить");
            Check(prediction?.Reason == "Похожее вы обычно оставляете (3 из 3): папки в «Видео» больше 10 ГБ, не менялись больше года.",
                  $"в причине сказано, что сочтено похожим: {prediction?.Reason}");
            Check(three.Predict(target, [CleanupAction.Safe]) == null, "действие, которое для объекта не разрешено, не предлагается");
            Check(three.Predict(Features(@"Downloads\x"), [CleanupAction.Safe, CleanupAction.Keep]) == null, "папки в «Видео» ничего не говорят о «Загрузках»");

            var mixed = Model(Example(@"Videos\a", CleanupAction.Keep), Example(@"Videos\b", CleanupAction.Keep),
                              Example(@"Videos\c", CleanupAction.Safe), Example(@"Videos\d", CleanupAction.Safe));
            Check(mixed.Predict(target, [CleanupAction.Safe, CleanupAction.Keep]) == null, "решения расходятся — модель не гадает");

            var broader = Model(Example(@"Videos\a", CleanupAction.Safe, daysAgo: 100), Example(@"Videos\b", CleanupAction.Safe, daysAgo: 200),
                                Example(@"Videos\c", CleanupAction.Safe, daysAgo: 400));
            Check(broader.Predict(target, [CleanupAction.Safe, CleanupAction.Keep])?.Reason == "Похожее вы обычно убираете в сейф (3 из 3): папки в «Видео» больше 10 ГБ.",
                  "точно похожих мало — берутся похожие без учёта давности");
            // Среди всех папок в «Видео» уверенно «в сейф» (9 из 11), но самые похожие расходятся.
            var strict = new HabitModel(new[] { Example(@"Videos\a", CleanupAction.Keep), Example(@"Videos\b", CleanupAction.Safe), Example(@"Videos\c", CleanupAction.Keep) }
                .Concat(Enumerable.Range(2, 8).Select(i => Example($@"Videos\{i}", CleanupAction.Safe, gb: i))));
            Check(strict.Predict(target, [CleanupAction.Safe, CleanupAction.Keep]) == null, "самые похожие решения расходятся — менее похожие их не перевешивают");

            var list = Model(Example(@"Videos\a", CleanupAction.Safe), Example(@"Videos\b", CleanupAction.Safe), Example(@"Videos\c", CleanupAction.Safe, gb: 2),
                             Example(@"Videos\d", CleanupAction.Safe, gb: 30),
                             Example(@"Downloads\a.msi", CleanupAction.Keep, DecisionKind.File, 0.5), Example(@"Downloads\b.msi", CleanupAction.Keep, DecisionKind.File, 0.3),
                             Example(@"Downloads\c.iso", CleanupAction.Keep, DecisionKind.File, 0.2)).Habits();
            Check(list.Select(h => h.Scope).SequenceEqual(["папки в «Видео»", "образы дисков и установщики в «Загрузках»"])
                  && list.Select(h => h.Action).SequenceEqual([CleanupAction.Safe, CleanupAction.Keep]) && list.First().Agreeing == 4,
                  $"список привычек — по местам и видам, самые подкреплённые сначала: {string.Join("; ", list.Select(h => h.Scope))}");
            Check(Model().IsEmpty && !three.IsEmpty, "пустая модель знает, что пуста");

            var deleting = new HabitModel(Enumerable.Range(1, 4).Select(i => Example($@"Downloads\{i}.msi", CleanupAction.Trash, DecisionKind.File, 0.5)));
            Check(deleting.Predict(Features(@"Downloads\new.msi", DecisionKind.File, 0.5), [CleanupAction.Trash, CleanupAction.Safe, CleanupAction.Keep]) == null
                  && deleting.Habits().Count == 0, "удалить привычка не предлагает никогда, даже если похожее всегда удаляли");
        });

        Section("Привычки: в предложениях", () =>
        {
            var keeping = Model(Example(@"Videos\a", CleanupAction.Keep), Example(@"Videos\b", CleanupAction.Keep), Example(@"Videos\c", CleanupAction.Keep));
            var planner = Planner(keeping);
            var item = Observation(@"Videos\Съёмки 2019");
            var suggestion = planner.Suggest(item);
            Check(suggestion.Action == CleanupAction.Keep && suggestion.Habit && !suggestion.Learned,
                  "правило советует сейф, но похожее вы оставляете — предлагается оставить, с пометкой");
            Check(suggestion.Module == CleanupModule.Safe && !suggestion.Preselected, "оставленное по привычке видно в плитке сейфа неотмеченным — с объяснением, почему");
            Check(suggestion.Kind == DecisionKind.Folder
                  && planner.Suggest(new CleanupObservation(HomePath(@"Projects\app"), 1, null, true, Verdict.Safe, IsProject: true)).Kind == DecisionKind.Project,
                  "вид объекта идёт в предложение, чтобы записаться с решением");

            var remembering = With(planner, memory: Remember((@"Videos\Съёмки 2019", CleanupAction.Safe)));
            Check(remembering.Suggest(item).Action == CleanupAction.Safe && remembering.Suggest(item).Learned, "решение по этой самой папке важнее привычки");

            var agreeing = Planner(Model(Example(@"Videos\a", CleanupAction.Safe), Example(@"Videos\b", CleanupAction.Safe), Example(@"Videos\c", CleanupAction.Safe)));
            var same = agreeing.Suggest(item);
            Check(same.Action == CleanupAction.Safe && same.Habit && same.Preselected && same.Reason.StartsWith("Похожее вы обычно убираете в сейф"),
                  "правило сейф только предлагает, а вы похожее обычно туда и убираете — отмечено сразу, по привычке");
            var projects = Planner(new HabitModel(Enumerable.Range(1, 3).Select(i => Example($@"Projects\{i}", CleanupAction.Backup, DecisionKind.Project))));
            var project = projects.Suggest(new CleanupObservation(HomePath(@"Projects\app"), 2_000_000_000, CleanupNow.AddDays(-200), true, Verdict.Safe, IsProject: true));
            Check(project.Action == CleanupAction.Backup && !project.Habit && project.Preselected, "привычка совпала с правилом, которое и так отмечает сразу, — объясняет правило");

            var blocked = planner.Suggest(Observation(@"Videos\Проект.lrdata", verdict: Verdict.Blocked("пакет")));
            Check(blocked.Action == CleanupAction.Keep && !blocked.Habit && blocked.Allowed.SequenceEqual([CleanupAction.Keep]), "запрещённое остаётся запрещённым");

            var trashing = Planner(Model(Example(@"Downloads\a.mkv", CleanupAction.Trash, DecisionKind.File, 4), Example(@"Downloads\b.mkv", CleanupAction.Trash, DecisionKind.File, 4),
                                         Example(@"Downloads\c.mkv", CleanupAction.Trash, DecisionKind.File, 4)));
            var video = trashing.Suggest(Observation(@"Downloads\film.mkv", 4, 400, directory: false));
            Check(video.Action != CleanupAction.Trash && !video.Allowed.Contains(CleanupAction.Trash),
                  "даже если похожее вы удаляли, личный файл в Корзину не предлагается: удалять разрешают только правила");

            var installers = Planner(new HabitModel(Enumerable.Range(1, 3).Select(i => Example($@"Downloads\{i}.msi", CleanupAction.Trash, DecisionKind.File, 0.5, 60))));
            var installer = installers.Suggest(Observation(@"Downloads\Figma.msi", 0.5, 60, directory: false));
            Check(installer.Action == CleanupAction.Keep && !installer.Habit && installer.Allowed.Contains(CleanupAction.Trash),
                  "установщик удаляете вы сами: сколько бы похожих ни удаляли, привычка его в Корзину не предлагает");

            var copy = CleanupSuggestion.Make(HomePath(@"Downloads\a.pdf"), 1, null, false, CleanupAction.Trash, "", [CleanupAction.Trash, CleanupAction.Keep], false, [],
                                              duplicateGroup: "h");
            Check(copy.Kind == DecisionKind.Copy, "копия одинакового файла записывается как копия");
        });

        Section("Привычки: одинаковые файлы", () =>
        {
            DuplicateCopy Copy(string relative) => new(HomePath(relative), 5_000_000, CleanupNow.AddDays(-400), CleanupNow.AddDays(-400));
            CleanupPlanner For(CleanupAction action, string place) =>
                Planner(new HabitModel(Enumerable.Range(1, 3).Select(i => Example($@"{place}\{i}.pdf", action, DecisionKind.Copy, 0.005))));
            var keeping = For(CleanupAction.Keep, "Downloads").Suggestions([], [new DuplicateGroup("g", 5_000_000, [Copy(@"Documents\a.pdf"), Copy(@"Downloads\a.pdf")])]);
            Check(keeping.Select(s => s.Action).SequenceEqual([CleanupAction.Keep, CleanupAction.Keep]) && keeping.Select(s => s.Habit).SequenceEqual([false, true]),
                  "лишнюю копию там, где копии вы оставляете, привычка предлагает оставить");
            Check(keeping[^1].Reason == "Похожее вы обычно оставляете (3 из 3): копии документов в «Загрузках» меньше 100 МБ, не менялись больше года.",
                  $"у копий в причине назван вид файла: {keeping[^1].Reason}");
            var trashing = For(CleanupAction.Trash, "Documents").Suggestions([], [new DuplicateGroup("g", 5_000_000, [Copy(@"Documents\a.pdf"), Copy(@"Documents\Старое\a.pdf")])]);
            Check(trashing.Select(s => s.Action).SequenceEqual([CleanupAction.Keep, CleanupAction.Trash]) && !trashing.Any(s => s.Habit),
                  "привычка удалять копии не трогает ту, что остаётся, и удалений не добавляет");
            var remembered = With(For(CleanupAction.Keep, "Downloads"), memory: Remember((@"Downloads\a.pdf", CleanupAction.Trash)))
                .Suggestions([], [new DuplicateGroup("g", 5_000_000, [Copy(@"Documents\a.pdf"), Copy(@"Downloads\a.pdf")])]);
            Check(remembered[^1].Action == CleanupAction.Trash && remembered[^1].Learned && !remembered[^1].Habit, "решение по этой самой копии важнее привычки");
        });

        Section("Привычки: что считается выбором", () =>
        {
            DecisionStore.Decision Decision(CleanupAction action, CleanupAction? suggested, string relative = @"Videos\a") =>
                new(HomePath(relative), action, 20_000_000_000, suggested, DecisionKind.Folder, CleanupNow.AddDays(-400), CleanupNow);
            Check(Decision(CleanupAction.Keep, CleanupAction.Safe).IsChoice && Decision(CleanupAction.Safe, CleanupAction.Safe).IsChoice
                  && Decision(CleanupAction.Trash, null).IsChoice, "выбор — поменять предложенное или согласиться что-то сделать");
            Check(!Decision(CleanupAction.Keep, CleanupAction.Keep).IsChoice && !Decision(CleanupAction.Keep, null).IsChoice,
                  "«оставить», когда оставить и предлагалось (или неизвестно, что предлагалось), — не выбор");
            var passive = new HabitModel(Enumerable.Range(1, 5).Select(i => Decision(CleanupAction.Keep, CleanupAction.Keep, $@"Videos\{i}")), FakeHome);
            Check(passive.IsEmpty && passive.Count == 0, "на согласии по умолчанию модель не учится");
            var active = new HabitModel(Enumerable.Range(1, 3).Select(i => Decision(CleanupAction.Keep, CleanupAction.Safe, $@"Videos\{i}")), FakeHome);
            Check(active.Count == 3 && active.Predict(Features(@"Videos\Новая"), [CleanupAction.Safe, CleanupAction.Keep])?.Action == CleanupAction.Keep,
                  "на том, что вы поменяли, — учится");
        });
    }
}
