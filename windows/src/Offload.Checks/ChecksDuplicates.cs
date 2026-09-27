using Offload.Core;
using static Offload.Checks.Harness;
using static Offload.Checks.Helpers;

namespace Offload.Checks;

// Поиск одинаковых файлов: что считается копией, какая остаётся и что сверяется перед удалением.
static partial class All
{
    static void ChecksDuplicates()
    {
        Section("Дубликаты: поиск", () =>
        {
            var rules = new SafetyRules(Room("dup-home"));
            var home = rules.Home;
            string At(string relative) => Path.Combine(home, relative);
            void Put(byte[] data, string relative)
            {
                Directory.CreateDirectory(Paths.Parent(At(relative)));
                File.WriteAllBytes(At(relative), data);
            }
            static byte[] Bytes(int count, byte seed) => Enumerable.Range(0, count).Select(i => (byte)(i * 31 + seed)).ToArray();

            const int size = 300_000;
            var photo = Bytes(size, 1);
            Put(photo, @"Downloads\photo.jpg");
            Put(photo, @"Pictures\2019\photo.jpg");
            Put(photo, @"Desktop\photo (1).jpg");
            // Тот же размер и те же края, другая середина: отличить может только полное сравнение.
            var middle = (byte[])photo.Clone();
            middle[size / 2] ^= 0xFF;
            Put(middle, @"Documents\almost.jpg");
            HardLink(At(@"Downloads\photo.jpg"), At(@"Documents\hardlink.jpg"));
            if (CanSymlink) FileLink(At(@"Documents\link.jpg"), At(@"Downloads\photo.jpg"));
            Junction(At(@"Documents\junction"), At("Pictures"));
            Put(photo, @"Documents\.hidden\photo.jpg");
            Put(photo, @"Documents\Скрытая\photo.jpg");
            Add(At(@"Documents\Скрытая"), FileAttributes.Hidden);
            Put(photo, @"Projects\app\assets\photo.jpg");
            Directory.CreateDirectory(At(@"Projects\app\.git"));
            Put(photo, @"Projects\site\node_modules\pkg\photo.jpg");
            Put(photo, @"Downloads\Machine.vmwarevm\photo.jpg");
            Put(photo, @"Documents\env\Lib\site-packages\photo.jpg");
            Put(photo, @"Documents\conda\photo.jpg");
            Directory.CreateDirectory(At(@"Documents\conda\conda-meta"));
            Put(Bytes(1_000, 2), @"Downloads\small.txt");
            Put(Bytes(1_000, 2), @"Documents\small.txt");

            var finder = new DuplicateFinder { MinimumBytes = 100_000, EdgeBytes = 4_096, EncryptedImage = _ => false };
            string[] roots = [At("Downloads"), At("Desktop"), At("Documents"), At("Pictures"), At("Projects")];
            var first = finder.Find(roots, rules);
            Check(first.Completed, "поиск закончен");
            Check(first.Groups.Count == 1, $"одна группа: копии фото; почти такие же и мелкие файлы — не дубликаты ({first.Groups.Count})");
            var found = first.Groups.FirstOrDefault()?.Copies.Select(c => c.Path[(home.Length + 1)..]).ToList() ?? [];
            Check(found.SequenceEqual([@"Desktop\photo (1).jpg", @"Downloads\photo.jpg", @"Pictures\2019\photo.jpg"]),
                  $"копии фото — в Загрузках, на Рабочем столе и в Изображениях; скрытые папки, git-проекты, node_modules, пакеты машин, окружения Python, ссылки и второе имя того же файла копиями не считаются: {string.Join(", ", found)}");
            Check(first.Groups.FirstOrDefault()?.Bytes == size, "у группы размер одной копии");
            Check(first.Groups.FirstOrDefault() is { } g && DuplicateFinder.Savings(g) == g.Copies.Select(c => c.Allocated).Order().SkipLast(1).Sum(),
                  "освободится всё, кроме одной копии");
            Check(first.Groups.FirstOrDefault()?.Copies.All(c => c.Verdict == Verdict.Safe) == true, "у каждой копии решение правил по пути");
            Check(first.ReadBytes > 0, "в первый раз файлы читаются");

            var known = first.Fingerprints.ToDictionary(f => f.Path, Paths.Comparer);
            var second = finder.Find(roots, rules, known);
            Check(second.Groups.Select(x => x.Id).SequenceEqual(first.Groups.Select(x => x.Id)), "с отпечатками находится то же самое");
            Check(second.ReadBytes == 0, "неизменившиеся файлы второй раз не читаются");

            // Файл поменяли, размер тот же: отпечаток больше не годится.
            Put(Bytes(size, 9), @"Desktop\photo (1).jpg");
            File.SetLastWriteTimeUtc(At(@"Desktop\photo (1).jpg"), DateTime.UtcNow.AddHours(-1));
            var third = finder.Find(roots, rules, known);
            Check(third.Groups.FirstOrDefault()?.Copies.Count == 2, "изменившийся файл перечитан и из группы выпал");
            Check(third.ReadBytes > 0 && third.ReadBytes < first.ReadBytes, "перечитан только он");

            // Зашифрован ли образ, спрашивается только у .vhdx: у остальных файлов вопрос не задаётся.
            Put(Bytes(200_000, 5), @"Images\vault.vhdx");
            Put(Bytes(200_000, 5), @"Images\Старое\vault.vhdx");
            Put(Bytes(200_000, 6), @"Images\notes.bin");
            Put(Bytes(200_000, 6), @"Images\Старое\notes.bin");
            var asked = new List<string>();
            var images = new DuplicateFinder { MinimumBytes = 100_000, EdgeBytes = 4_096, EncryptedImage = path => { asked.Add(path); return true; } };
            var marked = images.Find([At("Images")], rules).Groups.SelectMany(x => x.Copies).ToList();
            Check(marked.Count == 4 && marked.All(c => c.IsEncryptedImage == (Paths.Extension(c.Path) == "vhdx")),
                  "зашифрованные образы .vhdx помечены, другие файлы — нет");
            Check(asked.All(p => Paths.Extension(p) == "vhdx"), "о шифровании спрашивают только у образов");

            var clonePaths = new HashSet<string>(Paths.Comparer) { At(@"Pictures\2019\photo.jpg"), At(@"Downloads\photo.jpg") };
            var clones = new DuplicateFinder { MinimumBytes = 100_000, EdgeBytes = 4_096, EncryptedImage = _ => false,
                                               ContentIdentifier = path => clonePaths.Contains(path) ? 42 : null };
            Check(clones.Find(roots, rules).Groups.FirstOrDefault()?.Copies.Count(c => c.SharesData) == 2, "клоны помечены: удаление одного места не освободит");

            int calls = 0;
            var stopped = finder.Find(roots, rules, isCancelled: () => ++calls > 3);
            Check(!stopped.Completed && stopped.Groups.Count == 0, "остановленный поиск ничего не выдаёт за итог");

            Check(DuplicateFinder.SameContent(At(@"Downloads\photo.jpg"), At(@"Pictures\2019\photo.jpg")), "одинаковые файлы совпадают байт в байт");
            Check(!DuplicateFinder.SameContent(At(@"Downloads\photo.jpg"), At(@"Documents\almost.jpg")), "различие в одном байте посередине находится");
            Check(!DuplicateFinder.SameContent(At(@"Downloads\photo.jpg"), At(@"Documents\hardlink.jpg")), "второе имя того же файла копией не считается");
            Check(!DuplicateFinder.SameContent(At(@"Downloads\small.txt"), At(@"Downloads\photo.jpg")), "разный размер — не копии");
            ExpectError("исчезнувший файл — ошибка, а не «совпало»", () => DuplicateFinder.SameContent(At(@"Downloads\photo.jpg"), At(@"Downloads\нет такого.jpg")));
            if (CanSymlink)
                ExpectError("ссылка вместо файла — ошибка, а не сравнение того, на что она ведёт",
                            () => DuplicateFinder.SameContent(At(@"Pictures\2019\photo.jpg"), At(@"Documents\link.jpg")));
        });

        Section("Дубликаты: что остаётся и что удаляется", () =>
        {
            var planner = new CleanupPlanner { Now = CleanupNow, Home = FakeHome };
            DuplicateCopy Copy(string relative, double daysAgo = 10, Verdict? verdict = null, bool shares = false, bool encrypted = false) =>
                new(HomePath(relative), 5_000_000, CleanupNow.AddDays(-daysAgo), CleanupNow.AddDays(-daysAgo), verdict, shares, encrypted);
            DuplicateGroup Group(params DuplicateCopy[] copies) => new($"h{copies.Length}", 5_000_000, copies);
            List<string> Names(List<CleanupSuggestion> list) => list.Select(s => s.Id[(FakeHome.Length + 1)..]).ToList();

            var placed = planner.Suggestions([], [Group(Copy(@"Downloads\a.pdf", 400), Copy(@"Documents\Отчёты\a.pdf", 1))]);
            Check(Names(placed).SequenceEqual([@"Documents\Отчёты\a.pdf", @"Downloads\a.pdf"]), "остаётся копия на своём месте, а не в Загрузках — даже более новая");
            Check(placed.Select(s => s.Action).SequenceEqual([CleanupAction.Keep, CleanupAction.Trash]) && placed.All(s => s.DuplicateGroup == "h2"),
                  "лишняя копия — в Корзину, обе строки помечены группой");
            Check(placed[1].Allowed.SequenceEqual([CleanupAction.Trash, CleanupAction.Keep]), "лишнюю копию можно и оставить");

            var named = planner.Suggestions([], [Group(Copy(@"Downloads\a (1).pdf", 30), Copy(@"Downloads\a.pdf", 1))]);
            Check(Names(named).First() == @"Downloads\a.pdf", "из двух в одной папке остаётся имя без «(1)»");
            Check(CleanupPlanner.LooksLikeCopy("Отчёт копия 2.pdf") && CleanupPlanner.LooksLikeCopy("photo copy.jpg") && CleanupPlanner.LooksLikeCopy("scan 2.pdf")
                  && CleanupPlanner.LooksLikeCopy("invoice-1.pdf") && CleanupPlanner.LooksLikeCopy("Отчёт - копия.pdf") && CleanupPlanner.LooksLikeCopy("Отчёт - копия (2).pdf")
                  && !CleanupPlanner.LooksLikeCopy("Отчёт 2019.pdf") && !CleanupPlanner.LooksLikeCopy("a.pdf"),
                  "имена копий узнаются, в том числе «— копия» Проводника; год в имени копией не считается");
            var older = planner.Suggestions([], [Group(Copy(@"Documents\b.pdf", 5), Copy(@"Pictures\b.pdf", 50))]);
            Check(Names(older).First() == @"Pictures\b.pdf", "при прочих равных остаётся копия, появившаяся раньше");

            var music = planner.Suggestions([], [Group(Copy(@"Downloads\song.m4a", 400), Copy(@"Music\iTunes\iTunes Media\Music\A\song.m4a", 1))]);
            Check(Names(music).First().StartsWith(@"Music\iTunes\") && music.First().Allowed.SequenceEqual([CleanupAction.Keep]),
                  "копия в медиатеке iTunes остаётся, и удалить её нельзя вовсе");
            Check(music.Last().Action == CleanupAction.Trash, "лишней становится копия в Загрузках");
            Check(planner.Suggestions([], [Group(Copy(@"Music\iTunes\iTunes Media\a.m4a"), Copy(@"Music\Apple Music\Media\a.m4a"))]).Count == 0,
                  "группа, где удалить нельзя ни одну копию, не показывается");
            Check(planner.Suggestions([], [Group(Copy(@"Documents\c.pdf", shares: true), Copy(@"Documents\c - копия.pdf", shares: true))]).Count == 0,
                  "клоны не предлагаются: места их удаление не освободит");
            var blocked = planner.Suggestions([], [Group(Copy(@"Documents\d.bin"), Copy(@"Documents\x.utm\d.bin", verdict: Verdict.Blocked("пакет")))]);
            Check(blocked.First(s => s.Id.Contains(".utm")).Allowed.SequenceEqual([CleanupAction.Keep]), "копию в запрещённом месте удалить нельзя");
            Check(planner.Suggestions([], [Group(Copy(@"Downloads\vault.vhdx", encrypted: true), Copy(@"Documents\vault.vhdx", encrypted: true))]).Count == 0,
                  "копии зашифрованного образа не удаляются: как и сам образ, это личные данные");
            Check(planner.Suggestions([], [Group(Copy(@"Downloads\ubuntu.iso"), Copy(@"VMs\ubuntu.iso"))]).Count == 0,
                  "копии .iso не удаляются: к образу бывает подключена виртуальная машина");
            var plainImage = planner.Suggestions([], [Group(Copy(@"Downloads\photos.img"), Copy(@"Documents\photos.img"))]);
            Check(plainImage.Select(s => s.Action).SequenceEqual([CleanupAction.Keep, CleanupAction.Trash]), "у обычного образа .img лишняя копия удаляется, как любая другая");

            CleanupObservation Top(string relative, double gb, double daysAgo) =>
                new(HomePath(relative), (long)(gb * 1_000_000_000), CleanupNow.AddDays(-daysAgo), false, Verdict.Safe);
            var film = Group(Copy(@"Videos\film.mkv", 400), Copy(@"Downloads\film.mkv", 300));
            var merged = planner.Suggestions([Top(@"Videos\film.mkv", 4, 400), Top(@"Downloads\film.mkv", 4, 300)], [film]);
            Check(merged.Count == 2 && merged.All(s => s.DuplicateGroup != null), "файл-копия показывается только в своей группе");
            Check(merged[0].Action == CleanupAction.Keep && merged[0].Allowed.SequenceEqual([CleanupAction.Trash, CleanupAction.Keep]),
                  "у копии два исхода — в Корзину или остаться: в сейф крупное и старое убирается своей плиткой");
            Check(merged[1].Action == CleanupAction.Trash && merged[1].Allowed.SequenceEqual([CleanupAction.Trash, CleanupAction.Keep])
                  && merged.All(s => s.Module == CleanupModule.Duplicates), "лишняя копия — в Корзину, обе в плитке «Одинаковые файлы»");
            Check(!merged.Any(s => s.Preselected) && merged[1].DefaultChoice == CleanupAction.Keep, "лишние копии сами не отмечаются: какие удалить, решаете вы");
            var spared = With(planner, ignored: new HashSet<string>(Paths.Comparer) { HomePath(@"Downloads\a.pdf") })
                .Suggestions([], [Group(Copy(@"Downloads\a.pdf"), Copy(@"Documents\a.pdf"))]);
            Check(Names(spared).SequenceEqual([@"Downloads\a.pdf", @"Documents\a.pdf"]) && spared[0].Allowed.SequenceEqual([CleanupAction.Keep])
                  && spared[1].Action == CleanupAction.Trash, "копия, которую вы просили не предлагать, остаётся, а другая становится лишней");
            var installers = planner.Suggestions([Top(@"Downloads\app.msi", 0.5, 30), Top(@"Desktop\app.msi", 0.5, 30)],
                                                 [Group(Copy(@"Downloads\app.msi"), Copy(@"Desktop\app.msi"))]);
            Check(installers.Select(s => s.Action).SequenceEqual([CleanupAction.Keep, CleanupAction.Keep])
                  && installers.All(s => s.DuplicateGroup == null && s.Allowed.Contains(CleanupAction.Trash)),
                  "старые установщики в группу не попадают: удалить их, каждый по отдельности, решаете вы");

            var kept = With(planner, memory: Remember((@"Downloads\a.pdf", CleanupAction.Keep))).Suggestions([], [Group(Copy(@"Downloads\a.pdf"), Copy(@"Documents\a.pdf"))]);
            Check(kept[^1].Action == CleanupAction.Keep && kept[^1].Learned, "прошлое «оставить» для копии помнится");
            var both = With(planner, memory: Remember((@"Downloads\a.pdf", CleanupAction.Trash), (@"Documents\a.pdf", CleanupAction.Trash)))
                .Suggestions([], [Group(Copy(@"Downloads\a.pdf"), Copy(@"Documents\a.pdf"))]);
            Check(both.Any(s => s.Action != CleanupAction.Trash), "прошлые решения не отправят в Корзину все копии разом");

            // Выбор человека: последнюю остающуюся копию удалить нельзя, сверка — с остающейся.
            var pair = placed;
            Func<CleanupSuggestion, CleanupAction> Effective(Dictionary<string, CleanupAction> choices) =>
                s => choices.TryGetValue(s.Id, out var action) ? action : s.Action;
            Check(CleanupPlanner.Options(pair[0], pair, Effective(new())).SequenceEqual([CleanupAction.Keep]), "у единственной остающейся копии Корзины в выборе нет");
            Check(CleanupPlanner.Options(pair[1], pair, Effective(new())).SequenceEqual([CleanupAction.Trash, CleanupAction.Keep]), "у лишней — есть");
            Check(CleanupPlanner.Options(pair[0], pair, Effective(new() { [pair[1].Id] = CleanupAction.Keep })).Contains(CleanupAction.Trash),
                  "оставили другую копию — эту теперь можно удалить");
            Check(CleanupPlanner.Reference(pair[1], pair, Effective(new()))?.Id == pair[0].Id, "удаляемая копия сверяется с остающейся");
            Check(CleanupPlanner.Reference(pair[1], pair, Effective(new() { [pair[0].Id] = CleanupAction.Trash })) == null,
                  "если не остаётся ни одной копии, сверять не с чем — удалять нельзя");

            var folder = CleanupSuggestion.Make(HomePath("Documents"), 1, null, true, CleanupAction.Safe, "", [CleanupAction.Safe, CleanupAction.Keep], false, []);
            Check(CleanupPlanner.Container(placed[0], [folder, .. placed])?.Id == folder.Id, "видно, в какой папке из списка лежит копия");
            Check(CleanupPlanner.Container(placed[1], [folder, .. placed]) == null, "копия в Загрузках ни в какой папке списка не лежит");
            var sibling = CleanupSuggestion.Make(HomePath("Doc"), 1, null, true, CleanupAction.Safe, "", [CleanupAction.Safe, CleanupAction.Keep], false, []);
            Check(CleanupPlanner.Container(placed[0], [sibling, .. placed]) == null, "папка с похожим началом имени контейнером не считается");
        });
    }
}
