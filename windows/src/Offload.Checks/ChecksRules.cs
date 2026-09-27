using Offload.Core;
using static Offload.Checks.Harness;
using static Offload.Checks.Helpers;

namespace Offload.Checks;

// Правила безопасности: что по пути, по содержимому и по диску назначения переносить нельзя.
static partial class All
{
    static void ChecksRules()
    {
        Section("Правила безопасности: пути", () =>
        {
            var rules = new SafetyRules(Room("home-a"), publicFolder: Room("public-a"));
            Verdict V(string relative) => rules.PathVerdict(Path.Combine(rules.Home, relative));
            Verdict P(string relative) => rules.PathVerdict(Path.Combine(rules.Public, relative));

            Check(IsBlocked(rules.PathVerdict(rules.Home), "целиком"), "домашняя папка целиком запрещена");
            Check(IsBlocked(rules.PathVerdict(@"C:\Windows\System32\drivers\etc\hosts")), "вне домашней папки запрещено");
            Check(IsBlocked(V("Downloads"), "стандартная папка"), "стандартная папка целиком запрещена");
            Check(IsBlocked(V("downloads"), "стандартная папка"), "стандартная папка узнаётся без учёта регистра");
            Check(V(@"Downloads\archive.zip") == Verdict.Safe, "файл в Загрузках разрешён");
            Check(IsBlocked(V(@"Downloads\vms\Debian.vhdx"), "«Debian.vhdx» зарегистрирован"), "диск виртуальной машины запрещён");
            Check(IsBlocked(V(@"Downloads\home\debian\18.1\Whonix-Gateway.utm\Data\disk.raw"), "Whonix-Gateway.utm"),
                  "файл внутри пакета машины с Mac (.utm) запрещён");
            Check(IsBlocked(V(@"Documents\VM\Win.vbox")), "машина VirtualBox по файлу .vbox запрещена");
            Check(IsBlocked(V(@"AppData\Local\Docker\wsl\disk\docker_data.vhdx"), "Docker"), "диск Docker — с подсказкой про раздел Docker");
            Check(IsBlocked(V(@"AppData\Local\Docker"), "Docker"), "папка Docker — с той же подсказкой");
            Check(IsBlocked(V(@"AppData\Local\wsl\{7c3d}\ext4.vhdx"), "WSL"), "диск WSL — с подсказкой, как перенести его средствами WSL");
            Check(IsBlocked(V(@"AppData\Local\Packages\CanonicalGroupLimited.Ubuntu_79rhkp1fndgsc\LocalState\ext4.vhdx"), "WSL"),
                  "диск Ubuntu из Microsoft Store — тоже WSL");
            Check(IsBlocked(V(@"AppData\Roaming\Telegram Desktop\tdata"), "Telegram"), "кеш Telegram — с подсказкой");
            Check(IsBlocked(V(@"AppData\Roaming\Claude\vm_bundles\claudevm.bundle")), "виртуалка Claude запрещена");
            Check(V(@"AppData\Roaming\Apple Computer\iTunes\iPhone Software Updates\iPhone.ipsw") == Verdict.Safe, "прошивка iPhone разрешена");
            Check(V(@"AppData\Local\SomeApp\logs\run.log") == Verdict.Safe, "лог-файл разрешён");
            Check(V(@"AppData\Local\CrashDumps\app.exe.1234.dmp") == Verdict.Safe, "дамп сбоя разрешён");
            Check(IsBlocked(V(@"AppData\Roaming\SomeApp\data.db"), "AppData"), "данные программ в AppData запрещены");
            Check(IsBlocked(V(@"AppData\Local\SomeApp\data.vhdx")), "диск машины в AppData запрещён, даже в разрешённом месте");
            Check(V(@"AppData\Roaming\Apple Computer\MobileSync\Backup\0000").IsCaution, "бэкап iPhone — с предупреждением");
            Check(V(@"Apple\MobileSync\Backup\0000").IsCaution, "бэкап iPhone из «Устройств Apple» — с предупреждением");
            Check(IsBlocked(V(@".ssh\id_ed25519")), "~\\.ssh запрещена");
            Check(IsBlocked(V(".lmstudio")), "скрытая папка программы целиком запрещена");
            Check(V(@".lmstudio\models").IsCaution, "данные внутри скрытой папки — с предупреждением");
            Check(IsBlocked(V("NTUSER.DAT"), "Реестр"), "реестр пользователя запрещён");
            Check(IsBlocked(V("ntuser.dat.LOG1"), "Реестр"), "журнал реестра пользователя запрещён");
            Check(IsBlocked(V(@"OneDrive\Документы"), "OneDrive"), "папка OneDrive запрещена — с подсказкой, как освободить место");
            Check(IsBlocked(V(@"OneDrive - Компания\Отчёты"), "OneDrive"), "рабочий OneDrive тоже");
            Check(IsBlocked(V(@"iCloudDrive\Бэкапы"), "iCloud"), "iCloud Drive запрещён");
            Check(IsBlocked(V(@"VirtualBox VMs\Linux"), "VirtualBox"), "машины VirtualBox — через сам VirtualBox");
            Check(IsBlocked(V(@"Projects\app\.git\hooks\pre-commit"), "git"), "служебная папка git запрещена");
            Check(V(@"Projects\app") == Verdict.Safe, "сам проект с git переносить можно");
            Check(IsBlocked(P(@"BlueStacks_nxt\Engine\Nougat64\Data.vhdx"), "Data.vhdx"), "диск BlueStacks в общей папке запрещён");
            Check(IsBlocked(P("desktop.ini"), "Проводника"), "служебный файл общей папки запрещён");
            Check(P(@"Documents\setup.zip") == Verdict.Safe, "обычный файл в общей папке разрешён");

            foreach (var relative in new[] { @".SSH\authorized_keys", ".Ssh", @"Projects\app\.GIT\config", @"APPDATA\Roaming\x.db" })
                Check(IsBlocked(V(relative)), $"«~\\{relative}» запрещён независимо от регистра");

            // Короткие имена 8.3 («VIRTUA~1», «SSH~1») — те же папки: правила сравнивают настоящие имена.
            int shortChecked = 0;
            foreach (var (folder, inside) in new[] { ("VirtualBox VMs", "Linux"), (".ssh", "id_ed25519"), ("OneDrive - Компания", "Отчёты") })
            {
                Directory.CreateDirectory(Path.Combine(rules.Home, folder));
                if (ShortPath(Path.Combine(rules.Home, folder)) is not { } shortPath || Paths.Name(shortPath).Equals(folder, Paths.Comparison)) continue;
                shortChecked++;
                Check(IsBlocked(rules.PathVerdict(Path.Combine(shortPath, inside))), $"короткое имя «{Paths.Name(shortPath)}» не обходит запрет на «{folder}»");
            }
            if (shortChecked == 0) Console.WriteLine("  (короткие имена 8.3 в этой папке не создаются — проверка пропущена)");
        });

        Section("Домашняя папка, заданная через точку соединения", () =>
        {
            // Дом бывает не там, куда на него показывают. Правила разворачивают ссылки в проверяемом пути —
            // значит, и сам дом обязаны развернуть так же, иначе любой обычный путь внутри дома
            // окажется для них «вне домашней папки».
            var real = Room("harden-home-real");
            Directory.CreateDirectory(Path.Combine(real, @"Downloads\данные"));
            var link = Path.Combine(Scratch, "harden-home-link");
            Junction(link, real);

            var rules = new SafetyRules(link);
            Check(Paths.Same(rules.Home, real), $"дом развёрнут до настоящего пути ({rules.Home})");
            Check(rules.PathVerdict(Path.Combine(real, @"Downloads\архив.zip")) == Verdict.Safe, "обычный путь внутри дома считается своим, а не чужим");
            Check(rules.PathVerdict(Path.Combine(link, @"Downloads\архив.zip")) == Verdict.Safe, "тот же путь, записанный через ссылку, — тоже свой");
            Check(IsBlocked(rules.PathVerdict(real), "целиком"), $"сам дом запрещён как дом: {rules.PathVerdict(real)}");
            Check(IsBlocked(rules.PathVerdict(Path.Combine(real, @".ssh\id_ed25519")), "ключи"), "правило про ~\\.ssh работает и по настоящему пути");
            Check(IsBlocked(rules.PathVerdict(Path.Combine(real, "Downloads")), "стандартная папка"), "стандартная папка узнаётся по настоящему пути");

            var target = new SafeMover(rules).TargetPath(Path.Combine(link, @"Downloads\данные"), Fake("exfat", mount: @"Q:\", name: "Внешний"));
            Check(target == @"Q:\Offload\Downloads\данные", $"в архиве виден путь от дома, а не одно имя папки ({target})");

            // Ссылка внутри дома, ведущая в AppData, не открывает туда дорогу.
            var trap = Path.Combine(real, @"Documents\Фото\old");
            Directory.CreateDirectory(Path.Combine(real, @"AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"));
            Junction(trap, Path.Combine(real, "AppData"));
            Check(IsBlocked(rules.PathVerdict(Path.Combine(trap, @"Roaming\Microsoft\Windows\Start Menu\Programs\Startup\evil.cmd"))),
                  "путь через точку соединения в AppData запрещён, хотя конца пути ещё нет");
            if (CanSymlink)
            {
                var symbolic = Path.Combine(real, @"Documents\Фото\old2");
                DirectoryLink(symbolic, Path.Combine(real, "AppData"));
                Check(IsBlocked(rules.PathVerdict(Path.Combine(symbolic, @"Roaming\evil.cmd"))), "путь через символическую ссылку в AppData запрещён");
                var outside = Path.Combine(real, @"Documents\Фото\system");
                DirectoryLink(outside, @"C:\Windows");
                Check(IsBlocked(rules.PathVerdict(Path.Combine(outside, @"System32\evil.dll"))), "путь через ссылку за пределы дома запрещён");
            }
        });

        Section("Проверка содержимого", () =>
        {
            var rules = new SafetyRules(Room("home-b"));
            var folder = Path.Combine(rules.Home, @"Downloads\stuff");
            Write("a", Path.Combine(folder, "a.txt"));
            Write("", Path.Combine(folder, @"vms\Test.vhdx"));
            Directory.CreateDirectory(Path.Combine(folder, @"repo\.git"));
            Junction(Path.Combine(folder, "jlink"), Path.Combine(folder, "repo"));
            bool symlinks = CanSymlink;
            if (symlinks) FileLink(Path.Combine(folder, "link"), "a.txt");
            var report = Inspector.Inspect(folder);
            Check(report.RegisteredBundle == @"vms\Test.vhdx", $"найден вложенный диск машины ({report.RegisteredBundle})");
            Check(report.SymlinkCount == (symlinks ? 2 : 1) && report.SymbolicLinks == (symlinks ? 1 : 0),
                  $"посчитаны ссылки: всего {report.SymlinkCount}, символических {report.SymbolicLinks}");
            Check(report.ContainsGitRepo, "найден git-репозиторий");
            Check(rules.FullVerdict(folder, report).IsBlocked, "папка с вложенным диском машины запрещена");

            var clean = Path.Combine(rules.Home, @"Downloads\clean");
            Write("b", Path.Combine(clean, "b.txt"));
            var fresh = rules.FullVerdict(clean, Inspector.Inspect(clean));
            Check(fresh.IsCaution && fresh.Notes.Any(n => n.Contains("Менялось")), "свежие файлы — с предупреждением");
            Check(rules.FullVerdict(clean, Inspector.Inspect(clean), now: DateTime.UtcNow.AddDays(30)) == Verdict.Safe,
                  "давно не менявшиеся файлы разрешены без оговорок");
            Check(IsBlocked(rules.FullVerdict(clean, null, ["Блокнот"]), "открыты"), "открытые файлы запрещают перенос");

            // Внутри подключён другой том (точка подключения тома в папке): он не должен уехать вместе с папкой.
            var mounted = Path.Combine(rules.Home, @"Downloads\with-volume");
            Write("x", Path.Combine(mounted, "x.txt"));
            var volume = Native.VolumeGuidPath(Paths.Root(Scratch));
            if (volume != null)
            {
                var mountPoint = Path.Combine(mounted, "disk");
                Junction(mountPoint, volume.StartsWith(@"\\?\", StringComparison.Ordinal) ? volume[4..] : volume);
                try
                {
                    var withVolume = Inspector.Inspect(mounted);
                    Check(withVolume.MountedVolume == "disk" && withVolume.SymlinkCount == 0, $"подключённый внутрь том замечен ({withVolume.MountedVolume})");
                    Check(IsBlocked(rules.FullVerdict(mounted, withVolume), "другой диск"), "папка с подключённым внутрь томом не переносится");
                }
                finally { FileSystem.DeleteTree(mountPoint); }
            }

            // Файл, открытый другой программой, — то, что на Mac показывает lsof.
            var busy = Path.Combine(rules.Home, @"Downloads\busy");
            Write("держу", Path.Combine(busy, "open.txt"));
            using (new Holder(Path.Combine(busy, "open.txt")))
            {
                var locks = FileLocks.Scan(busy);
                Check(locks is { Holders.Count: > 0 }, $"программа, держащая файл, найдена: {string.Join(", ", locks?.Holders ?? [])}");
                var plan = new SafeMover(rules).Plan(busy, Fake("ntfs"));
                Check(IsBlocked(plan.Verdict, "открыты"), $"перенос открытого файла запрещён ещё в плане: {plan.Verdict}");
            }
            using (var own = new FileStream(Path.Combine(busy, "open.txt"), FileMode.Open, FileAccess.Read, FileShare.Read))
                Check(FileLocks.Scan(busy) is { Holders.Count: 0, Locked: 0 }, "файл, открытый самим Offload, занятым не считается");
        });

        Section("Проверка диска назначения", () =>
        {
            var content = new ContentReport { Files = 10, Directories = 2, LogicalBytes = 1L << 30, AllocatedBytes = 1L << 30, SymlinkCount = 3, SymbolicLinks = 1 };
            var exfat = SafetyRules.CheckDestination(Fake("exfat", block: 131_072), null, content);
            Check(!exfat.IsOK && exfat.Blockers.Any(b => b.Contains("ссылки")), $"exFAT не хранит ссылки — перенос со ссылками запрещён: {string.Join(" ", exfat.Blockers)}");
            Check(SafetyRules.CheckDestination(Fake("ntfs"), null, content, canCreateSymlinks: true).IsOK, "NTFS со ссылками допустим");
            var noRights = SafetyRules.CheckDestination(Fake("ntfs"), null, content, canCreateSymlinks: false);
            Check(!noRights.IsOK && noRights.Blockers.Any(b => b.Contains("режим")),
                  "символические ссылки без права их создавать — запрет с подсказкой про режим разработчика");
            var junctions = content with { SymbolicLinks = 0 };
            Check(SafetyRules.CheckDestination(Fake("ntfs"), null, junctions, canCreateSymlinks: false).IsOK,
                  "точки соединения создаются без особых прав — запрета нет");
            var plain = content with { SymlinkCount = 0, SymbolicLinks = 0 };
            Check(SafetyRules.CheckDestination(Fake("exfat", block: 131_072), null, plain).IsOK, "exFAT без ссылок допустим");
            Check(!SafetyRules.CheckDestination(Fake("fat32"), null, plain with { LargestFile = 5L << 30 }).IsOK, "FAT32 не принимает файл больше 4 ГБ");
            Check(SafetyRules.CheckDestination(Fake("exfat"), null, plain with { LargestFile = 5L << 30 }).IsOK, "exFAT принимает файл больше 4 ГБ");
            Check(!SafetyRules.CheckDestination(Fake("exfat", free: 100L << 20), null, plain).IsOK, "мало места — запрет");
            Check(!SafetyRules.CheckDestination(Fake("ntfs", readOnly: true), null, plain).IsOK, "только чтение — запрет");
            Check(!SafetyRules.CheckDestination(Fake("ntfs"), Fake("ntfs"), plain).IsOK, "тот же диск — запрет");
            var sparse = plain with { SparseFiles = 1, AllocatedBytes = 100L << 20 };
            Check(SafetyRules.CheckDestination(Fake("exfat"), null, sparse).Notes.Any(n => n.Contains("Разрежённые")), "предупреждение о разрежённых файлах");
            var tagged = new ContentReport { Files = 2, LogicalBytes = 1L << 20, TaggedFiles = 2, HardLinkedFiles = 3 };
            var notes = string.Join(" ", SafetyRules.CheckDestination(Fake("exfat"), null, tagged).Notes);
            Check(notes.Contains("потоки данных NTFS"), "о потере дополнительных потоков NTFS предупреждают заранее");
            Check(notes.Contains("жёсткие ссылки"), "о разрыве жёстких ссылок предупреждают заранее");
        });

        Section("Место на приёмнике: мелкие файлы и разрежённые", () =>
        {
            // Двадцать тысяч мелких файлов: логически весят копейки, а на диске каждый занял целый кластер.
            var small = new ContentReport { Files = 20_000, Directories = 500, LogicalBytes = 20_000L * 200, AllocatedBytes = 20_000L * 4096 };
            var smallCheck = SafetyRules.CheckDestination(Fake("ntfs"), null, small);
            Check(smallCheck.RequiredBytes >= small.AllocatedBytes,
                  $"оценка места для дерева мелких файлов не меньше занятого на диске: {smallCheck.RequiredBytes} против {small.AllocatedBytes}");
            Check(smallCheck.IsOK, "на просторном диске перенос мелких файлов разрешён");
            long margin = 512L * 1024 * 1024;
            var tight = Fake("ntfs", free: (small.LogicalBytes + small.AllocatedBytes) / 2 + margin);
            Check(tight.AvailableBytes > small.LogicalBytes + margin, "условие задачи: по логическому размеру места хватало бы");
            Check(!SafetyRules.CheckDestination(tight, null, small).IsOK, "места хватает только по логическому размеру — перенос запрещён");
            // У exFAT кластер бывает 128 КБ: на нём те же файлы займут ещё больше.
            var bigCluster = SafetyRules.CheckDestination(Fake("exfat", block: 131_072), null, small);
            Check(bigCluster.RequiredBytes > smallCheck.RequiredBytes, "крупный кластер приёмника учтён в оценке места");

            var sparse = new ContentReport { Files = 1, Directories = 1, LogicalBytes = 200L << 30, AllocatedBytes = 20L << 30, SparseFiles = 1 };
            var sparseCheck = SafetyRules.CheckDestination(Fake("ntfs", free: 60L << 30), null, sparse);
            Check(sparseCheck.RequiredBytes >= sparse.LogicalBytes, "разрежённый файл считается по логическому размеру");
            Check(!sparseCheck.IsOK, "разрежённый файл на 200 ГБ не пускают туда, где свободно 60 ГБ");
            Check(sparseCheck.Notes.Any(n => n.Contains("полный размер")), "оговорка про разрежённые файлы на месте");
        });

        Section("Осмотр настоящих файлов: потоки NTFS и жёсткие ссылки", () =>
        {
            var room = Room("harden-inspect");
            string Folder(string name, string file, params string[] streams)
            {
                var directory = Path.Combine(room, name);
                var path = Path.Combine(directory, file);
                Write("содержимое", path);
                foreach (var stream in streams) File.WriteAllText(path + ":" + stream, "1");
                return directory;
            }
            // Поток, который записала программа (метка, эскиз, комментарий), человек заметит, если он пропадёт.
            var tagged = Folder("метка", "a.txt", "com.dropbox.attrs");
            Check(Inspector.Inspect(tagged).TaggedFiles == 1, "дополнительный поток на настоящем файле заметен");
            // А это Windows ставит сама каждому скачанному файлу — предупреждать о нём незачем.
            var downloaded = Folder("скачанное", "setup.msi", "Zone.Identifier", "SmartScreen");
            var routine = Inspector.Inspect(downloaded);
            Check(routine.Files == 1 && routine.TaggedFiles == 0, $"отметка «скачано из интернета» заметной не считается ({routine.TaggedFiles})");
            var mixed = Folder("вперемешку", "с-меткой.txt", "com.dropbox.attrs");
            Write("ещё", Path.Combine(mixed, "скачанный.zip"));
            File.WriteAllText(Path.Combine(mixed, "скачанный.zip") + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=3");
            var mixedReport = Inspector.Inspect(mixed);
            Check(mixedReport.Files == 2 && mixedReport.TaggedFiles == 1,
                  $"среди скачанных файлов заметен ровно помеченный ({mixedReport.TaggedFiles} из {mixedReport.Files})");
            var notes = string.Join(" ", SafetyRules.CheckDestination(Fake("exfat"), null, mixedReport).Notes);
            Check(notes.Contains("потоки"), "о потере настоящего потока предупреждают до переноса");

            var hard = Path.Combine(room, "жёсткие");
            Write("один и тот же файл", Path.Combine(hard, "первое имя.bin"));
            HardLink(Path.Combine(hard, "первое имя.bin"), Path.Combine(hard, "второе имя.bin"));
            var hardReport = Inspector.Inspect(hard);
            Check(hardReport.Files == 2 && hardReport.HardLinkedFiles == 2,
                  $"оба имени одного файла посчитаны как жёсткие ссылки ({hardReport.HardLinkedFiles} из {hardReport.Files})");
            Check(Inspector.Inspect(tagged).HardLinkedFiles == 0, "обычный файл жёсткой ссылкой не считается");
            Check(string.Join(" ", SafetyRules.CheckDestination(Fake("exfat"), null, hardReport).Notes).Contains("жёсткие ссылки"),
                  "о разрыве настоящих жёстких ссылок предупреждают до переноса");

            var sparse = Path.Combine(room, @"разрежённое\disk.img");
            Sparse(sparse, 2L << 30);
            var sparseReport = Inspector.Inspect(Paths.Parent(sparse));
            Check(sparseReport.SparseFiles == 1 && sparseReport.LogicalBytes == 2L << 30 && sparseReport.AllocatedBytes < 64L << 20,
                  $"разрежённый файл замечен: {sparseReport.LogicalBytes} на бумаге, {sparseReport.AllocatedBytes} на диске");
        });
    }
}
