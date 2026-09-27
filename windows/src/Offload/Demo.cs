using System.IO;
using Offload.Core;

namespace Offload;

/// <summary>Демонстрационный режим для снимков экрана: OFFLOAD_DEMO=1.
///
/// Показывает вымышленные диск, сейф, папки и журнал, чтобы снимки для README не выдавали ничьих
/// настоящих папок и проектов. В этом режиме OffLoadAI ничего не читает с дисков, ничего не сохраняет
/// в настройки и ничего не пишет в журнал.</summary>
public static class Demo
{
    public static readonly bool IsOn = Environment.GetEnvironmentVariable("OFFLOAD_DEMO") == "1";

    public static readonly string Home = Paths.Home;
    const long Gigabyte = 1_000_000_000;

    public static readonly VolumeInfo SystemDisk = new(@"C:\", "Локальный диск", "ntfs", 494 * Gigabyte, 41 * Gigabyte, 4096, false, true);

    public static readonly VolumeInfo Disk = new(@"E:\", "Samsung T7", "exfat", 1000 * Gigabyte, 612 * Gigabyte, 131_072, false, false);

    public const string SafeMount = @"S:\";

    public static readonly VolumeInfo SafeVolume = new(SafeMount, "Offload Safe", "ntfs", 1000 * Gigabyte, 611 * Gigabyte, 4096, false, false, true);

    public static SafeModel.State SafeState
    {
        get
        {
            var image = Path.Combine(Disk.MountPoint, SecretsVault.SafeImageName);
            return new SafeModel.State(Disk.Id, image, true, true, new EncryptionInfo(true, 1, 2, "5B1E2C4A-0D3F-4E77-9A61-2C8B7F1D0E93"),
                                       Disk.TotalBytes, 318 * Gigabyte, SafeMount, [image], false);
        }
    }

    public static readonly MemorySnapshot Memory = new(
        16UL << 30, 1_200UL << 20, 2_300UL << 20, 1_100UL << 20, 3UL << 30, MemoryPressure.Normal, TimeSpan.FromHours(3 * 24 + 5),
        [
            new AppMemory("Google Chrome", 3_400UL << 20, 23),
            new AppMemory("Visual Studio Code", 2_600UL << 20, 14),
            new AppMemory("Figma", 1_300UL << 20, 5),
            new AppMemory("Slack", 900UL << 20, 6),
            new AppMemory("Telegram Desktop", 610UL << 20, 2),
            new AppMemory("Проводник", 380UL << 20, 1),
        ]);

    static string At(string relative) => Path.Combine(Home, relative);

    public static List<SpaceItem> SpaceItems()
    {
        SpaceItem Item(string name, double gb, Verdict verdict, double daysAgo) =>
            new(At(name), (long)(gb * Gigabyte), DateTime.UtcNow.AddDays(-daysAgo), true, false, verdict, true);
        return
        [
            Item("Videos", 142.6, Verdict.Safe, 210),
            Item("AppData", 96.1, Verdict.Blocked("Данные программ: перенос сломает программы, которые их используют."), 0),
            Item("Downloads", 58.3, Verdict.Safe, 3),
            Item("Pictures", 41.7, Verdict.Caution("Внутри каталог Lightroom — его перенести нельзя, остальное можно."), 12),
            Item("Projects", 31.2, Verdict.Caution("Внутри git-репозитории: после переноса с ними можно работать только с диска."), 1),
            Item("Music", 12.4, Verdict.Safe, 400),
            Item("Documents", 17.5, Verdict.Safe, 5),
            Item("Desktop", 2.9, Verdict.Safe, 0),
        ];
    }

    public static List<MoveRecord> Records()
    {
        MoveRecord Record(string relative, double gb, int files, double daysAgo, bool inSafe = true, bool restored = false, string? note = null)
        {
            var root = inSafe ? SafeMount : Disk.MountPoint;
            return new MoveRecord
            {
                Date = DateTime.UtcNow.AddDays(-daysAgo), OriginalPath = At(relative), ArchivedPath = Path.Combine(root, "Offload", relative),
                VolumeName = inSafe ? SafeVolume.Name : Disk.Name, Files = files, Bytes = (long)(gb * Gigabyte), OriginalRemoved = true,
                Restored = restored, Note = note, InSafe = inSafe ? true : null,
            };
        }
        return
        [
            Record(@"Videos\Съёмки 2023", 86.4, 412, 1),
            Record(@"Apple\MobileSync\Backup\iPhone 15", 48.2, 9_811, 2, note: "Резервная копия iPhone. После возврата «Устройства Apple» снова её увидят."),
            Record(@"Downloads\Установщики", 21.7, 64, 2),
            Record(@"Pictures\Экспорт Lightroom 2022", 12.9, 1_840, 30, inSafe: false, note: "Перенесено до появления сейфа — лежит на диске открыто."),
            Record(@"Music\Проекты FL Studio", 9.8, 2_377, 6),
            Record(@"Projects\old-prototypes", 6.3, 18_204, 9),
            Record(@"Documents\Сканы договоров", 1.2, 146, 14, restored: true),
        ];
    }

    /// <summary>Что находит разбор в демонстрации — через настоящие правила, привычки и память.</summary>
    public static List<CleanupSuggestion> CleanupSuggestions(IReadOnlyDictionary<string, CleanupAction> memory, HabitModel? habits)
    {
        var now = DateTime.UtcNow;
        CleanupObservation Item(string relative, double gb, double daysAgo, bool directory = true, Verdict? verdict = null, bool project = false) =>
            new(At(relative), (long)(gb * Gigabyte), now.AddDays(-daysAgo), directory, verdict ?? Verdict.Safe, project);
        DuplicateCopy Copy(string relative, double gb, double daysAgo) =>
            new(At(relative), (long)(gb * Gigabyte), now.AddDays(-daysAgo), now.AddDays(-daysAgo));
        var appData = Verdict.Blocked("Данные программ");
        var regenerable = new Dictionary<string, string>(Paths.Comparer);
        foreach (var location in CleanupPlanner.RegenerableLocations)
        {
            if (location.Path == @".nuget\packages" || location.Path == @"AppData\Local\npm-cache\_cacache" || location.Path == @"AppData\Local\pip\Cache")
                regenerable[At(location.Path)] = location.Reason;
            if (location.Path == @"AppData\Local\Google\Chrome\User Data") regenerable[At(location.Path + @"\Default\Cache")] = location.Reason;
        }
        var remembered = new Dictionary<string, CleanupAction>(memory, Paths.Comparer) { [At(@"Downloads\Датасеты")] = CleanupAction.Safe };
        // Кеш открытого Chrome в демонстрации — занят.
        var busy = new Dictionary<string, string>(Paths.Comparer)
        {
            [At(@"AppData\Local\Google\Chrome\User Data\Default\Cache")] = "Сейчас открыт Google Chrome: кеш занят. Закройте программу — и его можно будет удалить.",
        };
        var planner = new CleanupPlanner { Now = now, Home = Home, Regenerable = regenerable, Memory = remembered, Habits = habits, Busy = busy };
        return planner.Suggestions(
        [
            Item(@".nuget\packages", 18.4, 0, verdict: appData),
            Item(@"AppData\Local\npm-cache\_cacache", 3.4, 5, verdict: appData),
            Item(@"AppData\Local\Google\Chrome\User Data\Default\Cache", 1.6, 0, verdict: appData),
            Item(@"AppData\Local\pip\Cache", 1.1, 7, verdict: appData),
            Item(@"Videos\Съёмки 2023", 86.4, 210),
            Item(@"Downloads\Датасеты", 24.1, 150),
            Item(@"Videos\Интервью 2024", 12.6, 50),
            Item(@"Documents\Архив 2019", 9.4, 900),
            Item(@"Documents\Работа", 8.1, 2),
            Item(@"Pictures\Lightroom\Каталог.lrcat", 41.7, 1, directory: false, verdict: Verdict.Blocked("Каталог Lightroom")),
            Item(@"Downloads\VisualStudioSetup.exe", 7.9, 60, directory: false),
            Item(@"Downloads\Figma-Setup.msi", 0.3, 40, directory: false),
            Item(@"Projects\offload-site", 1.2, 120, project: true),
        ],
        [
            new DuplicateGroup("demo-video", (long)(2.4 * Gigabyte),
                [Copy(@"Videos\Отпуск 2023.mp4", 2.4, 300), Copy(@"Downloads\Отпуск 2023.mp4", 2.4, 40), Copy(@"Desktop\Отпуск 2023 (1).mp4", 2.4, 12)]),
            new DuplicateGroup("demo-pdf", 14_000_000,
                [Copy(@"Documents\Договор аренды.pdf", 0.014, 90), Copy(@"Downloads\Договор аренды (1).pdf", 0.014, 30)]),
        ]);
    }

    /// <summary>Прошлые решения, на которых в демонстрации выучены привычки. Пишутся только в базу в памяти.</summary>
    public static List<DecisionStore.Decision> Decisions()
    {
        var now = DateTime.UtcNow;
        DecisionStore.Decision Decision(string relative, CleanupAction action, CleanupAction suggested, DecisionKind kind, double gb, double daysAgo, double decidedDaysAgo)
        {
            var decided = now.AddDays(-decidedDaysAgo);
            return new DecisionStore.Decision(At(relative), action, (long)(gb * Gigabyte), suggested, kind, decided.AddDays(-daysAgo), decided);
        }
        var result = new List<DecisionStore.Decision>();
        var shoots = new[] { "Съёмки 2019", "Съёмки 2020", "Свадьба Ани", "Съёмки 2021", "Съёмки 2022" };
        for (int i = 0; i < shoots.Length; i++)
            result.Add(Decision($@"Videos\{shoots[i]}", CleanupAction.Safe, CleanupAction.Safe, DecisionKind.Folder, 18 + i * 11, 200 + i * 60, 20 + i * 25));
        var archives = new[] { "Архив 2015", "Архив 2016", "Архив 2017", "Архив 2018" };
        for (int i = 0; i < archives.Length; i++)
            result.Add(Decision($@"Documents\{archives[i]}", CleanupAction.Keep, CleanupAction.Safe, DecisionKind.Folder, 2.5 + i * 1.5, 400 + i * 200, 10 + i * 30));
        var projects = new[] { "landing", "telegram-bot", "scripts" };
        for (int i = 0; i < projects.Length; i++)
            result.Add(Decision($@"Projects\{projects[i]}", CleanupAction.Backup, CleanupAction.Backup, DecisionKind.Project, 0.2 + i * 0.3, 5 + i * 20, 15 + i * 10));
        return result;
    }

    public static List<string> BackupSources => new[] { "Projects", "Documents", "Desktop" }.Select(At).ToList();

    // MARK: Docker и виртуальные машины

    public const long DockerRawBytes = 64 * Gigabyte;

    public static List<DockerVolume> DockerVolumes
    {
        get
        {
            DockerVolume Volume(string name, double gb, double daysAgo, params string[] usedBy) =>
                new(name, DateTime.UtcNow.AddDays(-daysAgo), (long)(gb * Gigabyte), usedBy);
            return
            [
                Volume("postgres-data", 12.4, 40, "shop-db"),
                Volume("ml-datasets", 9.8, 120),
                Volume("redis-cache", 0.6, 40, "shop-cache"),
                Volume("old-wordpress", 3.2, 400),
                Volume("minio-storage", 5.1, 200),
            ];
        }
    }

    public static readonly DockerUsage DockerUsage = new(
        new DockerUsage.PartInfo(24, 6, 18 * Gigabyte, 11 * Gigabyte),
        new DockerUsage.PartInfo(9, 3, 400_000_000, 250_000_000),
        new DockerUsage.PartInfo(5, 2, 31 * Gigabyte, 18 * Gigabyte),
        new DockerUsage.PartInfo(140, 0, 9 * Gigabyte, 9 * Gigabyte));

    public static List<VirtualMachine> Machines
    {
        get
        {
            VirtualMachine Machine(string name, MachineKind kind, string path, double gb, double logical, double daysAgo) =>
                new(name, kind, path, (long)(gb * Gigabyte), (long)(logical * Gigabyte), (long)(gb * 0.95 * Gigabyte), DateTime.UtcNow.AddDays(-daysAgo));
            return
            [
                Machine("Windows 11 (разработка)", MachineKind.VirtualBox, At(@"VirtualBox VMs\Windows 11 (разработка)"), 38.2, 64, 3),
                Machine("Ubuntu-24.04", MachineKind.Wsl, At(@"AppData\Local\wsl\{3f1e}\ext4.vhdx"), 24.9, 24.9, 1),
                Machine("Kali", MachineKind.VirtualBox, At(@"VirtualBox VMs\Kali"), 11.5, 32, 210),
            ];
        }
    }

    // MARK: Из iCloud

    public static List<CloudRestore.Repository> CloudRepositories => [new(Path.Combine(CloudRestore.ICloudDrive, "Бэкапы", "ssd-restic"))];

    public static List<CloudRestore.Snapshot> CloudSnapshots
    {
        get
        {
            CloudRestore.Snapshot Snapshot(string id, double hoursAgo) =>
                new(id + new string('0', 56), id, DateTime.UtcNow.AddHours(-hoursAgo), ["/Volumes/Samsung T7"], "mac", ["ssd"], 162 * Gigabyte);
            return [Snapshot("c00b9807", 5), Snapshot("3e18663f", 30), Snapshot("9a41d2e0", 170)];
        }
    }

    public const string CloudDirectory = "/Volumes/Samsung T7";

    public static List<CloudRestore.Entry> CloudEntries
    {
        get
        {
            CloudRestore.Entry Entry(string name, double? gb, double daysAgo) =>
                new(CloudDirectory + "/" + name, gb == null, gb is { } size ? (long)(size * Gigabyte) : null, DateTime.UtcNow.AddDays(-daysAgo));
            return
            [
                Entry("Offload", null, 1), Entry("Projects", null, 2), Entry("Photos 2025", null, 60), Entry("Movies", null, 210),
                Entry("Offload Safe.vhdx", 318, 1), Entry("presentation.pptx", 0.4, 12), Entry("taxes-2025.pdf", 0.002, 90),
            ];
        }
    }
}
