using Offload.Core;
using static Offload.Checks.Harness;
using static Offload.Checks.Helpers;

namespace Offload.Checks;

// Разбор одной кнопкой: что предлагается, что отмечено сразу, что запоминается и какие вопросы задаются.
static partial class All
{
    static readonly DateTime CleanupNow = DateTime.UnixEpoch.AddSeconds(2_000_000_000);
    const string FakeHome = @"C:\Users\q";

    static string HomePath(string relative) => Path.Combine(FakeHome, relative);

    static CleanupObservation Item(string relative, double gb, double? daysAgo, bool directory = true, Verdict? verdict = null,
                                   bool project = false, bool inBackup = false) =>
        new(HomePath(relative), (long)(gb * 1_000_000_000), daysAgo is { } days ? CleanupNow.AddDays(-days) : null, directory,
            verdict ?? Verdict.Safe, project, inBackup);


    static CleanupPlanner With(CleanupPlanner p, IReadOnlyDictionary<string, CleanupAction>? memory = null, IReadOnlyDictionary<string, string>? busy = null,
                               IReadOnlySet<string>? ignored = null, HabitModel? habits = null) =>
        new()
        {
            Now = p.Now, Home = p.Home, Regenerable = p.Regenerable, Memory = memory ?? p.Memory, Busy = busy ?? p.Busy,
            Ignored = ignored ?? p.Ignored, Habits = habits ?? p.Habits,
        };

    static Dictionary<string, CleanupAction> Remember(params (string relative, CleanupAction action)[] items)
    {
        var result = new Dictionary<string, CleanupAction>(Paths.Comparer);
        foreach (var (relative, action) in items) result[relative.Length > 1 && relative[1] == ':' ? relative : HomePath(relative)] = action;
        return result;
    }

    static void ChecksCleanup()
    {
        Section("Разбор: предложения", () =>
        {
            var appData = Verdict.Blocked("Данные программ");
            var npm = HomePath(@"AppData\Local\npm-cache\_cacache");
            var planner = new CleanupPlanner
            {
                Now = CleanupNow, Home = FakeHome,
                Regenerable = new Dictionary<string, string>(Paths.Comparer) { [npm] = "Кеш npm — пакеты скачаются снова." },
            };

            var cache = planner.Suggest(Item(@"AppData\Local\npm-cache\_cacache", 20, 1, verdict: appData));
            Check(cache.Action == CleanupAction.Trash, "кеш npm предлагается в Корзину, хотя AppData переносить нельзя");
            Check(cache.Allowed.SequenceEqual([CleanupAction.Trash, CleanupAction.Keep]), "кеш можно только удалить или оставить — ни в сейф, ни в бэкап");
            Check(planner.Suggest(Item(@"AppData\Local\NPM-CACHE\_cacache", 20, 1, verdict: appData)).Action == CleanupAction.Trash,
                  "восстанавливаемое место узнаётся без учёта регистра");

            var installer = planner.Suggest(Item(@"Downloads\Figma.msi", 0.3, 20, directory: false));
            Check(installer.Action == CleanupAction.Keep && installer.Allowed.Contains(CleanupAction.Trash),
                  "старый установщик сам в Корзину не предлагается, но выбрать её можно");
            var exe = planner.Suggest(Item(@"Downloads\setup.exe", 0.3, 20, directory: false));
            Check(exe.Allowed.Contains(CleanupAction.Trash), ".exe в Загрузках — установщик");
            var tool = planner.Suggest(Item(@"Tools\portable.exe", 0.3, 20, directory: false));
            Check(!tool.Allowed.Contains(CleanupAction.Trash), ".exe вне Загрузок и Рабочего стола — программа без установки, не установщик");
            var encrypted = planner.Suggest(new CleanupObservation(HomePath(@"Downloads\Документы.vhdx"), 2_000_000_000, CleanupNow.AddDays(-400), false,
                                                                   Verdict.Safe, IsEncryptedImage: true));
            Check(!encrypted.Allowed.Contains(CleanupAction.Trash), "зашифрованный образ — личные данные: удалить из разбора нельзя");
            Check(encrypted.Action == CleanupAction.Safe, "большой старый зашифрованный образ — в сейф, как любой личный файл");
            var iso = planner.Suggest(Item(@"Downloads\ubuntu.iso", 5, 20, directory: false));
            Check(!iso.Allowed.Contains(CleanupAction.Trash), ".iso не установщик: к нему бывает подключена виртуальная машина");
            var learnedTrash = With(planner, memory: Remember((@"Downloads\Figma.msi", CleanupAction.Trash)))
                .Suggest(Item(@"Downloads\Figma.msi", 0.3, 20, directory: false));
            Check(learnedTrash.Action == CleanupAction.Trash && learnedTrash.Learned, "если в прошлый раз установщик удалили — предлагается то же");
            var fresh = planner.Suggest(Item(@"Downloads\Figma.msi", 0.3, 2, directory: false));
            Check(!fresh.Allowed.Contains(CleanupAction.Trash), "установщик, скачанный на днях, удалить не предлагается: его могли ещё не поставить");
            var serverDated = planner.Suggest(new CleanupObservation(HomePath(@"Downloads\Tool.msi"), 300_000_000, CleanupNow.AddDays(-300), false,
                                                                     Verdict.Safe, Added: CleanupNow.AddDays(-1)));
            Check(!serverDated.Allowed.Contains(CleanupAction.Trash), "установщик с датой сервера, появившийся в папке вчера, старым не считается");
            var video = planner.Suggest(Item(@"Downloads\film.mkv", 3, 400, directory: false));
            Check(!video.Allowed.Contains(CleanupAction.Trash), "личный файл удалить нельзя вовсе — только в сейф или оставить");
            Check(video.Action == CleanupAction.Safe, "большой и давно не менявшийся файл — в сейф");

            var old = planner.Suggest(Item(@"Videos\Съёмки 2019", 80, 500));
            Check(old.Action == CleanupAction.Safe && old.Allowed.Contains(CleanupAction.Backup), "большая старая папка — в сейф, бэкап тоже можно выбрать");
            Check(planner.Suggest(Item(@"Videos\Монтаж", 80, 3)).Action == CleanupAction.Keep, "папка, которую меняли на днях, остаётся на месте");
            Check(planner.Suggest(Item(@"Projects\app", 2, 200, project: true)).Action == CleanupAction.Backup, "проект с git предлагается в бэкап, а не в сейф");
            Check(!planner.Suggest(Item(@"Projects\app", 2, 200, project: true, inBackup: true)).Allowed.Contains(CleanupAction.Backup),
                  "то, что уже в бэкапе, второй раз туда не предлагается");
            var library = planner.Suggest(Item(@"Pictures\Lightroom\Catalog.lrcat", 60, 500, verdict: Verdict.Blocked("медиатека")));
            Check(library.Action == CleanupAction.Keep && library.Allowed.SequenceEqual([CleanupAction.Keep]) && library.Reason == "медиатека",
                  "каталог Lightroom нельзя ни удалить, ни перенести — и сказано почему");
            var caution = planner.Suggest(Item(@"Projects\old", 5, 400, verdict: Verdict.Caution("оговорка")));
            Check(caution.Action == CleanupAction.Keep && caution.Allowed.Contains(CleanupAction.Safe) && caution.Cautions.SequenceEqual(["оговорка"]),
                  "с оговорками — само не предлагается, но выбрать можно, и оговорка видна");

            var learning = With(planner, memory: Remember((@"Videos\Съёмки 2019", CleanupAction.Keep), (@"Videos\Монтаж", CleanupAction.Trash)));
            var remembered = learning.Suggest(Item(@"Videos\Съёмки 2019", 80, 500));
            Check(remembered.Action == CleanupAction.Keep && remembered.Learned, "прошлое решение «оставить» побеждает правило");
            var impossible = learning.Suggest(Item(@"Videos\Монтаж", 80, 3));
            Check(impossible.Action == CleanupAction.Keep && !impossible.Learned, "прошлое решение, которое теперь недопустимо (удалить личную папку), не применяется");
            Check(With(planner, memory: Remember((@"videos\съёмки 2019", CleanupAction.Keep)))
                  .Suggest(Item(@"Videos\Съёмки 2019", 80, 500)).Learned, "прошлое решение находится без учёта регистра пути");

            var list = planner.Suggestions([
                Item(@"Downloads\small", 0.01, 500),
                Item(@"Videos\Съёмки 2019", 80, 500),
                Item(@"AppData\Local\npm-cache\_cacache", 2, 1, verdict: appData),
                Item(@"Videos\Монтаж", 90, 3),
            ]);
            Check(list.Select(s => s.Action).SequenceEqual([CleanupAction.Trash, CleanupAction.Safe])
                  && list.Select(s => s.Module).SequenceEqual(new CleanupModule?[] { CleanupModule.Junk, CleanupModule.Safe }),
                  "сначала мусор, потом сейф; мелочь и то, что трогать незачем, в итоги не попадают");
        });

        Section("Разбор: плитки и что отмечено сразу", () =>
        {
            var appData = Verdict.Blocked("Данные программ");
            var npm = HomePath(@"AppData\Local\npm-cache\_cacache");
            var code = HomePath(@"AppData\Roaming\Code\Cache");
            var planner = new CleanupPlanner
            {
                Now = CleanupNow, Home = FakeHome,
                Regenerable = new Dictionary<string, string>(Paths.Comparer) { [npm] = "кеш npm", [code] = "кеш VS Code" },
            };
            var cache = planner.Suggest(Item(@"AppData\Local\npm-cache\_cacache", 5, 1, verdict: appData));
            Check(cache.Module == CleanupModule.Junk && cache.Preselected && cache.DefaultChoice == CleanupAction.Trash,
                  "мусор — плитка «Мусор», отмечен сразу: программы создадут его заново");
            var film = planner.Suggest(Item(@"Videos\Съёмки 2019", 80, 500));
            Check(film.Module == CleanupModule.Safe && film.Action == CleanupAction.Safe && !film.Preselected && film.DefaultChoice == CleanupAction.Keep,
                  "крупное и старое — в плитке сейфа, но само не отмечается: личное решаете вы");
            var project = planner.Suggest(Item(@"Projects\app", 2, 200, project: true));
            Check(project.Module == CleanupModule.Projects && project.Preselected, "проект без бэкапа отмечен сразу: добавление в бэкап ничего не удаляет");
            var installer = planner.Suggest(Item(@"Downloads\Figma.msi", 0.3, 20, directory: false));
            Check(installer.Module == CleanupModule.Installers && !installer.Preselected && installer.DefaultChoice == CleanupAction.Keep,
                  "старый установщик — в своей плитке, неотмеченным");
            Check(planner.Suggest(Item(@"Videos\Монтаж", 80, 3)).Module == null, "то, чем пользуются, ни в какую плитку не попадает");

            var remembering = With(planner, memory: Remember((@"Videos\Съёмки 2019", CleanupAction.Safe), (@"Downloads\Figma.msi", CleanupAction.Trash),
                                                             (@"Projects\app", CleanupAction.Keep)));
            Check(remembering.Suggest(Item(@"Videos\Съёмки 2019", 80, 500)).Preselected, "в прошлый раз вы убрали это в сейф — теперь отмечено сразу");
            Check(remembering.Suggest(Item(@"Downloads\Figma.msi", 0.3, 20, directory: false)).Preselected, "установщик, который вы удаляли в прошлый раз, отмечен");
            var keptProject = remembering.Suggest(Item(@"Projects\app", 2, 200, project: true));
            Check(keptProject.Module == CleanupModule.Projects && !keptProject.Preselected && keptProject.Learned,
                  "проект, который вы в прошлый раз не стали добавлять, остаётся в своей плитке неотмеченным");

            var busy = With(planner, memory: Remember((code, CleanupAction.Trash)),
                            busy: CleanupPlanner.BusyIn(FakeHome, new Dictionary<string, string> { ["Code"] = "Visual Studio Code", ["explorer"] = "Проводник" }));
            var open = busy.Suggest(Item(@"AppData\Roaming\Code\Cache", 1, 1, verdict: appData));
            Check(open.Module == CleanupModule.Junk && !open.Preselected && open.Allowed.Contains(CleanupAction.Trash) && open.Reason.Contains("Visual Studio Code"),
                  "кеш открытой программы не отмечается, даже если его удаляли в прошлый раз, — и сказано почему");
            Check(busy.Suggest(Item(@"AppData\Local\npm-cache\_cacache", 5, 1, verdict: appData)).Preselected, "кеши закрытых программ отмечены как обычно");
            Check(CleanupPlanner.BusyIn(FakeHome, new Dictionary<string, string>()).Count == 0, "ничего не открыто — ничего не занято");

            var ignoring = With(planner, ignored: new HashSet<string>(Paths.Comparer) { HomePath("Videos"), code });
            var visible = ignoring.Suggestions([Item(@"Videos\Съёмки 2019", 80, 500), Item(@"AppData\Roaming\Code\Cache", 1, 1, verdict: appData),
                                                Item(@"Documents\Архив", 20, 500)]);
            Check(visible.Select(s => s.Id[(FakeHome.Length + 1)..]).SequenceEqual([@"Documents\Архив"]),
                  "то, что вы просили не предлагать, — и всё внутри такой папки — в итоги не попадает");
            Check(ignoring.IsIgnored(HomePath(@"Videos\a\b.mov")) && !ignoring.IsIgnored(HomePath("Videosx")) && ignoring.IsIgnored(HomePath(@"VIDEOS\c.mov")),
                  "не предлагать папку — значит и всё внутри неё (без учёта регистра), но не соседей с похожим именем");

            var fake = Room("home-regenerable");
            const string ide = @"AppData\Local\JetBrains\IntelliJIdea2025.2";
            const string chrome = @"AppData\Local\Google\Chrome\User Data";
            foreach (var relative in new[] { @".gradle\caches", chrome + @"\Default\Cache", chrome + @"\Default\Code Cache", chrome + @"\Default\Sessions",
                                             ide + @"\caches", ide + @"\index", ide + @"\LocalHistory" })
                Directory.CreateDirectory(Path.Combine(fake, relative));
            Write("{}", Path.Combine(fake, chrome + @"\Default\Bookmarks"));
            string[] jetbrains = [ide + @"\caches", ide + @"\index"];
            string[] chromeCaches = [chrome + @"\Default\Cache", chrome + @"\Default\Code Cache"];
            var found = CleanupPlanner.RegenerableIn(fake).Keys.ToHashSet(Paths.Comparer);
            Check(found.SetEquals(new[] { @".gradle\caches" }.Concat(chromeCaches).Concat(jetbrains).Select(r => Path.Combine(fake, r))),
                  $"кеши Gradle, Chrome и JetBrains находятся, если они есть ({found.Count})");
            Check(!found.Any(k => k.Contains("LocalHistory") || k.Contains("Bookmarks") || k.Contains("Sessions")),
                  "локальная история JetBrains и закладки и сессии Chrome в мусор не попадают — только кеши");
            var busyJetBrains = CleanupPlanner.BusyIn(fake, new Dictionary<string, string> { ["idea64"] = "IntelliJ IDEA" });
            Check(busyJetBrains.Keys.ToHashSet(Paths.Comparer).SetEquals(jetbrains.Select(r => Path.Combine(fake, r))),
                  "любая среда JetBrains держит кеши JetBrains, и только их");
            // Ссылка на месте кеша: удалять по ней нельзя — она ведёт неизвестно куда.
            Junction(Path.Combine(fake, @"AppData\Local\go-build"), Room("real-go-build"));
            Check(!CleanupPlanner.RegenerableIn(fake).ContainsKey(Path.Combine(fake, @"AppData\Local\go-build")), "точка соединения на месте кеша мусором не считается");

            // Где искать: стандартные папки и свои папки в домашней, без скрытых, облачных, AppData и ссылок.
            foreach (var name in new[] { "Downloads", "Documents", "Projects", ".cache", "OneDrive", "AppData", "iCloudDrive" })
                Directory.CreateDirectory(Path.Combine(fake, name));
            Junction(Path.Combine(fake, "Linked"), Room("linked-elsewhere"));
            Directory.CreateDirectory(Path.Combine(fake, "Скрытая"));
            Add(Path.Combine(fake, "Скрытая"), FileAttributes.Hidden);
            var roots = CleanupPlanner.Roots(fake).Select(Paths.Name).ToList();
            Check(roots.Contains("Downloads") && roots.Contains("Documents") && roots.Contains("Projects"), $"стандартные и свои папки разбираются: {string.Join(", ", roots)}");
            Check(!roots.Any(r => r is ".cache" or "OneDrive" or "AppData" or "iCloudDrive" or "Linked" or "Скрытая" or "Desktop"),
                  "скрытые, облачные, AppData, ссылки и несуществующие папки не разбираются");
        });

        Section("Разбор: вопросы вместо флажков", () =>
        {
            var appData = Verdict.Blocked("Данные программ");
            var npm = HomePath(@"AppData\Local\npm-cache\_cacache");
            var code = HomePath(@"AppData\Roaming\Code\Cache");
            DuplicateCopy Copy(string relative, double daysAgo)
            {
                var date = CleanupNow.AddDays(-daysAgo);
                return new DuplicateCopy(HomePath(relative), 2_000_000_000, date, date);
            }
            var planner = new CleanupPlanner
            {
                Now = CleanupNow, Home = FakeHome,
                Regenerable = new Dictionary<string, string>(Paths.Comparer)
                {
                    [npm] = CleanupPlanner.RegenerableLocations[0].Reason, [code] = "Кеш VS Code — пересоздаётся сам.",
                },
                Memory = Remember((@"Downloads\Старый.msi", CleanupAction.Keep)),
                Busy = CleanupPlanner.BusyIn(FakeHome, new Dictionary<string, string> { ["Code"] = "Visual Studio Code" }),
            };
            var suggestions = planner.Suggestions([
                Item(@"AppData\Local\npm-cache\_cacache", 20, 1, verdict: appData),
                Item(@"AppData\Roaming\Code\Cache", 2, 0, verdict: appData),
                Item(@"Downloads\Figma.msi", 0.3, 20, directory: false),
                Item(@"Downloads\Старый.msi", 0.5, 60, directory: false),
                Item(@"Videos\Съёмки 2019", 80, 500),
                Item(@"Videos\Монтаж", 90, 3),
                Item(@"Projects\app", 2, 200, project: true),
            ], [
                new DuplicateGroup("video", 2_000_000_000, [Copy(@"Videos\Отпуск.mov", 300), Copy(@"Downloads\Отпуск.mov", 40), Copy(@"Desktop\Отпуск (1).mov", 12)]),
                // Лишняя копия внутри папки, которую можно убрать в сейф, едет вместе с папкой.
                new DuplicateGroup("inside", 2_000_000_000, [Copy(@"Documents\Отчёт.pdf", 600), Copy(@"Videos\Съёмки 2019\Отчёт.pdf", 500)]),
            ]);
            var docker = new DockerUsage(new(20, 3, 12_000_000_000, 10_200_000_000), new(5, 1, 1_200_000, 1_100_000),
                                         new(12, 4, 31_000_000_000, 20_000_000_000), new(120, 0, 5_600_000_000, 5_600_000_000));
            var questions = CleanupQuestions.Build(suggestions, docker);
            CleanupQuestion? Q(QuestionKind kind) => questions.FirstOrDefault(q => q.Kind == kind);
            List<string> Names(QuestionKind kind) => Q(kind)?.Items.Select(i => i.Name).ToList() ?? [];
            var junkKind = QuestionKind.Of(CleanupModule.Junk);

            Check(questions.Select(q => q.Kind).SequenceEqual([junkKind, QuestionKind.Docker, QuestionKind.Of(CleanupModule.Duplicates),
                                                             QuestionKind.Of(CleanupModule.Installers), QuestionKind.Of(CleanupModule.Safe),
                                                             QuestionKind.Of(CleanupModule.Projects)]),
                  $"порядок: сначала то, что пересоздаётся само, потом личное; виртуальных машин среди вопросов нет: {string.Join(", ", questions.Select(q => q.Kind))}");
            var junk = Q(junkKind);
            Check(Names(junkKind).SequenceEqual(["_cacache"]) && junk?.Bytes == 20_000_000_000, "в вопросе о мусоре — только то, что можно удалить сейчас");
            Check(junk?.Notes.Any(n => n.Contains("Visual Studio Code")) == true, "кеш открытой программы в вопрос не входит, и сказано почему");
            Check(junk?.Labels.SequenceEqual(["Кеш npm"]) == true, $"мусор назван по-человечески, а не именем папки: {string.Join(", ", junk?.Labels ?? [])}");

            var dockerQuestion = Q(QuestionKind.Docker);
            Check(dockerQuestion != null && dockerQuestion.Docker.Count == 2 && dockerQuestion.Docker[DockerPruneTarget.BuildCache] == 5_600_000_000
                  && dockerQuestion.Docker[DockerPruneTarget.DanglingImages] == 0 && dockerQuestion.Bytes == 5_600_000_000,
                  "Docker: кеш сборки и образы без имени");
            Check(dockerQuestion?.Docker.ContainsKey(DockerPruneTarget.Images) == false, "все неиспользуемые образы (--all) в вопрос не входят: собранный вами образ не скачать");
            Check(dockerQuestion?.Docker.ContainsKey(DockerPruneTarget.Containers) == false, "остановленные контейнеры в вопрос о Docker не входят: в них бывают данные");
            Check(!CleanupQuestions.Build([], new DockerUsage(BuildCache: new(1, 0, 50_000_000, 50_000_000))).Any(q => q.Kind == QuestionKind.Docker),
                  "о Docker, который отдаст меньше 100 МБ, не спрашиваю");

            var duplicatesKind = QuestionKind.Of(CleanupModule.Duplicates);
            var duplicates = Q(duplicatesKind);
            Check(Names(duplicatesKind).Order().SequenceEqual(new[] { "Отпуск (1).mov", "Отпуск.mov" }.Order())
                  && duplicates!.Items.All(i => !Paths.IsInside(i.Path, HomePath("Videos"))),
                  "лишние копии — те, что в Загрузках и на Рабочем столе; копия на своём месте остаётся");
            Check(duplicates?.Keepers.Select(k => k.Path).SequenceEqual([HomePath(@"Videos\Отпуск.mov")]) == true, "с чем сверять перед удалением — копия, которая остаётся");
            Check(duplicates?.Items.Any(i => Paths.IsInside(i.Path, HomePath(@"Videos\Съёмки 2019"))) == false,
                  "копия внутри папки, которую можно убрать в сейф, в вопрос о копиях не входит — поедет вместе с папкой");
            Check(duplicates?.Bytes == 4_000_000_000, "освободится ровно столько, сколько занимают лишние копии");

            Check(Names(QuestionKind.Of(CleanupModule.Installers)).SequenceEqual(["Figma.msi"]), "старый установщик — в вопросе, а тот, что вы вернули из Корзины, — нет");
            Check(Names(QuestionKind.Of(CleanupModule.Safe)).SequenceEqual(["Съёмки 2019"]), "в сейф — большое и давно не менявшееся; то, что меняли на днях, не спрашиваю");
            Check(Names(QuestionKind.Of(CleanupModule.Projects)).SequenceEqual(["app"]) && Q(QuestionKind.Of(CleanupModule.Projects))?.Bytes == 0,
                  "проекты — в бэкап; места на компьютере это не освобождает");
            Check(!questions.Any(q => q.Items.Any(i => i.Name == "Монтаж")), "то, что трогать незачем, ни в один вопрос не попадает");
            Check(questions.Where(q => !q.AnsweredTogether).Select(q => q.Kind).SequenceEqual([QuestionKind.Of(CleanupModule.Installers)]),
                  "«Разрешить всё» не удаляет установщики: только отдельным «да» на их вопрос");
            Check(questions.All(q => q.Kind == QuestionKind.Of(CleanupModule.Projects) || q.Bytes > 0), "в каждом вопросе, кроме бэкапа, есть что освободить");
            Check(CleanupQuestions.Build([]).Count == 0, "нечего спрашивать — нет и вопросов");
        });
    }
}
