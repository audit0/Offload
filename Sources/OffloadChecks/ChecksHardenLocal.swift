import Darwin
import Foundation
import OffloadCore

// Проверки без дисковых образов: разворачивание домашней папки и осмотр настоящих файлов.
// Вызывается из main.swift; check/section/scratch/fm/write берутся оттуда же — это один модуль.

func checksHardenLocal() {
    section("Домашняя папка, заданная через символическую ссылку") {
        // Дом бывает не там, куда на него показывают: домашнюю папку переносят на внешний диск,
        // а в /Users оставляют ссылку. Правила разворачивают ссылки в проверяемом пути —
        // значит, и сам дом обязаны развернуть так же, иначе любой обычный путь внутри дома
        // окажется для них «вне домашней папки» и переносить будет нечего.
        let real = scratch.appendingPathComponent("harden-home-real", isDirectory: true)
        try fm.createDirectory(at: real.appendingPathComponent("Downloads/данные"), withIntermediateDirectories: true)
        let link = scratch.appendingPathComponent("harden-home-link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)

        let rules = SafetyRules(home: link)
        check(rules.home.path == real.path, "дом развёрнут до настоящего пути (\(rules.home.path))")
        check(rules.pathVerdict(for: real.appendingPathComponent("Downloads/архив.zip")) == .safe,
              "обычный путь внутри дома считается своим, а не чужим")
        check(rules.pathVerdict(for: link.appendingPathComponent("Downloads/архив.zip")) == .safe,
              "тот же путь, записанный через ссылку, — тоже свой")
        // Дальше важно не просто «запрещено», а запрещено по своему правилу: с неразвёрнутым
        // домом всё внутри него отвергалось бы одной общей причиной «переносить можно только
        // из домашней папки», и разницы между домом, ключами и обычным файлом не осталось бы.
        check(isBlocked(rules.pathVerdict(for: real), containing: "целиком"),
              "сам дом запрещён как дом: \(rules.pathVerdict(for: real).notes)")
        check(isBlocked(rules.pathVerdict(for: real.appendingPathComponent(".ssh/id_ed25519")), containing: "ключи"),
              "правило про ~/.ssh работает и по настоящему пути")
        check(isBlocked(rules.pathVerdict(for: real.appendingPathComponent("Downloads")), containing: "стандартная папка"),
              "стандартная папка внутри дома узнаётся по настоящему пути")

        let volume = VolumeInfo(mountPoint: URL(fileURLWithPath: "/Volumes/Внешний"), name: "Внешний", fsType: "exfat",
                                totalBytes: 1 << 40, availableBytes: 1 << 40, blockSize: 131_072,
                                isReadOnly: false, isInternal: false)
        let target = SafeMover(rules: rules).targetURL(for: link.appendingPathComponent("Downloads/данные"), on: volume)
        check(target.path == "/Volumes/Внешний/Offload/Downloads/данные",
              "в архиве виден путь от дома, а не одно имя папки (\(target.path))")
    }

    section("Осмотр настоящих файлов: метки Finder и жёсткие ссылки") {
        let room = scratch.appendingPathComponent("harden-inspect", isDirectory: true)

        func setXattr(_ name: String, on url: URL) throws {
            let value = Array("1".utf8)
            guard setxattr(url.path, name, value, value.count, 0, XATTR_NOFOLLOW) == 0 else {
                throw CopyError.writeFailed(url.path, "setxattr \(name): \(String(cString: strerror(errno)))")
            }
        }
        func folder(_ name: String, file: String, xattrs: [String]) throws -> URL {
            let directory = room.appendingPathComponent(name, isDirectory: true)
            let url = directory.appendingPathComponent(file)
            try write("содержимое", to: url)
            for attribute in xattrs { try setXattr(attribute, on: url) }
            return directory
        }

        // Метку и комментарий человек ставит руками и потерю заметит: об этом и предупреждают.
        let tagged = try folder("метка", file: "a.txt", xattrs: ["com.apple.metadata:_kMDItemUserTags"])
        check(Inspector.inspect(tagged).taggedFiles == 1, "метка Finder на настоящем файле заметна")
        let commented = try folder("комментарий", file: "b.txt", xattrs: ["com.apple.metadata:kMDItemFinderComment"])
        check(Inspector.inspect(commented).taggedFiles == 1, "комментарий Finder на настоящем файле заметен")

        // А это macOS ставит сама. kMDItemWhereFroms достаётся каждому скачанному файлу:
        // пока он считался заметным, предупреждение про метки загоралось почти на любой папке
        // из Загрузок и значить перестало.
        let downloaded = try folder("скачанное", file: "c.dmg",
                                    xattrs: ["com.apple.quarantine", "com.apple.provenance",
                                             "com.apple.metadata:kMDItemWhereFroms"])
        let routine = Inspector.inspect(downloaded)
        check(routine.files == 1 && routine.taggedFiles == 0,
              "карантин, происхождение и «откуда скачано» заметными не считаются (\(routine.taggedFiles))")

        // Одна настоящая метка среди скачанных файлов — и предупреждение обязано появиться.
        let mixed = try folder("вперемешку", file: "с-меткой.txt", xattrs: ["com.apple.metadata:_kMDItemUserTags"])
        try write("ещё", to: mixed.appendingPathComponent("скачанный.zip"))
        try setXattr("com.apple.metadata:kMDItemWhereFroms", on: mixed.appendingPathComponent("скачанный.zip"))
        let mixedReport = Inspector.inspect(mixed)
        check(mixedReport.files == 2 && mixedReport.taggedFiles == 1,
              "среди скачанных файлов заметен ровно помеченный (\(mixedReport.taggedFiles) из \(mixedReport.files))")
        let volume = VolumeInfo(mountPoint: URL(fileURLWithPath: "/Volumes/Внешний"), name: "Внешний", fsType: "exfat",
                                totalBytes: 1 << 40, availableBytes: 1 << 40, blockSize: 131_072,
                                isReadOnly: false, isInternal: false)
        let notes = SafetyRules.checkDestination(volume, sourceVolume: nil, content: mixedReport).notes.joined(separator: " ")
        check(notes.contains("метки Finder"), "о потере настоящей метки предупреждают до переноса")

        // Два имени одного файла: копия сделает из них два независимых файла, места уйдёт вдвое,
        // и правка одного перестанет быть видна в другом. Узнаётся это только по st_nlink.
        let hard = room.appendingPathComponent("жёсткие", isDirectory: true)
        try write("один и тот же файл", to: hard.appendingPathComponent("первое имя.bin"))
        guard link(hard.appendingPathComponent("первое имя.bin").path, hard.appendingPathComponent("второе имя.bin").path) == 0 else {
            throw CopyError.writeFailed(hard.path, String(cString: strerror(errno)))
        }
        let hardReport = Inspector.inspect(hard)
        check(hardReport.files == 2 && hardReport.hardLinkedFiles == 2,
              "оба имени одного файла посчитаны как жёсткие ссылки (\(hardReport.hardLinkedFiles) из \(hardReport.files))")
        check(Inspector.inspect(tagged).hardLinkedFiles == 0, "обычный файл жёсткой ссылкой не считается")
        let hardNotes = SafetyRules.checkDestination(volume, sourceVolume: nil, content: hardReport).notes.joined(separator: " ")
        check(hardNotes.contains("жёсткие ссылки"), "о разрыве настоящих жёстких ссылок предупреждают до переноса")
    }
}
