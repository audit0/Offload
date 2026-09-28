using System.Text;
using Offload.Core;
using static Offload.Checks.Harness;
using static Offload.Checks.Helpers;

namespace Offload.Checks;

// Восстановление из бэкапа restic: разбор вывода — всегда, настоящее хранилище — если restic установлен.
static partial class All
{
    static void ChecksCloudRestore()
    {
        Section("Из iCloud: разбор вывода restic", () =>
        {
            var snapshots = CloudRestore.ParseSnapshots(Encoding.UTF8.GetBytes("""
                [{"time":"2026-09-26T20:23:14.99383+03:00","tree":"t","paths":["/Volumes/SSD"],"hostname":"mac","tags":["ssd"],
                  "summary":{"total_bytes_processed":160181592064},"id":"c00b9807aaaa","short_id":"c00b9807"},
                 {"time":"2026-09-26T18:44:07.123456789+03:00","paths":["/a/b","/a/c"],"hostname":"mac","id":"3e18663fbbbb","short_id":"3e18663f"},
                 {"time":"2026-09-25T10:00:00+03:00","paths":["C:\\Users\\q\\Documents"],"hostname":"pc","id":"99aa00bbcc11"}]
                """));
            Check(snapshots.Count == 3, "три снимка");
            Check(snapshots[0].TotalBytes == 160_181_592_064, "размер снимка из summary");
            Check(snapshots[1].TotalBytes == null, "без summary размер неизвестен");
            Check(snapshots[0].Root == "/Volumes/SSD", "корень снимка с одним путём");
            Check(snapshots[1].Root == "/a", "корень снимка с двумя путями — общая папка");
            Check(snapshots[2].ShortId == "99aa00bb", "короткий номер снимка — из длинного, если его нет");
            Check(snapshots[2].Root == "/C/Users/q/Documents", $"снимок с Windows: корень — как в дереве restic, «/C/…» ({snapshots[2].Root})");
            Check(CloudRestore.ParseTime("2026-09-26T18:44:07.123456789+03:00") == new DateTime(2026, 9, 26, 15, 44, 7, DateTimeKind.Utc),
                  "время с наносекундами читается и переводится во всемирное");
            Check(CloudRestore.ParseTime("вчера") == null && CloudRestore.ParseTime(null) == null, "мусор вместо времени — неизвестно");
            Check(CloudRestore.CommonDirectory(["/Volumes/SSD", "/Users/q"]) == "/", "разные диски — корень");
            Check(CloudRestore.ParseSnapshots(Encoding.UTF8.GetBytes("не json")).Count == 0, "мусор вместо списка снимков — пустой список, без падения");

            var entries = CloudRestore.ParseEntries("""
                {"time":"2026-09-26T20:23:14+03:00","paths":["/Volumes/SSD"],"id":"x","struct_type":"snapshot","message_type":"snapshot"}
                {"name":"SSD","type":"dir","path":"/Volumes/SSD","mtime":"2026-09-26T16:54:14.1+03:00","struct_type":"node"}
                {"name":"a.txt","type":"file","path":"/Volumes/SSD/a.txt","size":12,"mtime":"2026-09-26T16:54:14+03:00","struct_type":"node"}
                {"name":"dev","type":"chardev","path":"/Volumes/SSD/dev","struct_type":"node"}
                не json
                """);
            Check(entries.Count == 2, "строка снимка, устройства и мусор пропускаются");
            Check(entries[^1].Size == 12 && !entries[^1].IsDirectory && entries[^1].Name == "a.txt", "размер файла");
            Check(entries[0].IsDirectory && entries[0].Size == null, "у папки размера нет");

            var found = CloudRestore.ParseFind(Encoding.UTF8.GetBytes("""
                [{"matches":[{"path":"/src/x.pdf","type":"file","size":5},{"path":"/src/d","type":"dir"}],"hits":2,"snapshot":"s"}]
                """));
            Check(found.Select(e => e.Path).SequenceEqual(["/src/x.pdf", "/src/d"]), "поиск: совпадения всех снимков");

            var status = CloudRestore.ParseProgress("""{"message_type":"status","percent_done":0.25,"total_bytes":400,"bytes_restored":100}""");
            Check(status is { Fraction: 0.25, BytesDone: 100 }, "прогресс восстановления");
            Check(CloudRestore.ParseProgress("""{"message_type":"summary","total_bytes":400,"bytes_restored":400}""")?.Fraction == 1, "итог — 100 %");
            Check(CloudRestore.ParseProgress("не json") == null, "посторонние строки — не прогресс");
            Check(CloudRestore.ParseProblem("""{"message_type":"error","error":{"message":"read failed"},"during":"restore","item":"/a"}""") == "/a: read failed",
                  "ошибка с файлом (restic 0.17 и новее — JSON в stderr)");
            Check(CloudRestore.FailedItem(@"ignoring error for /Docs/big1.bin: StreamPack: open C:\r\data\ea\eaea: The system cannot find the file specified.")
                      is ("/Docs/big1.bin", @"StreamPack: open C:\r\data\ea\eaea: The system cannot find the file specified."),
                  "ошибка с файлом в restic 0.16 — текстом");
            Check(CloudRestore.FailedItem(@"Load(<data/eaeaae5b1e>, 17879973, 0) returned error, retrying after 264ms: open C:\r\x: not found") == null,
                  "повтор чтения — не ошибка с файлом");
            Check(CloudRestore.FailedItem("""{"message_type":"status","percent_done":0.5}""") == null
                  && CloudRestore.FailedItem("""{"message_type":"error","error":5,"item":7}""") is ("", "ошибка"),
                  "прогресс — не ошибка; поля не той формы — без исключения");
            Check(CloudRestore.Readable("""
                Load(<data/ea>, 1, 0) returned error, retrying after 264ms: open C:\r\data\ea\x: not found
                {"message_type":"error","error":{"message":"ciphertext verification failed"},"during":"restore","item":"/Docs/a.bin"}
                {"message_type":"exit_error","code":1,"message":"There were 1 errors"}
                """).SequenceEqual(["/Docs/a.bin: ciphertext verification failed", "There were 1 errors"]),
                  "сообщение об ошибке — по-человечески: без JSON и без повторов чтения");

            // Испорченное restic оставляет с дырами — его убираем. Но только обычный файл и только внутри папки восстановления.
            var target = Room("broken-restore");
            Write("испорчен", Path.Combine(target, @"Docs\big.bin"));
            Write("цел", Path.Combine(target, @"Docs\small.txt"));
            var outside = Path.Combine(Scratch, "outside.txt");
            Write("чужое", outside);
            CloudRestore.RemoveBroken("/Docs/big.bin", target);
            CloudRestore.RemoveBroken("/../outside.txt", target);
            CloudRestore.RemoveBroken("/Docs", target);
            Check(!File.Exists(Path.Combine(target, @"Docs\big.bin")), "испорченный файл убран");
            Check(File.Exists(Path.Combine(target, @"Docs\small.txt")), "целый рядом остался");
            Check(File.Exists(outside), "путь с «..» из вывода restic за папку не выходит");
            Check(Directory.Exists(Path.Combine(target, "Docs")), "папку с ошибкой (например, прав) не удаляем");

            var stall = @"Load(<data/a08d985582>, 1425, 57776523) returned error, retrying after 926.43089ms: read C:\Users\q\iCloudDrive\Бэкапы\ssd-restic\data\a0\a08d98: The cloud operation was unsuccessful.";
            Check(CloudRestore.StalledFile(stall) == @"C:\Users\q\iCloudDrive\Бэкапы\ssd-restic\data\a0\a08d98", "кусок, который ждёт iCloud");
            var macStall = "Load(<data/a08d985582>, 1425, 57776523) returned error, retrying after 926.43089ms: read /Users/q/Library/Mobile Documents/com~apple~CloudDocs/Бэкапы/ssd-restic/data/a0/a08d98: operation canceled";
            Check(CloudRestore.StalledFile(macStall) == "/Users/q/Library/Mobile Documents/com~apple~CloudDocs/Бэкапы/ssd-restic/data/a0/a08d98",
                  "и в строке с путём Mac");
            Check(CloudRestore.StalledFile("Fatal: wrong password") == null, "прочие ошибки — не ожидание iCloud");

            Check(CloudRestore.EscapePattern("a[1]*?.txt") == @"a\[1\]\*\?.txt", "спецсимволы шаблона экранируются");
            Check(CloudRestore.EscapePattern("обычное имя.pdf") == "обычное имя.pdf", "обычное имя не меняется");
            Check(CloudRestore.ParentDirectory("/Volumes") == "/", "родитель верхней папки — корень");
            Check(CloudRestore.Ancestors("/Volumes/SSD/Проекты").SequenceEqual(["/", "/Volumes", "/Volumes/SSD", "/Volumes/SSD/Проекты"]), "хлебные крошки");
            Check(CloudRestore.Ancestors("/").SequenceEqual(["/"]), "крошки корня");

            var repository = new CloudRestore.Repository(@"C:\repo");
            var (typedArguments, stdin) = CloudRestore.Invocation(["snapshots"], repository, new CloudRestore.Password.Typed("секрет"));
            Check(!typedArguments.Contains("секрет") && stdin != null && Encoding.UTF8.GetString(stdin) == "секрет",
                  "набранный пароль идёт только через stdin, в аргументах его нет");
            Check(typedArguments.Contains("--no-lock"), "хранилище только читается: --no-lock");
            Check(CloudRestore.Error(12, "", repository).Kind == CloudRestore.RestoreErrorKind.WrongPassword
                  && CloudRestore.Error(10, "", repository).Kind == CloudRestore.RestoreErrorKind.NotARepository
                  && CloudRestore.Error(1, "Fatal: wrong password or no key found", repository).Kind == CloudRestore.RestoreErrorKind.WrongPassword,
                  "коды и сообщения restic разбираются в понятные ошибки");
        });

        Section("Из iCloud: где искать хранилища", () =>
        {
            var root = Room("cloud-drive");
            var repository = Path.Combine(root, @"Бэкапы\ssd-restic");
            foreach (var folder in new[] { "keys", @"data\00", "snapshots" }) Directory.CreateDirectory(Path.Combine(repository, folder));
            Write("x", Path.Combine(repository, "config"));
            Write("x", Path.Combine(root, @"Документы\письмо.txt"));
            var fake = Path.Combine(root, @"Бэкапы\не-хранилище");
            Write("x", Path.Combine(fake, "config"));
            Check(CloudRestore.IsRepository(repository), "хранилище узнаётся по config, keys и data");
            Check(!CloudRestore.IsRepository(fake), "одного config мало");
            Check(CloudRestore.Discover(root).Select(r => r.Path).SequenceEqual([repository]), "найдено одно хранилище на втором уровне");
            Check(CloudRestore.Discover(root, 1).Count == 0, "глубже заданного не ищет");
            Check(CloudRestore.Discover(repository).Count == 1, "папка самого хранилища");
            var hidden = Path.Combine(root, "Скрытое");
            foreach (var folder in new[] { "keys", "data" }) Directory.CreateDirectory(Path.Combine(hidden, @"repo\" + folder));
            Write("x", Path.Combine(hidden, @"repo\config"));
            Add(hidden, FileAttributes.Hidden);
            Junction(Path.Combine(root, "Ссылка"), Path.Combine(root, "Бэкапы"));
            Check(CloudRestore.Discover(root).Count == 1, "в скрытые папки и по точкам соединения поиск не заходит");
            Check(Paths.Same(CloudRestore.ICloudDrive, Path.Combine(Paths.Home, "iCloudDrive")), "iCloud Drive для Windows — в папке пользователя");
        });

        if (!Integration)
        {
            Console.WriteLine("▸ Из iCloud: настоящее хранилище — пропущено (OFFLOAD_SKIP_INTEGRATION=1 или нет прав администратора)");
            return;
        }
        if (!CloudRestore.IsResticInstalled)
        {
            Console.WriteLine("▸ Из iCloud: настоящее хранилище — пропущено (restic не установлен)");
            return;
        }

        Section("Из iCloud: восстановление из настоящего хранилища", () =>
        {
            var baseFolder = Room("restic");
            var repositoryPath = Path.Combine(baseFolder, "repo");
            var source = Path.Combine(baseFolder, "SSD");
            const string secret = "проверочный пароль 42";
            Write("отчёт", Path.Combine(source, @"Документы\отчёт 2025.txt"));
            Write("звёздочка", Path.Combine(source, @"Документы\a[1].txt"));
            Write("сосед", Path.Combine(source, @"Документы\a1x.txt"));
            Write("вложенный", Path.Combine(source, @"Документы\Папка\глубже\b.txt"));
            Runner.Check("restic", ["init", "--repo", repositoryPath, "--quiet"], Encoding.UTF8.GetBytes(secret), TimeSpan.FromMinutes(2));
            Runner.Check("restic", ["backup", "--repo", repositoryPath, "--quiet", source], Encoding.UTF8.GetBytes(secret), TimeSpan.FromMinutes(5));
            var passwordFile = Path.Combine(baseFolder, "password");
            File.WriteAllText(passwordFile, secret);

            var repository = new CloudRestore.Repository(repositoryPath);
            var before = Listing(repositoryPath);
            ExpectError("неверный пароль", () => CloudRestore.Snapshots(repository, new CloudRestore.Password.Typed("не тот")),
                        ex => ex is CloudRestore.RestoreException { Kind: CloudRestore.RestoreErrorKind.WrongPassword });
            var snapshots = CloudRestore.Snapshots(repository, new CloudRestore.Password.Typed(secret));
            Check(snapshots.Count == 1, "снимок читается набранным паролем");
            Check(CloudRestore.Snapshots(repository, new CloudRestore.Password.FromFile(passwordFile)).Count == 1, "и паролем из файла");
            if (snapshots.FirstOrDefault() is not { } snapshot) return;
            var password = new CloudRestore.Password.Typed(secret);
            var top = CloudRestore.List(repository, password, snapshot.Id, snapshot.Root);
            Check(top.Select(e => e.Name).SequenceEqual(["Документы"]), $"содержимое корня ({snapshot.Root}): {string.Join(", ", top.Select(e => e.Name))}");
            var documents = CloudRestore.List(repository, password, snapshot.Id, snapshot.Root + "/Документы");
            Check(documents.FirstOrDefault() is { Name: "Папка", IsDirectory: true }, "папки идут первыми");
            Check(documents.Count == 4, "в папке четыре элемента, без вложенных");
            var search = CloudRestore.Search(repository, password, snapshot.Id, "ОТЧЁТ");
            Check(search.Select(e => e.Name).SequenceEqual(["отчёт 2025.txt"]), "поиск по части имени без учёта регистра");

            var folder = Path.Combine(Scratch, "restored");
            var star = documents.First(e => e.Name == "a[1].txt");
            var nested = documents.First(e => e.Name == "Папка");
            var first = CloudRestore.Restore(star, repository, password, snapshot, folder);
            Check(Read(first.Item) == "звёздочка", "файл со спецсимволами восстановлен");
            Check(Directory.GetFileSystemEntries(Paths.Parent(first.Item)).Select(Paths.Name).SequenceEqual(["a[1].txt"]), "восстановлен только он — без соседа a1x.txt");
            Check(first.Problems.Count == 0 && first.Files == 1, "без проблем");
            var second = CloudRestore.Restore(nested, repository, new CloudRestore.Password.FromFile(passwordFile), snapshot, folder);
            Check(Paths.Name(second.Item) == "Папка", "папка восстанавливается со своим именем");
            Check(Read(Path.Combine(second.Item, @"глубже\b.txt")) == "вложенный", "вложенное на месте");
            Check(!Paths.Same(Paths.Parent(second.Item), Paths.Parent(first.Item)) && Paths.Name(Paths.Parent(second.Item)).EndsWith("(2)"),
                  "каждый раз — новая папка, с номером, если имя занято");
            Check(CloudRestore.SizeOf(nested, repository, password, snapshot.Id) == Encoding.UTF8.GetByteCount("вложенный"), "размер папки — сумма файлов");
            int untouched = Directory.GetFileSystemEntries(folder).Length;
            ExpectError("остановленное восстановление", () => CloudRestore.Restore(nested, repository, password, snapshot, folder, isCancelled: () => true),
                        ex => ex is OperationCanceledException);
            Check(Directory.GetFileSystemEntries(folder).Length == untouched, "остановленное убрано целиком");
            var after = Listing(repositoryPath);
            Check(after.Count == before.Count && after.All(p => before.TryGetValue(p.Key, out var size) && size == p.Value),
                  "в хранилище ничего не записано — ни блокировок, ни кэша");
        });

        Section("Из iCloud: часть бэкапа испорчена — восстановленное остальное остаётся", () =>
        {
            // Большой файл займёт свои куски хранилища, маленький ляжет в последний. Испортим самый большой кусок:
            // restic выйдет с 1, а большой файл оставит полного размера с дырами.
            var baseFolder = Room("restic-damaged");
            var repositoryPath = Path.Combine(baseFolder, "repo");
            var source = Path.Combine(baseFolder, "SSD");
            const string secret = "проверочный пароль 42";
            Directory.CreateDirectory(Path.Combine(source, "Документы"));
            File.WriteAllBytes(Path.Combine(source, @"Документы\big.bin"), System.Security.Cryptography.RandomNumberGenerator.GetBytes(20_000_000));
            Write("маленький", Path.Combine(source, @"Документы\small.txt"));
            Runner.Check("restic", ["init", "--repo", repositoryPath, "--quiet"], Encoding.UTF8.GetBytes(secret), TimeSpan.FromMinutes(2));
            Runner.Check("restic", ["backup", "--repo", repositoryPath, "--quiet", source], Encoding.UTF8.GetBytes(secret), TimeSpan.FromMinutes(5));
            var largest = Directory.EnumerateFiles(Path.Combine(repositoryPath, "data"), "*", SearchOption.AllDirectories)
                .OrderByDescending(p => new FileInfo(p).Length).First();
            File.SetAttributes(largest, FileAttributes.Normal);
            var bytes = File.ReadAllBytes(largest);
            for (int index = 1000; index < bytes.Length - 1000; index += 4096) bytes[index] ^= 0xFF;
            File.WriteAllBytes(largest, bytes);

            var repository = new CloudRestore.Repository(repositoryPath);
            var password = new CloudRestore.Password.Typed(secret);
            var snapshot = CloudRestore.Snapshots(repository, password).First();
            var documents = CloudRestore.List(repository, password, snapshot.Id, snapshot.Root).First(e => e.Name == "Документы");
            var report = CloudRestore.Restore(documents, repository, password, snapshot, Path.Combine(Scratch, "restored-damaged"));
            Check(!report.Verified && report.Problems.Any(p => p.Contains("big.bin")), "не всё прочиталось: сказано, что именно, и что сверки не было");
            Check(!File.Exists(Path.Combine(report.Item, "big.bin")), "испорченный файл убран, а не оставлен с дырами");
            Check(Read(Path.Combine(report.Item, "small.txt")) == "маленький", "целый файл восстановлен и остался");
            Check(report.Files == 1, "в отчёте — то, что осталось");
        });
    }

    /// <summary>Все файлы хранилища с размерами — чтобы убедиться, что чтение его не меняет.</summary>
    static Dictionary<string, long> Listing(string root) =>
        Directory.EnumerateFileSystemEntries(root, "*", SearchOption.AllDirectories)
            .ToDictionary(p => p, p => File.Exists(p) ? new FileInfo(p).Length : -1, Paths.Comparer);
}
