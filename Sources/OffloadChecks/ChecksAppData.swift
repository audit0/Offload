import Foundation
import OffloadCore

// Проверки для данных Docker и UTM: место из-под них освобождается средствами самих приложений.
// Вызывается из main.swift; check/section/write/scratch берутся оттуда же — это один модуль.

func checksAppData() {
    section("Docker: место внутри и очистка — разбор ответов docker") {
        let df = """
        Images\t25\t3\t12.34GB\t10.2GB (82%)
        Containers\t5\t1\t1.2MB\t1.1MB (91%)
        Local Volumes\t12\t4\t31.65GB\t20.1GB (63%)
        Build Cache\t120\t0\t5.6GB\t5.6GB
        """
        let usage = DockerService.parseUsage(df)
        check(usage?.images == DockerUsage.Part(count: 25, active: 3, bytes: 12_340_000_000, reclaimable: 10_200_000_000),
              "образы: сколько всего, сколько занято, размер и сколько можно убрать")
        check(usage?.containers == DockerUsage.Part(count: 5, active: 1, bytes: 1_200_000, reclaimable: 1_100_000), "контейнеры")
        check(usage?.volumes?.bytes == 31_650_000_000, "тома")
        check(usage?.buildCache?.reclaimable == 5_600_000_000, "кеш сборки — у него доли в скобках нет")
        check(usage?.reclaimable([.images, .buildCache]) == 15_800_000_000, "к очистке — образы и кеш, тома не в счёт")
        check(usage?.reclaimable([]) == 0, "ничего не выбрано — ничего не уйдёт")
        check(DockerService.parseUsage("Images\t2\t0\t0B\t0B\n") == DockerUsage(images: DockerUsage.Part(count: 2, active: 0, bytes: 0, reclaimable: 0)),
              "нули разбираются, отсутствующие строки остаются пустыми")
        check(DockerService.parseUsage("Cannot connect to the Docker daemon at unix:///var/run/docker.sock.") == nil,
              "ответ без таблицы — не разбор")

        check(DockerService.parseReclaimed("Deleted Images:\nuntagged: alpine:3\ndeleted: sha256:0123\n\nTotal reclaimed space: 7.8MB\n") == 7_800_000,
              "итог docker image prune")
        check(DockerService.parseReclaimed("ID\t\tRECLAIMABLE\tSIZE\tLAST ACCESSED\nk2f9*\ttrue\t1.2GB\t2 days ago\nTotal:\t5.6GB\n") == 5_600_000_000,
              "итог docker builder prune (buildx)")
        check(DockerService.parseReclaimed("Total reclaimed space: 0B\n") == 0, "удалять было нечего — ноль, а не «неизвестно»")
        check(DockerService.parseReclaimed("Deleted Containers:\n") == nil, "без итога — неизвестно")

        let arguments = DockerPruneTarget.allCases.map(DockerService.pruneArguments)
        check(!arguments.joined().contains { $0.hasPrefix("volume") } && !arguments.joined().contains("--volumes"),
              "очистка никогда не трогает тома")
        check(arguments.allSatisfy { $0.contains("--force") }, "docker не ждёт подтверждения, которого никто не даст")
        check(DockerPruneTarget.allCases.first == .containers, "контейнеры чистятся первыми — иначе их образы ещё заняты")
        check(!DockerService.pruneArguments(.danglingImages).contains("--all"),
              "образы без имени чистятся без --all: образы с именем, собранные человеком, остаются")
        check(DockerService.pruneArguments(.images).contains("--all"), "все неиспользуемые образы — только по отдельной галочке")
        check(DockerService.pruneOrder([.buildCache, .danglingImages]) == [.danglingImages, .buildCache],
              "сразу отмеченное: образы без имени и кеш сборки")
        check(DockerService.pruneOrder([.images, .danglingImages, .containers]) == [.containers, .images],
              "отмечены все образы — образы без имени второй раз не чистятся")
        check(DockerUsage().reclaimable([.danglingImages]) == 0, "размер образов без имени неизвестен — в оценку не входит")
    }

    section("Данные Docker и UTM: чьи это строки") {
        let home = scratch.appendingPathComponent("home-appdata", isDirectory: true)
        func kind(_ relative: String) -> AppData? { AppData.kind(of: home.appendingPathComponent(relative), home: home) }
        check(kind("Library/Containers/com.docker.docker") == .docker, "контейнер Docker")
        check(kind("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw") == .docker, "Docker.raw")
        check(kind("Library/Containers/com.utmapp.UTM") == .utm, "контейнер UTM")
        check(kind("Library/Containers/com.utmapp.UTM/Data/Documents/Linux.utm") == .utm, "машина в папке UTM")
        check(kind("Downloads/vms/Debian.utm") == .utm, "машина, открытая в UTM из другой папки")
        check(kind("Library/Caches/com.utmapp.UTM") == nil, "кеш UTM — не машина, хоть и оканчивается на «.UTM»")
        check(kind("Library/Group Containers/WDNLXAD4W8.com.utmapp.UTM") == nil, "группа приложений UTM — не машина")
        let rules = SafetyRules(home: home)
        func blocked(_ relative: String) -> Bool { rules.verdict(for: home.appendingPathComponent(relative), content: nil).isBlocked }
        check(blocked("Library/Logs/my.test.utm"), "машина с именем-идентификатором в Logs не переносится: исключение — только для папок приложений")
        check(!blocked("Library/Logs/app.log"), "обычный лог в Logs переносить по-прежнему можно")
        check(blocked("Library/Containers/com.utmapp.UTM"), "папка UTM по-прежнему не переносится")
        check(kind("Library/Containers/com.docker.docker-helper") == nil, "похожее имя — не Docker")
        check(kind("Library/Containers") == nil && kind("Downloads") == nil, "обычные папки — ничьи")
    }

    section("UTM: машины и сколько они занимают") {
        let home = scratch.appendingPathComponent("home-utm", isDirectory: true)
        let folder = UTMMachines.folder(home: home)
        check(folder.path.hasSuffix("Library/Containers/com.utmapp.UTM/Data/Documents"), "машины ищутся там, где их хранит UTM")
        check(UTMMachines.list(in: folder).isEmpty, "нет папки — нет машин, без ошибки")

        let big = folder.appendingPathComponent("Linux.utm", isDirectory: true)
        try write(String(repeating: "x", count: 3 << 20), to: big.appendingPathComponent("Data/disk.qcow2"))
        try write("<plist/>", to: big.appendingPathComponent("config.plist"))
        // Разрежённый диск: весит 2 ГБ, а на диске почти ничего.
        let sparse = folder.appendingPathComponent("Mac.utm/Data/disk.img")
        try write("", to: sparse)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 2 << 30)
        try handle.close()
        try write("<plist/>", to: folder.appendingPathComponent("Mac.utm/config.plist"))
        try write("notes", to: folder.appendingPathComponent("notes.txt"))
        try fm.createDirectory(at: folder.appendingPathComponent("Inbox", isDirectory: true), withIntermediateDirectories: true)

        let machines = UTMMachines.list(in: folder)
        check(machines.map(\.name) == ["Linux", "Mac"], "в списке только машины, по убыванию занятого места: \(machines.map(\.name))")
        let linux = machines.first { $0.name == "Linux" }
        let mac = machines.first { $0.name == "Mac" }
        check((linux?.bytes ?? 0) >= 3 << 20, "размер машины — занятое на диске, как у du: \(linux?.bytes ?? 0)")
        check(linux?.largestFile == 3 << 20, "самый большой файл — диск машины")
        check((mac?.logicalBytes ?? 0) >= 2 << 30 && (mac?.bytes ?? .max) < 64 << 20,
              "у разрежённого диска полный объём отдельно от занятого: \(mac?.logicalBytes ?? 0) и \(mac?.bytes ?? 0)")
        check(linux?.modified != nil, "видно, когда машина менялась")
        check(UTMMachines.isMachine(big) && !UTMMachines.isMachine(home.appendingPathComponent("Library/Containers/com.utmapp.UTM")),
              "контейнер UTM — не машина")
    }
}
