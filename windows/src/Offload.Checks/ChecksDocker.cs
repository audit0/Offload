using Offload.Core;
using static Offload.Checks.Harness;
using static Offload.Checks.Helpers;

namespace Offload.Checks;

// Docker и виртуальные машины: место из-под них освобождается средствами самих программ.
// Разбор ответов docker проверяется всегда; настоящий Docker — только если он запущен.
// Очистку (prune) проверки не запускают никогда: она удалила бы образы и кеш человека.
static partial class All
{
    static void ChecksDocker()
    {
        Section("Docker: имена и размеры", () =>
        {
            Check(DockerService.IsValidVolumeName("openwrt-build-arm64") && DockerService.IsValidVolumeName("ok_name.1"), "обычные имена томов допустимы");
            foreach (var bad in new[] { "a", "-rm", @"C:\Users\q:/v", "x:y", "name with space", "../etc", "", @"..\etc", "том", "a\nb", new string('a', 256) })
                Check(!DockerService.IsValidVolumeName(bad), $"имя «{bad.Replace("\n", "\\n")}» отклоняется");
            Check(DockerService.VolumeNameFromArchive(@"E:\Offload\docker-volumes\vol-1.tar.zst") == "vol-1", "имя тома из имени архива");
            Check(DockerService.VolumeNameFromArchive(@"E:\vol-2.tar") == "vol-2", "и из несжатого архива");
            Check(DockerService.VolumeNameFromArchive(@"E:\vol (2).tar.zst") == null, "имя архива с пробелом не превращается в имя тома");
            Check(DockerService.VolumeNameFromArchive(@"E:\vol.zip") == null, "не архив тома — не имя тома");
            Check(DockerService.ParseSize("31.65GB") == 31_650_000_000, "31.65GB разбирается без ошибки округления");
            Check(DockerService.ParseSize("1.002kB") == 1_002 && DockerService.ParseSize("264B") == 264 && DockerService.ParseSize("2TB") == 2_000_000_000_000,
                  "мелкие и крупные размеры разбираются");
            Check(DockerService.ParseSize("N/A") == null && DockerService.ParseSize("") == null && DockerService.ParseSize("GB") == null, "мусор вместо размера не разбирается");

            var disk = Room("docker-disk");
            Write("", Path.Combine(disk, @"Offload\docker-volumes\a.tar.zst"));
            Write("", Path.Combine(disk, @"Archive-2026\docker-volumes\b.tar"));
            Write("", Path.Combine(disk, @"Archive-2026\docker-volumes\notes.txt"));
            Write("", Path.Combine(disk, @"Archive-2026\docker-volumes\.hidden.tar"));
            Directory.CreateDirectory(Path.Combine(disk, @"Archive-2026\docker-volumes\folder.tar"));
            var found = DockerService.Archives(Fake("ntfs", mount: disk + "\\")).Select(Paths.Name).ToList();
            Check(found.ToHashSet().SetEquals(["a.tar.zst", "b.tar"]), $"архивы томов находятся и в OffLoadAI, и в ручных папках docker-volumes ({string.Join(", ", found)})");
        });

        Section("Docker: место внутри и очистка — разбор ответов docker", () =>
        {
            const string df = "Images\t25\t3\t12.34GB\t10.2GB (82%)\nContainers\t5\t1\t1.2MB\t1.1MB (91%)\nLocal Volumes\t12\t4\t31.65GB\t20.1GB (63%)\r\nBuild Cache\t120\t0\t5.6GB\t5.6GB\n";
            var usage = DockerService.ParseUsage(df);
            Check(usage?.Images == new DockerUsage.PartInfo(25, 3, 12_340_000_000, 10_200_000_000), "образы: сколько всего, сколько занято, размер и сколько можно убрать");
            Check(usage?.Containers == new DockerUsage.PartInfo(5, 1, 1_200_000, 1_100_000), "контейнеры");
            Check(usage?.Volumes?.Bytes == 31_650_000_000, "тома — и со строкой в переводах строк Windows");
            Check(usage?.BuildCache?.Reclaimable == 5_600_000_000, "кеш сборки — у него доли в скобках нет");
            Check(usage?.ReclaimableFor([DockerPruneTarget.Images, DockerPruneTarget.BuildCache]) == 15_800_000_000, "к очистке — образы и кеш, тома не в счёт");
            Check(usage?.ReclaimableFor([]) == 0, "ничего не выбрано — ничего не уйдёт");
            Check(DockerService.ParseUsage("Images\t2\t0\t0B\t0B\n") == new DockerUsage(new DockerUsage.PartInfo(2, 0, 0, 0)), "нули разбираются, отсутствующие строки остаются пустыми");
            Check(DockerService.ParseUsage("failed to connect to the docker API at npipe:////./pipe/dockerDesktopLinuxEngine") == null, "ответ без таблицы — не разбор");

            Check(DockerService.ParseReclaimed("Deleted Images:\nuntagged: alpine:3\ndeleted: sha256:0123\n\nTotal reclaimed space: 7.8MB\n") == 7_800_000, "итог docker image prune");
            Check(DockerService.ParseReclaimed("ID\t\tRECLAIMABLE\tSIZE\tLAST ACCESSED\nk2f9*\ttrue\t1.2GB\t2 days ago\nTotal:\t5.6GB\n") == 5_600_000_000,
                  "итог docker builder prune (buildx)");
            Check(DockerService.ParseReclaimed("Total reclaimed space: 0B\r\n") == 0, "удалять было нечего — ноль, а не «неизвестно»");
            Check(DockerService.ParseReclaimed("Deleted Containers:\n") == null, "без итога — неизвестно");

            var arguments = Enum.GetValues<DockerPruneTarget>().Select(DockerService.PruneArguments).ToList();
            Check(!arguments.SelectMany(a => a).Any(a => a.StartsWith("volume") || a == "--volumes"), "очистка никогда не трогает тома");
            Check(arguments.All(a => a.Contains("--force")), "docker не ждёт подтверждения, которого никто не даст");
            Check(Enum.GetValues<DockerPruneTarget>()[0] == DockerPruneTarget.Containers, "контейнеры чистятся первыми — иначе их образы ещё заняты");
            Check(!DockerService.PruneArguments(DockerPruneTarget.DanglingImages).Contains("--all"),
                  "образы без имени чистятся без --all: образы с именем, собранные человеком, остаются");
            Check(DockerService.PruneArguments(DockerPruneTarget.Images).Contains("--all"), "все неиспользуемые образы — только по отдельной галочке");
            Check(DockerService.PruneOrder(new HashSet<DockerPruneTarget> { DockerPruneTarget.BuildCache, DockerPruneTarget.DanglingImages })
                      .SequenceEqual([DockerPruneTarget.DanglingImages, DockerPruneTarget.BuildCache]), "сразу отмеченное: образы без имени и кеш сборки");
            Check(DockerService.PruneOrder(new HashSet<DockerPruneTarget> { DockerPruneTarget.Images, DockerPruneTarget.DanglingImages, DockerPruneTarget.Containers })
                      .SequenceEqual([DockerPruneTarget.Containers, DockerPruneTarget.Images]), "отмечены все образы — образы без имени второй раз не чистятся");
            Check(new DockerUsage().ReclaimableFor([DockerPruneTarget.DanglingImages]) == 0, "размер образов без имени неизвестен — в оценку не входит");

            // Сверка тома и архива идёт одним скриптом в контейнере: имена с кавычками не должны его ломать.
            Check(DockerService.VolumeDigestScript.Contains("set -eo pipefail") && DockerService.ArchiveDigestScript().Contains("--to-command="),
                  "сверка — с pipefail и без распаковки архива на диск");
            var docker = new DockerService(Room("home-docker-none"));
            Check(docker.RawDiskPath == null && docker.RawDiskBytes() == null, "нет диска Docker — нет и его размера, без ошибки");
            Write("", Path.Combine(docker.Home, @"AppData\Local\Docker\wsl\disk\docker_data.vhdx"));
            Check(docker.RawDiskPath == Path.Combine(docker.Home, @"AppData\Local\Docker\wsl\disk\docker_data.vhdx"), "диск Docker ищется там, где его держит Docker Desktop");
        });

        Section("Данные Docker и виртуальных машин: чьи это строки", () =>
        {
            var home = Room("home-appdata");
            AppDataKind? Kind(string relative) => AppDataKinds.Of(Path.Combine(home, relative), home);
            Check(Kind(@"AppData\Local\Docker") == AppDataKind.Docker, "папка Docker");
            Check(Kind(@"AppData\Local\Docker\wsl\disk\docker_data.vhdx") == AppDataKind.Docker, "диск Docker");
            Check(Kind(@"AppData\Local\wsl") == AppDataKind.VirtualMachines, "машины WSL");
            Check(Kind(@"AppData\Local\Packages\CanonicalGroupLimited.Ubuntu_79rhkp1fndgsc") == AppDataKind.VirtualMachines, "Ubuntu из Microsoft Store");
            Check(Kind(@"VirtualBox VMs\Linux") == AppDataKind.VirtualMachines, "машина VirtualBox");
            Check(Kind(@"Documents\Virtual Machines\Ubuntu") == AppDataKind.VirtualMachines, "машина VMware");
            Check(Kind(@"Downloads\vms\Debian.vdi") == AppDataKind.VirtualMachines, "диск машины из другой папки");
            Check(Kind(@"Downloads\Offload Safe.vhdx") == null, "образ сейфа — не машина");
            Check(Kind(@"AppData\Local\Docker-helper") == null, "похожее имя — не Docker");
            Check(Kind(@"AppData\Local\Packages\Microsoft.WindowsCalculator_8wekyb3d8bbwe") == null, "другое приложение из Store — не машина");
            Check(Kind("AppData") == null && Kind("Downloads") == null, "обычные папки — ничьи");
            Check(AppDataKinds.Of(@"D:\VMs\disk.vhdx", home) == null, "вне домашней папки — ничьё");
        });

        Section("Виртуальные машины: список и сколько они занимают", () =>
        {
            var home = Room("home-vms");
            List<VirtualMachine> Mine() => VirtualMachines.List(home).Where(m => m.Kind != MachineKind.Wsl).ToList();
            Check(Mine().Count == 0, "нет папок — нет машин, без ошибки");

            var linux = Path.Combine(home, @"VirtualBox VMs\Linux");
            Write("<VirtualBox/>", Path.Combine(linux, "Linux.vbox"));
            File.WriteAllBytes(Path.Combine(linux, "Linux.vdi"), new byte[3 << 20]);
            var windows = Path.Combine(home, @"VirtualBox VMs\Windows");
            Write("<VirtualBox/>", Path.Combine(windows, "Windows.vbox"));
            Sparse(Path.Combine(windows, "Windows.vdi"), 2L << 30);
            Write("notes", Path.Combine(home, @"VirtualBox VMs\notes.txt"));
            Directory.CreateDirectory(Path.Combine(home, @"VirtualBox VMs\Inbox"));
            var vmware = Path.Combine(home, @"Documents\Virtual Machines\Ubuntu");
            Write("config.version = \"8\"", Path.Combine(vmware, "Ubuntu.vmx"));
            Write("disk", Path.Combine(vmware, "Ubuntu.vmdk"));

            var machines = Mine();
            Check(machines.Select(m => m.Name).Order().SequenceEqual(["Linux", "Ubuntu", "Windows"]) && machines[0].Name == "Linux"
                  && machines.Zip(machines.Skip(1)).All(p => p.First.Bytes >= p.Second.Bytes),
                  $"в списке только машины, по убыванию занятого места: {string.Join(", ", machines.Select(m => m.Name))}");
            var l = machines.FirstOrDefault(m => m.Name == "Linux");
            var w = machines.FirstOrDefault(m => m.Name == "Windows");
            Check(l is { Kind: MachineKind.VirtualBox } && l.Bytes >= 3 << 20, $"размер машины — занятое на диске: {l?.Bytes}");
            Check(l?.LargestFile == 3 << 20, "самый большой файл — диск машины");
            Check(w != null && w.LogicalBytes >= 2L << 30 && w.Bytes < 64L << 20, $"у разрежённого диска полный объём отдельно от занятого: {w?.LogicalBytes} и {w?.Bytes}");
            Check(machines.First(m => m.Name == "Ubuntu").Kind == MachineKind.VMware, "машина VMware узнаётся по .vmx");
            Check(l?.Modified != null, "видно, когда машина менялась");
            Check(VirtualMachines.List(home).Where(m => m.Kind == MachineKind.Wsl).All(m => !m.Name.StartsWith("docker-desktop", StringComparison.OrdinalIgnoreCase)),
                  "служебные дистрибутивы Docker Desktop в списке машин не показываются");
        });

        if (Env("OFFLOAD_SKIP_DOCKER"))
        {
            Console.WriteLine("▸ Docker: архивация тома и возврат — пропущено (OFFLOAD_SKIP_DOCKER=1)");
            return;
        }
        var service = new DockerService();
        try { service.EnsureRunning(); }
        catch (DockerException ex)
        {
            Console.WriteLine($"▸ Docker: архивация тома и возврат — пропущено ({ex.Message})");
            return;
        }

        Section("Docker: архивация тома и возврат", () =>
        {
            // Только чтение и свой пробный том: очистку в проверках не запускаем — она удалила бы образы и кеш человека.
            var usage = service.Usage();
            Check(usage?.Images != null, $"docker system df разбирается: {usage}");
            var name = "offload-check-" + Guid.NewGuid().ToString("N")[..8];
            Runner.Check("docker", ["volume", "create", name], timeout: TimeSpan.FromSeconds(60));
            try
            {
                service.LastActivity(name);
                Runner.Check("docker", ["run", "--rm", "--log-driver", "none", "--network", "none", "-v", $"{name}:/v", DockerService.HelperImage,
                                        "sh", "-c", "mkdir -p /v/a/b && echo hello > '/v/a/b/файл с пробелом.txt' && ln -s b /v/a/link"],
                             timeout: TimeSpan.FromMinutes(2));
                var rawBefore = service.RawDiskBytes();
                var archive = service.Archive(name, Path.Combine(Scratch, "docker-archives"));
                Check(File.Exists(archive), $"архив создан: {Paths.Name(archive)}");
                if (rawBefore is { } before && service.RawDiskBytes() is { } after)
                    Check(after - before < 512L << 20, $"диск Docker не раздулся: {Format.Bytes(after - before)}");
                service.RemoveVolume(name);
                service.Restore(archive, name);
                var content = Runner.Check("docker", ["run", "--rm", "--log-driver", "none", "--network", "none", "-v", $"{name}:/v:ro", DockerService.HelperImage,
                                                      "cat", "/v/a/b/файл с пробелом.txt"], timeout: TimeSpan.FromMinutes(1));
                Check(content.Output == "hello\n", "том восстановлен из архива");
                ExpectError("существующий том не перезаписывается", () => service.Restore(archive, name),
                            ex => ex is DockerException { Kind: DockerErrorKind.AlreadyExists });
                ExpectError("опасное имя тома отклоняется до запуска docker", () => service.Archive(@"C:\Windows:/v", Scratch),
                            ex => ex is DockerException { Kind: DockerErrorKind.InvalidName });
                if (CanSymlink)
                {
                    var linked = Path.Combine(Scratch, "linked.tar");
                    FileLink(linked, archive);
                    ExpectError("архив-ссылка не распаковывается", () => service.Restore(linked, name + "-link"), ex => IsCopy(ex, CopyErrorKind.Unreadable));
                }
            }
            finally
            {
                try { Runner.Run("docker", ["volume", "rm", "-f", name], timeout: TimeSpan.FromMinutes(1)); } catch (RunnerException) { }
            }
        });
    }
}
