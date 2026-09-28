using System.Text;
using System.Text.Json;
using Offload.Core;
using static Offload.Checks.Harness;
using static Offload.Checks.Helpers;

namespace Offload.Checks;

// Низкий уровень: запуск программ, хеши, журнал, размеры папок, формат, память, Корзина.
static partial class All
{
    /// <summary>Сама программа проверок в роли подопытной внешней программы: печатает аргументы, отдаёт stdin, спит.</summary>
    static string? SelfTool => Environment.ProcessPath is { } path && Path.GetFileNameWithoutExtension(path).Equals("Offload.Checks", StringComparison.OrdinalIgnoreCase)
        ? path : null;

    static void ChecksRunner()
    {
        Section("Запуск программ и хеши", () =>
        {
            Check(Paths.Same(Runner.Locate("powershell"), Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe")),
                  "PowerShell берётся из System32");
            Check(Runner.Locate(@"..\bin\sh") == null && Runner.Locate(@"C:\evil\docker") == null && Runner.Locate("docker:x") == null,
                  "путь вместо имени программы отклоняется");
            Check(Runner.Locate("notepad") == null, "программа не из списка известных не ищется вовсе — PATH не используется");
            Check(!Runner.ChildEnvironment["PATH"].Split(';').Any(p => p.Contains(@"\Temp", StringComparison.OrdinalIgnoreCase)),
                  "в PATH запускаемых программ нет временных папок");
            // Свои настройки человека не меняют того, что делают запущенные программы: restic не берёт чужой пароль
            // вместо введённого в OffLoadAI, Claude Code не платит по ключу API и не уходит в другое облако.
            string[] foreign = ["RESTIC_PASSWORD", "RESTIC_REPOSITORY", "ANTHROPIC_API_KEY", "CLAUDE_CODE_USE_BEDROCK"];
            var saved = foreign.Append("DOCKER_CONTEXT").ToDictionary(name => name, Environment.GetEnvironmentVariable);
            foreach (var name in foreign) Environment.SetEnvironmentVariable(name, "чужое");
            Environment.SetEnvironmentVariable("DOCKER_CONTEXT", "desktop-linux");
            try
            {
                var env = Runner.ChildEnvironment;
                Check(!foreign.Any(env.ContainsKey), "свои RESTIC_PASSWORD, ANTHROPIC_API_KEY и прочие настройки человека запускаемым программам не передаются");
                Check(env.TryGetValue("DOCKER_CONTEXT", out var context) && context == "desktop-linux", "куда подключаться Docker — передаётся");
                Check(new[] { "SystemRoot", "TEMP", "USERPROFILE", "LOCALAPPDATA" }.All(name => Environment.GetEnvironmentVariable(name) == null || env.ContainsKey(name)),
                      "каталог Windows, временная папка и профиль — передаются");
            }
            finally
            {
                foreach (var (name, value) in saved) Environment.SetEnvironmentVariable(name, value);
            }

            var abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
            Check(FileHasher.Sha256(Encoding.UTF8.GetBytes("abc")) == abc, "SHA-256 по эталону");
            var file = Path.Combine(Scratch, "abc.txt");
            File.WriteAllBytes(file, Encoding.UTF8.GetBytes("abc"));
            Check(FileHasher.Sha256(file) == abc, "SHA-256 файла по эталону (чтение мимо кеша)");
            var big = Path.Combine(Scratch, "big.bin");
            var data = new byte[FileHasher.ChunkSize * 2 + 12345];
            new Random(7).NextBytes(data);
            File.WriteAllBytes(big, data);
            Check(FileHasher.Sha256(big) == FileHasher.Sha256(data), "SHA-256 файла из нескольких кусков по 4 МБ совпадает с хешем в памяти");
            Check(FileHasher.Sha256Edges(file, 3, 64 * 1024) == abc, "короткий файл по краям читается целиком");

            if (SelfTool is not { } self)
            {
                Console.WriteLine("  (программа проверок запущена не своим exe — проверки аргументов пропущены)");
                return;
            }
            Runner.LocateOverride = name => name == "offload-self" ? self : null;
            try
            {
                var pwned = Path.Combine(Scratch, "pwned.txt");
                var hostile = $"a b; & echo x > \"{pwned}\" | calc %PATH% ^& $(id) `id` 'q' \"quoted\" trailing\\";
                var echoed = Runner.Check("offload-self", ["--echo-args", hostile, "", "второй аргумент"]);
                Check(echoed.Output == hostile + "\n\n" + "второй аргумент\n", $"аргументы не интерпретируются оболочкой: «{echoed.Output}»");
                Check(!File.Exists(pwned), "подстановка команды не выполнилась");
                Check(Runner.Check("offload-self", ["--cat"], stdin: Encoding.UTF8.GetBytes("секрет")).Output == "секрет", "stdin передаётся программе");
                var password = Environment.GetEnvironmentVariable("RESTIC_PASSWORD");
                Environment.SetEnvironmentVariable("RESTIC_PASSWORD", "чужой пароль");
                try
                {
                    Check(Runner.Check("offload-self", ["--env", "RESTIC_PASSWORD"]).Output == "", "свой RESTIC_PASSWORD человека до запущенной программы не доходит");
                    Check(Runner.Check("offload-self", ["--env", "SystemRoot"]).Output.Length > 0, "каталог Windows до запущенной программы доходит");
                }
                finally { Environment.SetEnvironmentVariable("RESTIC_PASSWORD", password); }
                ExpectError("зависшая программа прерывается по таймауту",
                            () => Runner.Run("offload-self", ["--sleep", "10"], timeout: TimeSpan.FromMilliseconds(500)),
                            ex => ex is RunnerException { Kind: RunnerErrorKind.TimedOut });
                ExpectError("ненулевой код — ошибка с кодом", () => Runner.Check("offload-self", ["--exit", "3"]),
                            ex => ex is RunnerException { Kind: RunnerErrorKind.Failed, Status: 3 });
                var lines = new List<string>();
                var streamed = Runner.Stream("offload-self", ["--echo-args", "раз", "два"], onLine: lines.Add);
                Check(streamed.Succeeded && lines.SequenceEqual(["раз", "два"]), $"построчный вывод доходит по мере появления ({string.Join("|", lines)})");
                ExpectError("построчный запуск останавливается по отмене",
                            () => Runner.Stream("offload-self", ["--sleep", "10"], isCancelled: () => true), ex => ex is OperationCanceledException);
            }
            finally { Runner.LocateOverride = null; }
        });
    }

    static void ChecksJournal()
    {
        Section("Журнал", () =>
        {
            var mount = Room("journal-disk") + "\\";
            var volume = Fake("exfat", mount: mount, name: "J");
            var manifest = Journal.ManifestPath(volume);
            var first = new MoveRecord { OriginalPath = Path.Combine(Scratch, @"j-home\Downloads\one"), ArchivedPath = Path.Combine(mount, @"Offload\Downloads\one"),
                                         VolumeName = "J", Files = 1, Bytes = 10 };
            Journal.Save(first, volume);
            Check(Journal.Records(volume).Count == 1, "запись попала в журнал на диске");
            Check(Journal.LocalRecords().Any(r => r.Id == first.Id), "и в локальную копию журнала");

            Write("{это не журнал", manifest);
            var second = first with { Id = Guid.NewGuid(), OriginalPath = Path.Combine(Scratch, @"j-home\Downloads\two"),
                                      ArchivedPath = Path.Combine(mount, @"Offload\Downloads\two") };
            Journal.Save(second, volume);
            var afterBreak = Journal.Records(volume);
            Check(afterBreak.Count == 2, $"испорченный журнал восстановлен из второй копии, а не начат с нуля ({afterBreak.Count})");
            var broken = Directory.GetFiles(Paths.Parent(manifest), "manifest.json.broken-*");
            Check(broken.Length == 1, $"испорченный файл отложен рядом, а не затёрт ({broken.Length})");

            // Формат — тот же, что у версии для Mac: даты без долей секунды, UUID заглавными.
            var json = File.ReadAllText(manifest);
            Check(json.Contains(first.Id.ToString("D").ToUpperInvariant()) && json.Contains("\"originalPath\""), "журнал записан в формате версии для Mac");
            var fromMac = """
                [{"id":"0F8C5B0E-1111-4E4E-9A9A-222233334444","date":"2026-09-26T20:23:14Z","originalPath":"/Users/q/Downloads/x",
                  "archivedPath":"/Volumes/SSD/Offload/Downloads/x","volumeName":"SSD","files":1,"bytes":5,"originalRemoved":true,"restored":false}]
                """;
            var macPath = Path.Combine(Scratch, "mac-manifest.json");
            File.WriteAllText(macPath, fromMac);
            var macRecords = Journal.Load(macPath);
            Check(macRecords.Count == 1 && macRecords[0].IsFromMac && macRecords[0].OriginalRemoved, "журнал, записанный на Mac, читается");
            Directory.CreateDirectory(Path.Combine(mount, @"Offload\Downloads\x"));
            Check(Journal.Rebase(macRecords[0], volume).ArchivedPath == Path.Combine(mount, @"Offload\Downloads\x"),
                  "путь архива из записи Mac переписан на этот диск, раз архив здесь");
            var otherLetter = first with { ArchivedPath = @"Z:\Offload\Downloads\x" };
            Check(Journal.Rebase(otherLetter, volume).ArchivedPath == Path.Combine(mount, @"Offload\Downloads\x"),
                  "буква диска сменилась — запись всё равно находит архив");
            var absent = first with { ArchivedPath = @"Z:\Offload\Downloads\нет такого" };
            Check(Journal.Rebase(absent, volume).ArchivedPath == absent.ArchivedPath, "архива на этом диске нет — путь не переписывается");
            Check(Journal.VolumeRelative("/Volumes/SSD") == null && Journal.VolumeRelative(@"\\server\share\x") == null,
                  "путь без папки на диске и сетевой путь не превращаются в путь на этом диске");

            // Журнал на внешнем диске: на его месте может оказаться что угодно.
            var room = Room("journal-traps");
            Directory.CreateDirectory(Path.Combine(room, "folder.json"));
            Check(Journal.State(Path.Combine(room, "folder.json")).kind == Journal.StateKind.Broken, "папка на месте журнала — «не читается»");
            Junction(Path.Combine(room, "junction.json"), room);
            Check(Journal.State(Path.Combine(room, "junction.json")).kind == Journal.StateKind.Broken, "точка соединения на месте журнала — «не читается»");
            var huge = Path.Combine(room, "huge.json");
            using (var stream = new FileStream(huge, FileMode.CreateNew)) stream.SetLength(Journal.MaxManifestBytes + 1L);
            Check(Journal.State(huge).kind == Journal.StateKind.Broken, "огромный журнал — «не читается», а не чтение 20 МБ в память");
            Write("null", Path.Combine(room, "null.json"));
            Check(Journal.State(Path.Combine(room, "null.json")).kind == Journal.StateKind.Broken, "журнал «null» — испорченный, без падения");
            Check(Journal.State(Path.Combine(room, "нет.json")).kind == Journal.StateKind.Missing, "нет журнала — «нет», а не «испорчен»");

            if (CanSymlink)
            {
                // Ссылка на месте журнала ведёт на файл с компьютера: запись журнала не должна его затереть.
                var victim = Path.Combine(room, "victim.txt");
                Write("не журнал, а чужой файл", victim);
                var trapMount = Room("journal-trap-disk") + "\\";
                var trapVolume = Fake("ntfs", mount: trapMount, name: "T");
                FileLink(Journal.ManifestPath(trapVolume), victim);
                Journal.Save(first with { Id = Guid.NewGuid(), ArchivedPath = Path.Combine(trapMount, @"Offload\x") }, trapVolume);
                Check(Read(victim) == "не журнал, а чужой файл", "файл за ссылкой на месте журнала не затёрт");
                Check(Journal.Records(trapVolume).Count == 1, "журнал записан заново рядом, а ссылка отложена");
            }
        });
    }

    static void ChecksSpace()
    {
        Section("Размеры папок", () =>
        {
            var home = Room("home-sizes");
            var folder = Path.Combine(home, "sized");
            Directory.CreateDirectory(folder);
            File.WriteAllBytes(Path.Combine(folder, "blob"), Enumerable.Repeat((byte)0x5a, 5 << 20).ToArray());
            Junction(Path.Combine(folder, "loop"), home);
            var rules = new SafetyRules(home);
            var item = SpaceScanner.Measure(folder, rules);
            Check(item.Bytes >= 5 << 20 && item.Bytes < 6 << 20, $"размер папки — занятое на диске, без захода за точку соединения ({item.Bytes} байт)");
            Check(!item.AccessDenied && item.IsDirectory && item.Verdict == Verdict.Safe, "папка читается и разрешена к переносу");
            Write("", Path.Combine(home, "desktop.ini"));
            Write("x", Path.Combine(home, "._x"));
            Check(SpaceScanner.Children(home).Select(Paths.Name).SequenceEqual(["sized"]), "служебные файлы Проводника и «._» в обзоре не показываются");
            var sparse = Path.Combine(home, @"sparse\disk.img");
            Sparse(sparse, 1L << 30);
            Check(SpaceScanner.Measure(Paths.Parent(sparse), rules).Bytes < 16L << 20, "разрежённый файл считается по занятому месту");
        });
    }

    static void ChecksFormat()
    {
        Section("Формат размеров и дат", () =>
        {
            Check(Format.Bytes(4_810_000_000) == "4.8 ГБ", $"до 100 — один знак: {Format.Bytes(4_810_000_000)}");
            Check(Format.Bytes(24_500_000_000) == "24.5 ГБ", "24.5 ГБ");
            Check(Format.Bytes(168_010_000_000) == "168 ГБ", $"от 100 — целые: {Format.Bytes(168_010_000_000)}");
            Check(Format.Bytes(612_000_000_000) == "612 ГБ", "612 ГБ");
            Check(Format.Bytes(9_000_000_000) == "9 ГБ", "ровное число — без «.0»");
            Check(Format.Bytes(999_960_000) == "1 ГБ", $"999.96 МБ округляется до 1 ГБ, а не «1000 МБ»: {Format.Bytes(999_960_000)}");
            Check(Format.Bytes(270_000) == "270 КБ", "270 КБ");
            Check(Format.Bytes(512) == "512 Б" && Format.Bytes(0) == "0 Б", "байты — целыми");
            Check(Format.Bytes(1_000_000_000_000) == "1 ТБ", "1 ТБ");
            Check(Format.Bytes(-64_000_000) == "−64 МБ", "отрицательное — со знаком минус");
            Check(Format.Memory(16UL << 30) == "16 ГБ" && Format.Memory(1_148_846_080) == "1.1 ГБ", "память — двоичными единицами");
            var now = new DateTime(2026, 9, 27, 12, 0, 0, DateTimeKind.Utc);
            Check(Format.Relative(now.AddSeconds(30), now) == "сейчас", "дата чуть в будущем — «сейчас»");
            Check(Format.Relative(now.AddMinutes(-5), now) == "5 минут назад" && Format.Relative(now.AddMinutes(-1), now) == "1 минуту назад", "минуты");
            Check(Format.Relative(now.AddHours(-3), now) == "3 часа назад", "часы");
            Check(Format.Relative(now.AddDays(-1), now) == "вчера" && Format.Relative(now.AddDays(-2), now) == "позавчера", "вчера и позавчера");
            Check(Format.Relative(now.AddDays(-5), now) == "5 дней назад", "дни");
            Check(Format.Relative(now.AddDays(-400), now) == "1 год назад" && Format.Relative(now.AddDays(-800), now) == "2 года назад", "годы");
            Check(Plural.Ru(1, "файл", "файла", "файлов") == "файл" && Plural.Ru(22, "файл", "файла", "файлов") == "файла"
                  && Plural.Ru(11, "файл", "файла", "файлов") == "файлов" && Plural.Ru(112, "файл", "файла", "файлов") == "файлов", "склонение по числу");
        });
    }

    static void ChecksMemory()
    {
        Section("Память", () =>
        {
            var snapshot = MemoryStats.Snapshot();
            Check(snapshot.PhysicalBytes > 0, "объём памяти известен");
            Check(snapshot.SwapUsedBytes <= snapshot.SwapTotalBytes, "файл подкачки: занято не больше, чем всего");
            Check(snapshot.Apps.Count > 0, "видны программы");
            Check(snapshot.Apps.Zip(snapshot.Apps.Skip(1)).All(p => p.First.Bytes >= p.Second.Bytes), "программы — по убыванию памяти");
            Check(MemoryStats.AppName("vmmem", null) == MemoryStats.VirtualMachinesName && MemoryStats.AppName("VmmemWSL", null) == MemoryStats.VirtualMachinesName
                  && MemoryStats.AppName("VBoxHeadless", null) == MemoryStats.VirtualMachinesName, "виртуальные машины распознаются");
            var notepad = Path.Combine(Environment.SystemDirectory, "notepad.exe");
            if (File.Exists(notepad))
                Check(!MemoryStats.AppName("notepad", notepad).Contains("Windows"), $"у системной программы не «Операционная система Windows»: {MemoryStats.AppName("notepad", notepad)}");
            Check(MemoryStats.AppName("gone", Path.Combine(Scratch, "нет.exe")) == "gone", "исчезнувший файл программы — имя процесса");
            var heavy = snapshot with
            {
                PhysicalBytes = 16UL << 30, SwapUsedBytes = 12UL << 30, Uptime = TimeSpan.FromDays(9), Pressure = MemoryPressure.Critical,
                Apps = [new AppMemory(MemoryStats.VirtualMachinesName, 6UL << 30, 2), new AppMemory("Google Chrome", 5UL << 30, 30)],
            };
            var advice = MemoryStats.Advice(heavy);
            Check(advice.Any(a => a.Contains("Перезагрузите")) && advice.Any(a => a.Contains("wsl --shutdown")) && advice.Any(a => a.Contains("вкладки")),
                  $"советы: перезагрузка, WSL и вкладки ({advice.Count})");
            var calm = heavy with { SwapUsedBytes = 0, Pressure = MemoryPressure.Normal, Apps = [] };
            Check(MemoryStats.Advice(calm).Count == 0, "всё спокойно — советов нет");
        });
    }

    static void ChecksTrash()
    {
        Section("Разбор: в Корзине — тот самый файл", () =>
        {
            var folder = Room("trash-identity");
            var original = Path.Combine(folder, "отчёт.pdf");
            var moved = Path.Combine(folder, "в Корзине.pdf");
            Write("то, что выбросил разбор", original);
            var identity = FileIdentity.Of(original);
            Check(identity != null, "у файла есть номер");
            File.Move(original, moved);
            Check(FileIdentity.Of(moved) == identity, "перенос на том же диске номер файла сохраняет");
            File.Delete(moved);
            Write("другой файл, выброшенный потом с тем же именем", moved);
            Check(FileIdentity.Of(moved) != identity, "другой файл по тому же пути — другой номер: удалить насовсем его нельзя");
            Check(FileIdentity.Of(Path.Combine(folder, "нет такого")) == null, "нет файла — нет и номера");

            // Настоящая Корзина: туда уходит только наш пробный файл, и он же оттуда возвращается и удаляется насовсем.
            var probe = Path.Combine(folder, $"offload-проверка-{Guid.NewGuid():N}.txt");
            Write("пробный файл проверок OffLoadAI", probe);
            var probeIdentity = FileIdentity.Of(probe);
            (string path, FileIdentity? identity) trashed;
            try { trashed = RecycleBin.Trash(probe); }
            catch (RecycleBin.RecycleException ex)
            {
                Console.WriteLine($"  (Корзина в этом сеансе недоступна: {ex.Message} — проверка пропущена)");
                return;
            }
            Check(!Exists(probe) && Exists(trashed.path), $"файл ушёл в Корзину: {trashed.path}");
            Check(trashed.path.Contains("$Recycle.Bin", StringComparison.OrdinalIgnoreCase) && Paths.Name(trashed.path).StartsWith("$R"),
                  "известно, где он лежит в Корзине");
            Check(FileIdentity.Of(trashed.path) == probeIdentity && trashed.identity == probeIdentity, "в Корзине — тот самый файл");
            RecycleBin.Restore(trashed.path, probe);
            Check(Read(probe) == "пробный файл проверок OffLoadAI" && !Exists(trashed.path), "возвращён на прежнее место");
            Check(!Exists(Path.Combine(Paths.Parent(trashed.path), "$I" + Paths.Name(trashed.path)[2..])), "запись Корзины о нём убрана");
            var again = RecycleBin.Trash(probe);
            RecycleBin.Erase(again.path);
            Check(!Exists(again.path) && !Exists(probe), "удалён насовсем — только он");
            Check(RecycleBin.Capacity(folder) is > 0, "предел Корзины на диске известен");
        });
    }
}
