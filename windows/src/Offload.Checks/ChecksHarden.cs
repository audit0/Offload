using System.Text;
using System.Text.Json;
using Offload.Core;
using static Offload.Checks.Harness;
using static Offload.Checks.Helpers;

namespace Offload.Checks;

// Возврат на настоящих пробных дисках против подготовленного диска: подделанный журнал, ссылки в пути
// возврата, в архиве, на месте списка сумм и в папке бэкапа; служебные файлы Проводника полным кругом;
// трудные имена; чужие остатки копирования.
static partial class All
{
    static void ChecksHarden()
    {
        if (!Integration)
        {
            Console.WriteLine("▸ Возврат: ловушки, служебные файлы, имена и остатки — пропущено (OFFLOAD_SKIP_INTEGRATION=1 или нет прав администратора)");
            return;
        }

        Section("Возврат: путь через подложенную точку соединения в автозагрузку", () =>
        {
            // Журнал лежит на внешнем диске, и записать в него может кто угодно. Опасна не сама запись, а возврат по ней:
            // он создаёт недостающие папки и кладёт туда содержимое архива. Путь «Documents\Фото\old\…\Startup\…»,
            // где old — точка соединения на AppData, до конца не существует.
            var volume = SharedExFat.Info;
            var rules = new SafetyRules(Room("home-trap"));
            var mover = new SafeMover(rules);
            var startup = Path.Combine(rules.Home, @"AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup");
            Directory.CreateDirectory(startup);
            var photos = Path.Combine(rules.Home, @"Documents\Фото");
            Directory.CreateDirectory(photos);
            Junction(Path.Combine(photos, "old"), Path.Combine(rules.Home, "AppData"));

            // Архив настоящий и лежит на диске: если проверка пути отвалится, возврату будет что записать.
            var archived = Path.Combine(SharedExFat.Root, @"Offload\Documents\Фото\old\evil");
            Write("start calc", Path.Combine(archived, "evil.cmd"));
            var trap = new MoveRecord
            {
                OriginalPath = Path.Combine(photos, @"old\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\evil"),
                ArchivedPath = archived, VolumeName = volume.Name, Files = 1, Bytes = 10, OriginalRemoved = true,
            };
            ExpectError("возврат по записи журнала через точку соединения в AppData отклоняется", () => mover.Restore(trap, deleteArchive: false),
                        ex => IsMove(ex, MoveErrorKind.UnsafeRecord));
            Check(Directory.GetFileSystemEntries(startup).Length == 0, "в автозагрузке ничего не появилось");
            ExpectError("тот же путь с короткими именами 8.3 — тоже", () => mover.Restore(trap with
            {
                OriginalPath = (ShortPath(Path.Combine(photos, "old")) ?? Path.Combine(photos, "old")) + @"\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\evil",
            }, deleteArchive: false), ex => IsMove(ex, MoveErrorKind.UnsafeRecord));

            // Тот же архив по честному пути обязан вернуться: иначе проверка выше доказывала бы только то,
            // что возврат не работает вообще.
            var honest = trap with { Id = Guid.NewGuid(), OriginalPath = Path.Combine(photos, "старое") };
            var done = mover.Restore(honest, deleteArchive: false);
            Check(done.Record.Restored && Exists(Path.Combine(photos, @"старое\evil.cmd")), "тот же архив по пути без ссылок возвращается");
        });

        Section("Возврат: desktop.ini уезжает в архив и возвращается", () =>
        {
            // В desktop.ini — значок и вид папки, выбранные человеком. Оригинал после переноса удаляется, поэтому
            // не скопировать desktop.ini — значит его потерять. А Проводник пишет его и Thumbs.db в любой момент,
            // в том числе между планом и переносом, и это не должно срывать уже начатый перенос.
            var volume = SharedExFat.Info;
            var rules = new SafetyRules(Room("home-ds"));
            var mover = new SafeMover(rules);
            var source = Path.Combine(rules.Home, @"Downloads\галерея");
            Write("снимок", Path.Combine(source, "фото.jpg"));
            Write("текст", Path.Combine(source, @"вложенная\файл.txt"));
            Write("вид вложенной папки", Path.Combine(source, @"вложенная\desktop.ini"));
            Add(Path.Combine(source, @"вложенная\desktop.ini"), FileAttributes.Hidden | FileAttributes.System);

            var plan = mover.Plan(source, volume);
            Write("вид корневой папки", Path.Combine(source, "desktop.ini"));
            Write("эскизы", Path.Combine(source, "Thumbs.db"));
            var record = mover.Execute(plan, deleteOriginal: true, acceptCautions: true);
            Check(!Exists(source), "(а) desktop.ini и Thumbs.db, появившиеся после проверки, перенос не сорвали");
            var target = record.ArchivedPath;
            Check(Exists(Path.Combine(target, @"вложенная\desktop.ini")), "(б) desktop.ini вложенной папки уехал в архив, а не пропал вместе с оригиналом");
            Check(Exists(Path.Combine(target, "desktop.ini")) && Exists(Path.Combine(target, "Thumbs.db")), "(б) поздние служебные файлы тоже в архиве");

            var outcome = mover.Restore(record, deleteArchive: true);
            Check(Read(Path.Combine(source, @"вложенная\desktop.ini")) == "вид вложенной папки", "(в) desktop.ini вернулся вместе с папкой, и это тот самый файл");
            Check(Has(Path.Combine(source, @"вложенная\desktop.ini"), FileAttributes.Hidden), "(в) и остался скрытым");
            Check(Exists(Path.Combine(source, "desktop.ini")), "(в) desktop.ini корня вернулся");
            Check(!outcome.NeedsAttention, $"(в) круг с desktop.ini прошёл без поводов для тревоги: {string.Join(" | ", outcome.Notes)}");
            Check(outcome.Notes.SequenceEqual(["Со списком, записанным при переносе, сверено 2 файлов из 2 в архиве."]),
                  $"(в) служебные файлы вычтены с обеих сторон сверки, сверены только настоящие файлы: {string.Join(" | ", outcome.Notes)}");

            // Настоящий новый файл — не Проводник: такой перенос обязан остановиться.
            var second = Path.Combine(rules.Home, @"Downloads\вторая");
            Write("данные", Path.Combine(second, "файл.txt"));
            var secondPlan = mover.Plan(second, volume);
            Write("появился сам", Path.Combine(second, "новый.txt"));
            ExpectError("(г) настоящий новый файл по-прежнему останавливает перенос", () => mover.Execute(secondPlan, deleteOriginal: true, acceptCautions: true),
                        ex => IsMove(ex, MoveErrorKind.ContentMismatch));
            Check(Exists(Path.Combine(second, "файл.txt")), "(г) после остановки оригинал на месте");
        });

        Section("Возврат: о чём предупреждает сверка со списком сумм", () =>
        {
            var volume = SharedNtfs.Info;
            var rules = new SafetyRules(Room("home-notes"));
            var mover = new SafeMover(rules);

            // Списка сумм рядом с архивом нет: его унесли, потеряли или перенос делали руками.
            var orphan = Path.Combine(rules.Home, @"Downloads\без-списка");
            Write("раз", Path.Combine(orphan, "one.txt"));
            Write("два", Path.Combine(orphan, "two.txt"));
            var orphanRecord = mover.Execute(mover.Plan(orphan, volume), deleteOriginal: true, acceptCautions: true);
            File.Delete(SafeMover.ChecksumPath(orphanRecord.ArchivedPath));
            var withoutList = mover.Restore(orphanRecord, deleteArchive: false);
            Check(withoutList.Record.Restored, "без списка сумм возврат состоялся");
            Check(withoutList.Notes.Any(n => n.Contains("нет списка контрольных сумм")), $"о пропавшем списке сумм сказано оговоркой: {string.Join(" | ", withoutList.Notes)}");
            Check(withoutList.NeedsAttention, "возврат без списка сумм помечен как то, на что стоит посмотреть");
            Check(Read(Path.Combine(orphan, "two.txt")) == "два", "данные вернулись и сверены с тем, что лежало в архиве");

            // Из архива пропал файл: человек сам его удалил, пока работал на внешнем диске.
            var gap = Path.Combine(rules.Home, @"Downloads\пропажа");
            Write("первый", Path.Combine(gap, "один.txt"));
            Write("второй", Path.Combine(gap, "два.txt"));
            Write("третий", Path.Combine(gap, "три.txt"));
            var gapRecord = mover.Execute(mover.Plan(gap, volume), deleteOriginal: true, acceptCautions: true);
            File.Delete(Path.Combine(gapRecord.ArchivedPath, "два.txt"));
            var missing = mover.Restore(gapRecord, deleteArchive: true);
            Check(missing.Notes.Any(n => n.Contains("не хватает 1 файлов") && n.Contains("два.txt")), $"о пропавшем из архива файле сказано оговоркой: {string.Join(" | ", missing.Notes)}");
            Check(missing.Notes.Any(n => n.Contains("сверено 2 файлов из 2")), "сверенное посчитано по тому, что в архиве есть");
            Check(missing.NeedsAttention, "нехватка файла помечена как то, на что стоит посмотреть");
            Check(Exists(Path.Combine(gap, "один.txt")) && Exists(Path.Combine(gap, "три.txt")) && !Exists(Path.Combine(gap, "два.txt")), "вернулось всё, что в архиве осталось");

            // Подготовленный диск: на месте списка сумм — папка, ссылка на файл с компьютера или огромный файл.
            var victim = Path.Combine(rules.Home, @"Documents\пароли.txt");
            Write("мои пароли", victim);
            RestoreOutcome Forged(string name, Action<string> forge)
            {
                var folder = Path.Combine(rules.Home, @"Downloads\" + name);
                Write("данные " + name, Path.Combine(folder, "a.txt"));
                var moved = mover.Execute(mover.Plan(folder, volume), deleteOriginal: true, acceptCautions: true);
                forge(moved.ArchivedPath);
                return mover.Restore(moved, deleteArchive: true);
            }
            var asFolder = Forged("список-папка", archive =>
            {
                File.Delete(SafeMover.ChecksumPath(archive));
                Directory.CreateDirectory(SafeMover.ChecksumPath(archive));
            });
            Check(asFolder.Record.Restored && asFolder.Notes.Any(n => n.Contains("не читается")), "папка на месте списка сумм — «не читается», возврат состоялся");
            if (CanSymlink)
            {
                var asLink = Forged("список-ссылка", archive =>
                {
                    File.Delete(SafeMover.ChecksumPath(archive));
                    File.CreateSymbolicLink(SafeMover.ChecksumPath(archive), victim);
                });
                Check(asLink.Record.Restored && asLink.Notes.Any(n => n.Contains("не читается")), "ссылка на месте списка сумм не читается — файл с компьютера не открыт");
                Check(Read(victim) == "мои пароли", "файл за ссылкой не тронут");
                var modesLink = Forged("атрибуты-ссылка", archive =>
                {
                    File.Delete(SafeMover.ModesPath(archive));
                    File.CreateSymbolicLink(SafeMover.ModesPath(archive), victim);
                });
                Check(modesLink.Record.Restored && Read(victim) == "мои пароли", "ссылка на месте списка атрибутов не читается, возврат состоялся");
            }
            var huge = Forged("огромный", archive =>
            {
                if (File.Exists(SafeMover.ModesPath(archive))) File.Delete(SafeMover.ModesPath(archive));
                using var stream = new FileStream(SafeMover.ModesPath(archive), FileMode.CreateNew);
                stream.SetLength(SafeMover.MaxSidecarBytes + 1L);
            });
            Check(huge.Record.Restored && Read(Path.Combine(rules.Home, @"Downloads\огромный\a.txt")) == "данные огромный",
                  "огромный список атрибутов не читается, возврат состоялся");
            var garbage = Forged("мусор", archive =>
            {
                File.Delete(SafeMover.ChecksumPath(archive));
                File.WriteAllText(SafeMover.ChecksumPath(archive), "это не список сумм\n");
            });
            Check(garbage.Record.Restored && garbage.NeedsAttention && garbage.Notes.Any(n => n.Contains("не читается")), "мусор вместо списка сумм — оговорка, а не отказ");
        });

        Section("Возврат: имена с кириллицей, пробелами, знаками и длинные пути", () =>
        {
            // Список сумм — текстовый файл формата sha256sum, а в именах бывает что угодно. Если экранирование
            // и разбор разойдутся, сверка объявит целый архив изменившимся на совершенно нетронутом архиве.
            var volume = SharedExFat.Info;
            var rules = new SafetyRules(Room("home-names"));
            var mover = new SafeMover(rules);
            var source = Path.Combine(rules.Home, @"Downloads\архив документов");
            string[] names = ["счёт за январь.txt", "отчет за год.txt", @"папка с пробелами\строка; вторая & [x] $y 'q' #1 %PATH%.txt", "обычный.txt",
                              "emoji 📁.txt", "  два пробела  в начале.txt"];
            foreach (var name in names) Write($"содержимое {name.Length}", Path.Combine(source, name));

            var record = mover.Execute(mover.Plan(source, volume), deleteOriginal: true, acceptCautions: true);
            Check(record.Files == names.Length, $"перенесены все файлы ({record.Files})");
            var list = File.ReadAllText(SafeMover.ChecksumPath(record.ArchivedPath));
            Check(list.Split('\n', StringSplitOptions.RemoveEmptyEntries).Length == names.Length, "каждому файлу — ровно одна строка в списке сумм");
            var outcome = mover.Restore(record, deleteArchive: true);
            Check(outcome.Notes.SequenceEqual([$"Со списком, записанным при переносе, сверено {names.Length} файлов из {names.Length} в архиве."]),
                  $"трудные имена прошли круг без ложных расхождений: {string.Join(" | ", outcome.Notes)}");
            Check(!outcome.NeedsAttention, "нетронутый архив с трудными именами не тревожит человека зря");
            foreach (var name in names) Check(Exists(Path.Combine(source, name)), $"«{name}» вернулся на место");

            // Путь длиннее 260 знаков: Проводник и .NET такие создают, и перенос обязан с ними справляться.
            var longSource = Path.Combine(rules.Home, @"Downloads\длинные пути");
            var deep = string.Join("\\", Enumerable.Repeat("очень длинное имя папки", 12)) + @"\последний файл.txt";
            Write("глубоко", Path.Combine(longSource, deep));
            Write("мелко", Path.Combine(longSource, "рядом.txt"));
            Check(Path.Combine(longSource, deep).Length > 260, $"есть путь длиннее 260 знаков ({Path.Combine(longSource, deep).Length})");
            var longPlan = mover.Plan(longSource, volume);
            MoveRecord? longRecord = null;
            Check(() =>
            {
                longRecord = mover.Execute(longPlan, deleteOriginal: true, acceptCautions: true);
                return true;
            }, "папка с путём длиннее 260 знаков переносится");
            if (longRecord == null)
            {
                Check(Read(Path.Combine(longSource, deep)) == "глубоко" && !Exists(longPlan.Target), "после отказа оригинал на месте, на диске ничего не осталось");
                Check(!Directory.GetDirectories(Paths.Parent(longPlan.Target)).Any(d => Paths.Name(d).StartsWith(".offload-partial-")), "временная папка копирования убрана");
            }
            else
            {
                var longOutcome = mover.Restore(longRecord, deleteArchive: true);
                Check(longOutcome.Record.Restored && Read(Path.Combine(longSource, deep)) == "глубоко" && !Exists(longRecord.ArchivedPath),
                      "и возвращается обратно, архив удалён целиком");
            }
        });

        Section("Остатки прерванных копирований: чужой компьютер", () =>
        {
            // Внешний диск носят между компьютерами. Номер процесса с чужого компьютера здесь ничего не значит:
            // чужую свежую метку берегут, а решает возраст метки — её обновляет само копирование.
            var volume = SharedNtfs.Info;
            var rules = new SafetyRules(Room("home-partials"));
            var mover = new SafeMover(rules);
            var archived = Path.Combine(SharedNtfs.Root, @"Ручной\данные");
            Write("данные", Path.Combine(archived, "file.txt"));
            var downloads = Path.Combine(rules.Home, "Downloads");
            Directory.CreateDirectory(downloads);
            var record = Manual(mover, archived, Path.Combine(downloads, "данные"), volume);
            var foreignFresh = Partial(downloads, "foreign-fresh", 999_999, host: "другой-пк");
            var foreignStale = Partial(downloads, "foreign-stale", Environment.ProcessId, DateTime.UtcNow.AddDays(-3), "другой-пк");
            var liveHere = Partial(downloads, "live-here", Environment.ProcessId);
            var garbageLock = Partial(downloads, "garbage-lock");
            File.WriteAllText(Path.Combine(garbageLock, ".offload-lock"), "не метка\n");
            Directory.SetLastWriteTimeUtc(garbageLock, DateTime.UtcNow.AddDays(-5));
            // Не папка, а файл с похожим именем — не остаток: его не трогают.
            var lookalike = Path.Combine(downloads, ".offload-partial-файл");
            Write("файл человека", lookalike);
            File.SetLastWriteTimeUtc(lookalike, DateTime.UtcNow.AddDays(-5));
            var outside = Room("partial-outside");
            Write("чужое", Path.Combine(outside, "keep.txt"));
            var linkedPartial = Path.Combine(downloads, ".offload-partial-ссылка");
            Junction(linkedPartial, outside);

            var outcome = mover.Restore(record, deleteArchive: false);
            Check(outcome.Record.Restored, "возврат прошёл");
            Check(Exists(foreignFresh), "свежая метка другого компьютера бережётся: там может идти копирование");
            Check(!Exists(foreignStale), "метка другого компьютера, которую сутками не обновляли, остаток не спасает");
            Check(Exists(liveHere), "идущее копирование на этом компьютере не тронуто");
            Check(!Exists(garbageLock), "испорченная метка — как её нет: старый остаток убран");
            Check(Exists(lookalike), "файл с похожим именем не тронут");
            Check(Exists(Path.Combine(outside, "keep.txt")), "по точке соединения с похожим именем ничего не удалено");
            Check(Exists(Path.Combine(downloads, @"данные\file.txt")), "данные вернулись на место");
        });

        Section("Аудит: «._»-файлы, подложенные ссылки, чужая запись в скрытую папку", () =>
        {
            var exfat = SharedExFat.Info;
            var ntfs = SharedNtfs.Info;
            var rules = new SafetyRules(Room("home-audit"));
            var mover = new SafeMover(rules);

            // Файлы человека с именами на «._» рядом с одноимёнными (с FAT-флешки, из архива) — на exFAT едут
            // и возвращаются: они записаны в список сумм при переносе.
            var photos = Path.Combine(rules.Home, @"Downloads\photos");
            Write("jpeg", Path.Combine(photos, "photo.jpg"));
            Write("данные человека", Path.Combine(photos, "._photo.jpg"));
            Write("jpeg3", Path.Combine(photos, "photo3.jpg"));
            File.WriteAllBytes(Path.Combine(photos, "._photo3.jpg"), [0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00, 0x55]);
            var record = mover.Execute(mover.Plan(photos, exfat), deleteOriginal: true, acceptCautions: true);
            var outcome = mover.Restore(record, deleteArchive: true);
            Check(outcome.Record.Restored, $"возврат прошёл: {string.Join(" | ", outcome.Notes)}");
            Check(Read(Path.Combine(photos, "._photo.jpg")) == "данные человека", "настоящий файл «._photo.jpg» вернулся, а не удалён вместе с архивом");
            Check(Exists(Path.Combine(photos, "._photo3.jpg")), "файл человека в формате AppleDouble вернулся: он в списке сумм");
            Check(!Exists(record.ArchivedPath), "архив удалён после сверенного возврата");

            // А служебный двойник, который Mac наплодил на exFAT уже после переноса, в списке сумм не значится и обратно не везётся.
            var clean = Path.Combine(rules.Home, @"Downloads\clean");
            Write("jpeg2", Path.Combine(clean, "photo2.jpg"));
            var cleanRecord = mover.Execute(mover.Plan(clean, exfat), deleteOriginal: true, acceptCautions: true);
            File.WriteAllBytes(Path.Combine(cleanRecord.ArchivedPath, "._photo2.jpg"), [0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00]);
            var cleanOutcome = mover.Restore(cleanRecord, deleteArchive: false);
            Check(Exists(Path.Combine(clean, "photo2.jpg")), "файл вернулся");
            Check(!Exists(Path.Combine(clean, "._photo2.jpg")), "служебный двойник, созданный Mac на exFAT, не вернулся");
            Check(!cleanOutcome.NeedsAttention, $"и расхождением не считается: {string.Join(" | ", cleanOutcome.Notes)}");

            // Запись только в журнале на диске, а путь — в скрытую папку программы (оговорка): не возвращаем.
            var foreignArchive = Path.Combine(SharedExFat.Root, @"Offload\plugin");
            Write("autocmd VimEnter * !curl evil", Path.Combine(foreignArchive, "x.vim"));
            var foreign = new MoveRecord
            {
                OriginalPath = Path.Combine(rules.Home, @".vim\plugin"), ArchivedPath = foreignArchive, VolumeName = exfat.Name, Files = 1, Bytes = 30, OriginalRemoved = true,
            };
            ExpectError("чужая запись с возвратом в скрытую папку программы отклоняется", () => mover.Restore(foreign, deleteArchive: false),
                        ex => IsMove(ex, MoveErrorKind.UnsafeRecord));
            Check(!Exists(Path.Combine(rules.Home, ".vim")), "в ~\\.vim ничего не появилось");
            // Та же запись, сделанная на этом компьютере (есть в локальном журнале), — своя: вернуть можно.
            var own = foreign with { Id = Guid.NewGuid() };
            Journal.Save(own, exfat);
            var ownOutcome = mover.Restore(own, deleteArchive: false);
            Check(ownOutcome.Record.Restored && Exists(Path.Combine(rules.Home, @".vim\plugin\x.vim")), "своя запись в скрытую папку возвращается");

            if (!CanSymlink) Console.WriteLine("  (символические ссылки создавать нельзя — часть проверок пропущена)");

            // Подготовленный диск: на месте будущего списка сумм — ссылка на файл с компьютера.
            var victim = Path.Combine(rules.Home, @"Documents\диплом.docx");
            Write("мой диплом", victim);
            var notes = Path.Combine(rules.Home, @"Downloads\notes");
            Write("заметки", Path.Combine(notes, "a.txt"));
            var trapFolder = Path.Combine(SharedNtfs.Root, @"Offload\Downloads");
            Directory.CreateDirectory(trapFolder);
            if (CanSymlink)
            {
                File.CreateSymbolicLink(Path.Combine(trapFolder, "notes.sha256"), victim);
                var moved = mover.Execute(mover.Plan(notes, ntfs), deleteOriginal: false, acceptCautions: true);
                Check(Read(victim) == "мой диплом", "файл на компьютере за подложенной ссылкой не перезаписан");
                Check(Paths.Name(moved.ArchivedPath) == "notes (2)", $"архив взял свободное имя вместе со спутниками: {moved.ArchivedPath}");
            }

            // Путь к архиву в журнале проходит через точку соединения на самом диске.
            var realArchive = Path.Combine(SharedNtfs.Root, @"Offload\настоящий");
            Write("x", Path.Combine(realArchive, "x.txt"));
            Junction(Path.Combine(SharedNtfs.Root, "короткий"), Path.Combine(SharedNtfs.Root, "Offload"));
            ExpectError("путь к архиву через точку соединения отклоняется",
                        () => mover.Validate(new MoveRecord { OriginalPath = Path.Combine(rules.Home, @"Downloads\x"), ArchivedPath = Path.Combine(SharedNtfs.Root, @"короткий\настоящий") }),
                        ex => IsMove(ex, MoveErrorKind.UnsafeRecord) && ex.Message.Contains("ссылк"));

            // Подделанный архив: точка соединения внутри ведёт на папку с компьютера, а список атрибутов — на файл за ней.
            var victimFolder = Room("victim-folder");
            Write("secret", Path.Combine(victimFolder, "victim.txt"));
            var victimAttributes = Attributes(Path.Combine(victimFolder, "victim.txt"));
            var evil = Path.Combine(rules.Home, @"Downloads\evil-source");
            Write("обычный", Path.Combine(evil, "a.txt"));
            var evilRecord = mover.Execute(mover.Plan(evil, ntfs), deleteOriginal: true, acceptCautions: true);
            Junction(Path.Combine(evilRecord.ArchivedPath, "evil"), victimFolder);
            ForgeModes(evilRecord.ArchivedPath, new() { ["evil/victim.txt"] = ReadOnly | Hidden | SystemFlag, ["evil"] = ReadOnly | Hidden });
            var evilOutcome = mover.Restore(evilRecord, deleteArchive: false);
            Check(Attributes(Path.Combine(victimFolder, "victim.txt")) == victimAttributes, "подделанный архив не изменил атрибуты файла вне папки");
            Check(!Has(victimFolder, FileAttributes.Hidden) && !Has(victimFolder, FileAttributes.ReadOnly), "и самой папки за точкой соединения");
            Check(evilOutcome.Record.Restored && Reparse.Read(Path.Combine(evil, "evil")) is { Type: LinkType.Junction }
                  && FileSystem.Stat(Path.Combine(evil, "evil")) is { IsLink: true },
                  "подложенная точка соединения вернулась ссылкой, а не содержимым папки с компьютера");
            Check(Read(Path.Combine(victimFolder, "victim.txt")) == "secret", "файл за точкой соединения цел");

            // Бэкап на подготовленный диск: папка бэкапа — ссылка на компьютер, папка проекта внутри — тоже.
            var project = Path.Combine(rules.Home, @"Projects\site");
            Write("<h1>site</h1>", Path.Combine(project, @"src\index.html"));
            var outside = Room("audit-outside");
            var linkedRoot = Path.Combine(SharedNtfs.Root, "Backup-link");
            Junction(linkedRoot, outside);
            ExpectError("бэкап в папку-ссылку на подготовленном диске отклоняется", () => BackupEngine.Run([project], linkedRoot),
                        ex => ex is BackupException && ex.Message.Contains("ссылку"));
            var backupRoot = Path.Combine(SharedNtfs.Root, "Offload Backup");
            Directory.CreateDirectory(Path.Combine(backupRoot, "site"));
            Junction(Path.Combine(backupRoot, @"site\src"), outside);
            var report = BackupEngine.Run([project], backupRoot);
            Check(Directory.GetFileSystemEntries(outside).Length == 0, "через подложенную ссылку внутри бэкапа на компьютере ничего не записано");
            Check(report.Problems.Count > 0, "о подложенной ссылке сказано в отчёте бэкапа");
            if (CanSymlink)
            {
                var fileTrap = Path.Combine(backupRoot, @"site\README.md");
                var victimFile = Path.Combine(outside, "не трогать.txt");
                Write("чужое", victimFile);
                Write("# site", Path.Combine(project, "README.md"));
                File.CreateSymbolicLink(fileTrap, victimFile);
                var fileReport = BackupEngine.Run([project], backupRoot);
                Check(Read(victimFile) == "чужое", "ссылка на месте файла бэкапа не перезаписала файл за ней");
                Check(fileReport.Problems.Any(p => p.Contains("README.md")), "и об этом сказано в отчёте");
            }
        });

        Section("Подделанный журнал на диске", () =>
        {
            var volume = SharedNtfs.Info;
            var rules = new SafetyRules(Room("home-forged"));
            var mover = new SafeMover(rules);
            var root = SharedNtfs.Root;
            var archived = Path.Combine(root, @"Offload\Downloads\честный");
            Write("данные", Path.Combine(archived, "a.txt"));
            var honest = Path.Combine(rules.Home, @"Downloads\честный");
            var forged = new (string label, string original, string archive)[]
            {
                ("архив с «..»", honest, root + @"Offload\..\..\Windows"),
                ("возврат с «..»", Path.Combine(rules.Home, @"Downloads\..\..\..\Windows\evil"), archived),
                ("сетевой путь архива", honest, @"\\attacker\share\x"),
                ("архив с «\\\\?\\»", honest, @"\\?\" + archived),
                ("поток NTFS в пути", honest, archived + ":evil"),
                ("точка в конце имени", honest, archived + "."),
                ("пробел в конце имени", honest, archived + " "),
                ("относительный путь", honest, @"Offload\Downloads\честный"),
                ("путь через «/»", honest, archived.Replace('\\', '/')),
                ("возврат на другой диск", @"D:\Users\q\Downloads\x", archived),
                ("возврат в Windows", @"C:\Windows\System32\evil.dll", archived),
                ("возврат в общую автозагрузку", @"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\evil.cmd", archived),
                ("возврат в AppData", Path.Combine(rules.Home, @"AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\x"), archived),
                ("возврат в ~\\.ssh", Path.Combine(rules.Home, @".ssh\authorized_keys"), archived),
                ("возврат в git-хуки", Path.Combine(rules.Home, @"Projects\app\.git\hooks"), archived),
                ("возврат в дом целиком", rules.Home, archived),
                ("возврат в реестр пользователя", Path.Combine(rules.Home, "NTUSER.DAT"), archived),
                ("архив на системном диске", honest, Path.Combine(Scratch, "elsewhere")),
                ("архив — корень диска", honest, root),
                ("запись с Mac", "/Users/q/Downloads/x", "/Volumes/SSD/Offload/Downloads/x"),
                ("пустые пути", "", ""),
            };
            var records = forged.Select(f => new MoveRecord { OriginalPath = f.original, ArchivedPath = f.archive, VolumeName = volume.Name, Files = 1, Bytes = 6,
                                                              OriginalRemoved = true, Note = f.label }).ToList();
            var manifest = Journal.ManifestPath(volume);
            Directory.CreateDirectory(Paths.Parent(manifest));
            File.WriteAllBytes(manifest, JsonSerializer.SerializeToUtf8Bytes(records, Journal.Options));
            var loaded = Journal.Records(volume);
            Check(loaded.Count == records.Count, $"подделанный журнал читается как данные, а не исполняется ({loaded.Count})");
            foreach (var record in loaded)
                ExpectError($"запись «{record.Note}» отклоняется до возврата", () => mover.Restore(record, deleteArchive: true),
                            ex => IsMove(ex, MoveErrorKind.UnsafeRecord) || IsMove(ex, MoveErrorKind.AlreadyExists));
            Check(Exists(Path.Combine(archived, "a.txt")) && !Exists(honest), "архив цел, на компьютере ничего не появилось");
            Check(!Exists(@"C:\Windows\System32\evil.dll") && !Exists(@"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\evil.cmd"),
                  "в системные места ничего не записано");
            var good = mover.Restore(new MoveRecord { OriginalPath = honest, ArchivedPath = archived, VolumeName = volume.Name, OriginalRemoved = true }, deleteArchive: false);
            Check(good.Record.Restored && Read(Path.Combine(honest, "a.txt")) == "данные", "честная запись с того же диска возвращается");

            // Огромный журнал на диске не читается целиком и не роняет программу.
            File.Delete(manifest);
            using (var stream = new FileStream(manifest, FileMode.CreateNew)) stream.SetLength(Journal.MaxManifestBytes + 1L);
            Check(Journal.Records(volume).Count == 0, "огромный журнал на диске — пустой список, без чтения в память");
            File.Delete(manifest);
        });
    }
}
