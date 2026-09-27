using System.Globalization;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Offload.Core;
using static Offload.Checks.Harness;
using static Offload.Checks.Helpers;

namespace Offload.Checks;

// Перенос и возврат на настоящих пробных дисках (VHDX с exFAT и NTFS) — ради этого программа и написана:
// данные должны вернуться к человеку. Всё через открытый API SafeMover, как это делает сама программа.
static partial class All
{
    static TestDisk? sharedExFat, sharedNtfs;
    /// <summary>Общий пробный exFAT для разделов, которым не нужен чистый диск.</summary>
    static TestDisk SharedExFat => sharedExFat ??= TestDisk.Create("shared-exfat", "exFAT", "OFFSHARE", 1024);
    /// <summary>Общий пробный NTFS: на нём можно подложить ссылку или точку соединения.</summary>
    static TestDisk SharedNtfs => sharedNtfs ??= TestDisk.Create("shared-ntfs", "NTFS", "OFFNTFS", 1024);

    static void DisposeDisks()
    {
        sharedExFat?.Dispose();
        sharedNtfs?.Dispose();
        sharedExFat = sharedNtfs = null;
    }

    /// <summary>Остаток прерванного копирования с меткой (или без неё) и датой корня, которая сама по себе обманчива.</summary>
    static string Partial(string parent, string suffix, int? pid = null, DateTime? lockDate = null, string? host = null, DateTime? rootDate = null)
    {
        var path = Path.Combine(parent, ".offload-partial-" + suffix);
        Directory.CreateDirectory(path);
        if (pid is { } number)
        {
            var seconds = ((lockDate ?? DateTime.UtcNow) - DateTime.UnixEpoch).TotalSeconds.ToString(CultureInfo.InvariantCulture);
            File.WriteAllText(Path.Combine(path, ".offload-lock"), $"{number} {seconds} {host ?? Environment.MachineName}\n");
        }
        // Дату корня ставим последней: именно она раньше и обманывала проверку.
        Directory.SetLastWriteTimeUtc(path, rootDate ?? DateTime.UtcNow.AddDays(-5));
        return path;
    }

    /// <summary>Права на возвращённое — унаследованы от папки на компьютере, а не принесены с диска.</summary>
    static bool InheritsOnly(string path)
    {
        FileSystemSecurity security = Directory.Exists(path) ? new DirectoryInfo(path).GetAccessControl() : new FileInfo(path).GetAccessControl();
        return security.GetAccessRules(includeExplicit: true, includeInherited: false, typeof(SecurityIdentifier)).Count == 0;
    }

    /// <summary>Подменяет список атрибутов рядом с архивом, как это сделал бы тот, у кого есть доступ к диску.</summary>
    static void ForgeModes(string archive, Dictionary<string, int> extra)
    {
        var path = SafeMover.ModesPath(archive);
        var modes = File.Exists(path) ? JsonSerializer.Deserialize<Dictionary<string, int>>(File.ReadAllBytes(path)) ?? [] : [];
        foreach (var (key, value) in extra) modes[key] = value;
        if (File.Exists(path)) File.Delete(path);
        File.WriteAllBytes(path, JsonSerializer.SerializeToUtf8Bytes(modes));
    }

    const int ReadOnly = 0x1, Hidden = 0x2, SystemFlag = 0x4;

    static void ChecksRestore()
    {
        if (!Integration)
        {
            Console.WriteLine("▸ Перенос и возврат на настоящих дисках — пропущено (OFFLOAD_SKIP_INTEGRATION=1 или нет прав администратора)");
            return;
        }

        Section("Перенос на настоящий exFAT и возврат", () =>
        {
            using var disk = TestDisk.Create("exfat-move", "exFAT", "OFFCHECK", 1024);
            var volume = disk.Info;
            Check(volume.FsType == "exfat", $"пробный том — exFAT ({volume.FsType})");

            var rules = new SafetyRules(Room("home-move"));
            var source = Path.Combine(rules.Home, @"Downloads\project");
            Write("@echo hi\r\n", Path.Combine(source, "run.cmd"));
            Add(Path.Combine(source, "run.cmd"), FileAttributes.ReadOnly);
            Write(new string('x', 300_000), Path.Combine(source, @"data\big.txt"));
            Write("скрытый", Path.Combine(source, @"data\hidden.txt"));
            Add(Path.Combine(source, @"data\hidden.txt"), FileAttributes.Hidden);

            var mover = new SafeMover(rules);
            var stale = mover.Plan(source, volume);
            Write("late", Path.Combine(source, "late.txt"));
            ExpectError("файл, появившийся после проверки, останавливает перенос", () => mover.Execute(stale, deleteOriginal: true, acceptCautions: true),
                        ex => IsMove(ex, MoveErrorKind.ContentMismatch));
            Check(Exists(Path.Combine(source, @"data\big.txt")), "после остановки оригинал на месте");
            Check(!Exists(Path.Combine(disk.Root, "Offload")), "после остановки на диске ничего не осталось");
            File.Delete(Path.Combine(source, "late.txt"));

            // exFAT не хранит ни ссылок, ни точек соединения: такой перенос отклоняется заранее.
            var linked = Path.Combine(rules.Home, @"Downloads\linked");
            Write("x", Path.Combine(linked, @"real\x.txt"));
            Junction(Path.Combine(linked, "jump"), Path.Combine(linked, "real"));
            var refused = mover.Plan(linked, volume);
            Check(!refused.CanProceed && refused.Check.Blockers.Any(b => b.Contains("ссылки")), $"папка с точкой соединения на exFAT не переносится: {string.Join(" ", refused.Check.Blockers)}");
            ExpectError("и выполнить такой план нельзя", () => mover.Execute(refused, deleteOriginal: true, acceptCautions: true), ex => IsMove(ex, MoveErrorKind.Destination));

            var plan = mover.Plan(source, volume);
            Check(plan.Check.IsOK, $"план: диск подходит {string.Join(" ", plan.Check.Blockers)}");
            ExpectError("свежие файлы без подтверждения не переносятся", () => mover.Execute(plan, deleteOriginal: true, acceptCautions: false),
                        ex => IsMove(ex, MoveErrorKind.NeedsConfirmation));

            var record = mover.Execute(plan, deleteOriginal: true, acceptCautions: true);
            var target = record.ArchivedPath;
            Check(record.OriginalRemoved && !Exists(source), "оригинал удалён после сверки");
            Check(target == Path.Combine(disk.Root, @"Offload\Downloads\project"), $"архив лежит в Offload\\<путь от домашней папки>: {target}");
            Check(!Directory.GetDirectories(Paths.Parent(target)).Any(d => Paths.Name(d).StartsWith(".offload-partial-")), "временной папки копирования не осталось");
            Check(!Exists(Path.Combine(target, ".offload-lock")), "метка идущего копирования в архив не попала");
            var list = VerifiedCopy.ParseChecksumList(File.ReadAllText(SafeMover.ChecksumPath(target)), "project");
            Check(list != null && list.Count == 3 && list.All(p => FileHasher.Sha256(Path.Combine(target, p.Key)) == p.Value),
                  "архив сверяется по своему списку сумм, как sha256sum -c");
            Check(Exists(SafeMover.ModesPath(target)) && File.ReadAllText(SafeMover.ModesPath(target)).Contains("run.cmd"), "атрибуты записаны рядом с архивом");
            Check(Journal.Records(volume).Any(r => r.Id == record.Id), "перенос записан в журнал на диске");
            Check(Journal.LocalRecords().Any(r => r.Id == record.Id && r.OriginalRemoved), "и в журнал на компьютере");

            // Архивом пользовались: человек работал с файлами прямо на внешнем диске, и они изменились.
            // Возврат обязан состояться — иначе к данным уже не подступиться, — но сказать об этом надо.
            var archivedFile = Path.Combine(target, @"data\big.txt");
            var goodContent = File.ReadAllText(archivedFile);
            File.WriteAllText(archivedFile, new string('y', goodContent.Length));
            var usedArchive = mover.Restore(record, deleteArchive: false);
            Check(usedArchive.Notes.Any(n => n.Contains("изменилось файлов: 1")), $"изменённый архив вернулся с оговоркой: {string.Join(" | ", usedArchive.Notes)}");
            Check(Read(Path.Combine(source, @"data\big.txt"))?.StartsWith('y') == true, "вернулось то, что лежит в архиве сейчас");
            Check(Exists(target), "архив на месте — удалять его не просили");
            FileSystem.DeleteTree(source);
            File.WriteAllText(archivedFile, goodContent);

            ExpectError("журнал с путём наружу отклоняется", () => mover.Validate(record with { ArchivedPath = disk.Root + @"Offload\..\..\Windows" }),
                        ex => IsMove(ex, MoveErrorKind.UnsafeRecord));
            ExpectError("журнал с возвратом в системное место отклоняется", () => mover.Validate(record with { OriginalPath = @"C:\Windows\System32\drivers\etc\hosts" }),
                        ex => IsMove(ex, MoveErrorKind.UnsafeRecord));
            ExpectError("журнал с возвратом в данные программ отклоняется",
                        () => mover.Validate(record with { OriginalPath = Path.Combine(rules.Home, @"AppData\Local\Docker\x") }), ex => IsMove(ex, MoveErrorKind.UnsafeRecord));
            // Путь возврата ведёт в несуществующее место, и без своей проверки ссылка в нём не развернулась бы:
            // такая запись из журнала записала бы файл в автозагрузку.
            var startup = Path.Combine(rules.Home, @"AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup");
            Directory.CreateDirectory(startup);
            var trapParent = Path.Combine(rules.Home, @"Documents\Фото");
            Directory.CreateDirectory(trapParent);
            Junction(Path.Combine(trapParent, "old"), Path.Combine(rules.Home, "AppData"));
            ExpectError("возврат через подложенную точку соединения в AppData отклоняется",
                        () => mover.Validate(record with { OriginalPath = Path.Combine(trapParent, @"old\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\evil.cmd") }),
                        ex => IsMove(ex, MoveErrorKind.UnsafeRecord));
            Check(Directory.GetFileSystemEntries(startup).Length == 0, "в автозагрузке ничего не появилось");
            ExpectError("архив вне внешнего диска отклоняется", () => mover.Validate(record with { ArchivedPath = Path.Combine(Scratch, "elsewhere") }),
                        ex => IsMove(ex, MoveErrorKind.UnsafeRecord));

            // Подделанный список атрибутов: «системный» из недоверенного архива не ставится, пути наружу не применяются.
            var victim = Path.Combine(Room("victim-attrs"), "victim.txt");
            Write("secret", victim);
            var victimAttributes = Attributes(victim);
            var relativeVictim = Path.GetRelativePath(Paths.Parent(source), victim).Replace('\\', '/');
            ForgeModes(target, new()
            {
                ["data/big.txt"] = Hidden | SystemFlag, ["../victim.txt"] = ReadOnly | Hidden | SystemFlag, [relativeVictim] = ReadOnly | Hidden | SystemFlag,
                [victim.Replace('\\', '/')] = ReadOnly | Hidden | SystemFlag, [victim] = ReadOnly | Hidden | SystemFlag,
            });

            // Перенос, сделанный без OffLoadAI: папка уже лежит на диске в произвольном месте.
            var manual = Path.Combine(disk.Root, @"Archive-2026\old-stuff");
            Write("manual", Path.Combine(manual, "file.txt"));
            Write("@echo hi\r\n", Path.Combine(manual, "tool.cmd"));
            Add(Path.Combine(manual, "tool.cmd"), FileAttributes.Hidden | FileAttributes.System);
            var imported = Manual(mover, manual, Path.Combine(rules.Home, @"Downloads\old-stuff"), volume, "вручную");
            Check(imported.Files == 2 && imported.VolumeName == volume.Name && imported.Note == "вручную", "ручная запись посчитана и привязана к диску");
            Check(Journal.Records(volume).Any(r => r.Id == imported.Id), "ручная запись сохранена в журнал на диске");
            var emptyPlace = Path.Combine(rules.Home, @"Downloads\old-stuff");
            Write("[.ShellClassInfo]", Path.Combine(emptyPlace, "desktop.ini"));
            var back = mover.Restore(imported, deleteArchive: false).Record;
            Check(back.Restored && Read(Path.Combine(emptyPlace, "file.txt")) == "manual", "ручная запись возвращается на место пустой папки со сверкой");
            // У ручного переноса нет списка атрибутов: «системный» с чужого диска не переносится на компьютер.
            Check(!Has(Path.Combine(emptyPlace, "tool.cmd"), FileAttributes.System), "атрибут «системный» с диска на компьютер не принесён");
            Check(InheritsOnly(emptyPlace) && InheritsOnly(Path.Combine(emptyPlace, "file.txt")), "права на возвращённое — унаследованы от папки на компьютере");
            var busyPlace = Path.Combine(rules.Home, @"Downloads\busy");
            Write("keep me", Path.Combine(busyPlace, "own.txt"));
            var clashing = Manual(mover, manual, busyPlace, volume);
            ExpectError("возврат в непустую папку отклоняется", () => mover.Restore(clashing, deleteArchive: false), ex => IsMove(ex, MoveErrorKind.AlreadyExists));
            Check(Read(Path.Combine(busyPlace, "own.txt")) == "keep me", "содержимое непустой папки не тронуто");
            ExpectError("ручная запись с возвратом в ~\\.ssh отклоняется",
                        () => mover.ImportRecord(manual, Path.Combine(rules.Home, @".ssh\keys"), originalRemoved: true), ex => IsMove(ex, MoveErrorKind.UnsafeRecord));
            ExpectError("ручная запись на несуществующий архив отклоняется",
                        () => mover.ImportRecord(Path.Combine(disk.Root, "nope"), Path.Combine(rules.Home, @"Downloads\nope"), originalRemoved: true),
                        ex => IsMove(ex, MoveErrorKind.UnsafeRecord));
            ExpectError("ручная запись с архивом на системном диске отклоняется",
                        () => mover.ImportRecord(Room("not-external"), Path.Combine(rules.Home, @"Downloads\x"), originalRemoved: true),
                        ex => IsMove(ex, MoveErrorKind.UnsafeRecord));

            var restored = mover.Restore(record, deleteArchive: true).Record;
            Check(Attributes(victim) == victimAttributes, "подделанный список атрибутов не изменил файл вне папки");
            Check(restored.Restored, "возврат отмечен");
            Check(Read(Path.Combine(source, @"data\big.txt"))?.Length == 300_000, "данные вернулись");
            Check(Has(Path.Combine(source, "run.cmd"), FileAttributes.ReadOnly) && Has(Path.Combine(source, @"data\hidden.txt"), FileAttributes.Hidden),
                  "атрибуты «только чтение» и «скрытый» вернулись");
            Check(Has(Path.Combine(source, @"data\big.txt"), FileAttributes.Hidden) && !Has(Path.Combine(source, @"data\big.txt"), FileAttributes.System),
                  "из подделанного списка «системный» не поставлен");
            Check(!Exists(target) && !Exists(SafeMover.ChecksumPath(target)) && !Exists(SafeMover.ModesPath(target)), "архив и его спутники удалены после возврата");
            Check(Journal.Records(volume).First(r => r.Id == record.Id).Restored, "возврат записан в журнал на диске");
        });

        Section("Возврат данных: архивом пользовались", () =>
        {
            var volume = SharedExFat.Info;
            var rules = new SafetyRules(Room("home-restore"));
            var mover = new SafeMover(rules);
            var source = Path.Combine(rules.Home, @"Downloads\models");
            Write("веса", Path.Combine(source, "a.bin"));
            Write("ещё веса", Path.Combine(source, @"sub\b.bin"));
            Write("@echo hi\r\n", Path.Combine(source, "run.cmd"));
            // Человек выбрал значок и вид папки — это и лежит в desktop.ini.
            Write("вид вложенной папки", Path.Combine(source, @"sub\desktop.ini"));

            var plan = mover.Plan(source, volume);
            // Между планом и переносом человек открыл папку в Проводнике, и тот записал свой desktop.ini.
            Write("вид корневой папки", Path.Combine(source, "desktop.ini"));
            Write("late", Path.Combine(source, "late.txt"));
            ExpectError("настоящий новый файл по-прежнему останавливает перенос", () => mover.Execute(plan, deleteOriginal: true, acceptCautions: true),
                        ex => IsMove(ex, MoveErrorKind.ContentMismatch));
            File.Delete(Path.Combine(source, "late.txt"));

            var record = mover.Execute(plan, deleteOriginal: true, acceptCautions: true);
            var target = record.ArchivedPath;
            Check(!Exists(source), "появившийся desktop.ini перенос не сорвал, оригинал удалён после сверки");
            Check(Exists(Path.Combine(target, @"sub\desktop.ini")), "desktop.ini человека уехал в архив, а не пропал вместе с оригиналом");
            Check(Exists(Path.Combine(target, "desktop.ini")), "поздний desktop.ini тоже скопирован");
            Check(!Exists(Path.Combine(target, ".offload-lock")), "метка идущего копирования снята и в архив не попала");

            // Дальше архивом пользуются: так и задумано для того, чему можно указать новый путь.
            File.WriteAllText(Path.Combine(target, "a.bin"), "новые веса");
            Write("сам положил", Path.Combine(target, @"sub\c.bin"));
            var used = mover.Restore(record, deleteArchive: false);
            Check(used.Record.Restored, "возврат изменённого архива состоялся, а не отказал");
            Check(used.Notes.Any(n => n.Contains("изменилось файлов: 1") && n.Contains("a.bin")), $"об изменившемся файле сказано оговоркой: {string.Join(" | ", used.Notes)}");
            Check(used.Notes.Any(n => n.Contains("появилось 1 файлов") && n.Contains(@"sub\c.bin")), "о подложенном в архив файле сказано оговоркой");
            Check(used.Notes.Any(n => n.Contains("сверено 2 файлов из 4")), "сказано, сколько файлов сверено со списком переноса и сколько всего в архиве");
            Check(Read(Path.Combine(source, "a.bin")) == "новые веса", "вернулось то, что лежит в архиве сейчас");
            Check(Exists(Path.Combine(source, @"sub\c.bin")), "подложенный в архив файл тоже вернулся");
            Check(used.NeedsAttention, "расхождение с архивом помечено как то, на что стоит посмотреть");

            // Второй возврат — уже без списка атрибутов рядом с архивом: так выглядит перенос, сделанный руками.
            FileSystem.DeleteTree(source);
            if (Exists(SafeMover.ModesPath(target))) File.Delete(SafeMover.ModesPath(target));

            // Остатки прерванных копирований в том же каталоге, куда идёт возврат.
            var downloads = Paths.Parent(source);
            var live = Partial(downloads, "live", Environment.ProcessId);
            var dead = Partial(downloads, "dead", DeadPid());
            var foreign = Partial(downloads, "foreign", DeadPid(), host: "другой-пк");
            var forgotten = Partial(downloads, "forgotten", Environment.ProcessId, DateTime.UtcNow.AddDays(-3));
            var old = Partial(downloads, "old", rootDate: DateTime.UtcNow.AddDays(-3));
            var young = Partial(downloads, "young", rootDate: DateTime.UtcNow);

            var strict = mover.Restore(record, deleteArchive: false);
            Check(Exists(live), "чужое идущее копирование не тронуто, хотя по дате выглядит заброшенным");
            Check(!Exists(dead), "остаток процесса, которого нет, убран");
            Check(Exists(foreign), "свежая метка другого компьютера бережётся: там может идти копирование");
            Check(!Exists(forgotten), "метка, которую сутками не обновляли, остатка не спасает");
            Check(!Exists(old), "старый остаток без метки убран");
            Check(Exists(young), "свежий остаток без метки не тронут");
            Check(strict.Record.Restored && Read(Path.Combine(source, @"sub\b.bin")) == "ещё веса", "без списка атрибутов данные вернулись");
            Check(!Has(Path.Combine(source, "run.cmd"), FileAttributes.Hidden | FileAttributes.System | FileAttributes.ReadOnly),
                  "без списка атрибутов файлы вернулись обычными — не скрытыми и не системными");
            Check(InheritsOnly(source), "права на корень возвращённого — унаследованы, а не принесены с диска");
        });

        Section("Возврат данных: архив удалить не удалось", () =>
        {
            var volume = SharedNtfs.Info;
            var rules = new SafetyRules(Room("home-keep"));
            var mover = new SafeMover(rules);

            // Обычный случай: архивом не пользовались. Оговорка про сверенное есть всегда, но тревожить ею незачем.
            var intact = Path.Combine(rules.Home, @"Downloads\intact");
            Write("раз", Path.Combine(intact, "one.txt"));
            Write("два", Path.Combine(intact, "two.txt"));
            var moved = mover.Execute(mover.Plan(intact, volume), deleteOriginal: true, acceptCautions: true);
            var clean = mover.Restore(moved, deleteArchive: true);
            Check(!clean.NeedsAttention, $"нетронутый архив вернулся без поводов для тревоги: {string.Join(" | ", clean.Notes)}");
            Check(clean.Notes.SequenceEqual(["Со списком, записанным при переносе, сверено 2 файлов из 2 в архиве."]),
                  $"сказано, сколько файлов сверено со списком переноса: {string.Join(" | ", clean.Notes)}");
            Check(Read(Path.Combine(intact, "two.txt")) == "два", "данные вернулись");

            // Файл архива держит сам OffLoadAI (так же держит антивирус или индексатор): Windows не даёт его удалить.
            var archived = Path.Combine(SharedNtfs.Root, @"Archive\stuff");
            Write("данные", Path.Combine(archived, "file.txt"));
            var record = Manual(mover, archived, Path.Combine(rules.Home, @"Downloads\stuff"), volume);
            RestoreOutcome outcome;
            using (new FileStream(Path.Combine(archived, "file.txt"), FileMode.Open, FileAccess.Read, FileShare.Read))
                outcome = mover.Restore(record, deleteArchive: true);
            Check(outcome.Record.Restored, "возврат засчитан, хотя архив остался на диске");
            Check(outcome.NeedsAttention, "оставшийся архив помечен как то, на что стоит посмотреть");
            Check(outcome.Notes.Any(n => n.Contains("архив удалить не удалось")), $"о неудавшемся удалении архива сказано оговоркой, а не ошибкой: {string.Join(" | ", outcome.Notes)}");
            Check(Read(Path.Combine(rules.Home, @"Downloads\stuff\file.txt")) == "данные", "данные на компьютере и сверены");
            Check(Exists(Path.Combine(archived, "file.txt")), "архив остался лежать — о нём и сказано в оговорке");

            // Архив держит другая программа: удаление даже не начинается, данные на компьютере.
            var held = Path.Combine(SharedNtfs.Root, @"Archive\held");
            Write("занят", Path.Combine(held, "file.txt"));
            var heldRecord = Manual(mover, held, Path.Combine(rules.Home, @"Downloads\held"), volume);
            RestoreOutcome heldOutcome;
            using (new Holder(Path.Combine(held, "file.txt")))
                heldOutcome = mover.Restore(heldRecord, deleteArchive: true);
            Check(heldOutcome.Record.Restored && heldOutcome.NeedsAttention && heldOutcome.Notes.Any(n => n.Contains("открыты")),
                  $"архив, открытый в другой программе, не удаляется, и сказано почему: {string.Join(" | ", heldOutcome.Notes)}");
            Check(Read(Path.Combine(held, "file.txt")) == "занят" && Read(Path.Combine(rules.Home, @"Downloads\held\file.txt")) == "занят",
                  "архив цел, данные на компьютере");

            // Перенос файла, открытого другой программой, останавливается и после плана: план мог часами ждать подтверждения.
            var busy = Path.Combine(rules.Home, @"Downloads\busy-later");
            Write("открою потом", Path.Combine(busy, "doc.txt"));
            var busyPlan = mover.Plan(busy, volume);
            using (new Holder(Path.Combine(busy, "doc.txt")))
                ExpectError("файл, открытый после проверки, останавливает перенос", () => mover.Execute(busyPlan, deleteOriginal: true, acceptCautions: true),
                            ex => IsMove(ex, MoveErrorKind.Blocked) && ex.Message.Contains("открыты"));
            Check(Read(Path.Combine(busy, "doc.txt")) == "открою потом" && !Exists(busyPlan.Target), "оригинал на месте, на диске ничего не появилось");
        });

        Section("Сообщения после возврата", () =>
        {
            var volume = SharedExFat.Info;
            var rules = new SafetyRules(Room("home-ui"));
            var mover = new SafeMover(rules);
            // Возврат переноса, сделанного мимо OffLoadAI: списка сумм рядом с архивом нет. Без оговорки человек видел бы
            // «каждый файл сверен по SHA-256» — при том что сверить архив было не с чем.
            var manual = Path.Combine(SharedExFat.Root, @"Вручную\папка");
            Write("данные", Path.Combine(manual, "file.txt"));
            var imported = Manual(mover, manual, Path.Combine(rules.Home, @"Downloads\папка"), volume);
            var outcome = mover.Restore(imported, deleteArchive: false);
            Check(outcome.Notes.Count > 0 && outcome.Notes.Any(n => n.Contains("нет списка контрольных сумм")),
                  "возврат без списка сумм возвращает оговорки, а не молчаливый успех");
            Check(outcome.Notes.All(n => n.Length > 0), "оговорки не пустые — плашке есть что показать");

            // Текст отмены обещает, что архив на диске не тронут.
            var other = Path.Combine(SharedExFat.Root, @"Вручную\вторая");
            Write("данные", Path.Combine(other, "file.txt"));
            var second = Manual(mover, other, Path.Combine(rules.Home, @"Downloads\вторая"), volume);
            ExpectError("отменённый возврат заканчивается отменой, а не тихим успехом", () => mover.Restore(second, deleteArchive: true, isCancelled: () => true),
                        ex => ex is OperationCanceledException);
            Check(Exists(Path.Combine(other, "file.txt")), "после отмены архив на диске на месте — как и написано в сообщении");
            Check(!Exists(Path.Combine(rules.Home, @"Downloads\вторая")), "после отмены на месте оригинала ничего не создано");
            Check(!Directory.GetDirectories(Path.Combine(rules.Home, "Downloads")).Any(d => Paths.Name(d).StartsWith(".offload-partial-")),
                  "после отмены временной папки не осталось");
            // Отмена посреди копирования: первые файлы уже скопированы — всё равно ничего не остаётся.
            int calls = 0;
            Write(new string('z', 1 << 20), Path.Combine(other, "big.bin"));
            var third = Manual(mover, other, Path.Combine(rules.Home, @"Downloads\третья"), volume);
            ExpectError("отмена посреди копирования", () => mover.Restore(third, deleteArchive: true, isCancelled: () => ++calls > 6),
                        ex => ex is OperationCanceledException);
            Check(!Exists(Path.Combine(rules.Home, @"Downloads\третья")) && Exists(Path.Combine(other, "big.bin")), "после отмены посреди копирования архив цел, оригинала нет");
        });
    }
}
