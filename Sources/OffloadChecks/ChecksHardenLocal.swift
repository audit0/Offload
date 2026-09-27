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

    section("Аудит: пути возврата, секреты бэкапа, журнал на недоверенном диске") {
        let rules = SafetyRules(home: scratch.appendingPathComponent("audit-home", isDirectory: true))
        try fm.createDirectory(at: rules.home, withIntermediateDirectories: true)
        // ~/.ssh ещё нет: realpath не приводит регистр, а на обычном диске Mac «.SSH» — та же папка.
        for relative in [".SSH/authorized_keys", ".Ssh", "Projects/app/.git/hooks/pre-commit", "Projects/app/.GIT/config"] {
            check(isBlocked(rules.pathVerdict(for: rules.home.appendingPathComponent(relative))),
                  "«~/\(relative)» запрещён независимо от регистра")
        }
        check(rules.pathVerdict(for: rules.home.appendingPathComponent("Projects/app")) == .safe, "сам проект с git переносить можно")

        for name in ["prod.env", ".env-local", ".env_local", "terraform.tfstate", "prod.tfvars", "credentials.json",
                     "service-account.json", "client_secret_123.json", "id_rsa.bak", "id_ed25519.old", ".vault-token",
                     ".htpasswd", ".zsh_history", "auth.json"] {
            check(BackupEngine.isSecret(name), "«\(name)» — секрет, в открытый бэкап не идёт")
        }
        for name in ["id_ed25519.pub", ".env.example", "package.json", "README.md", "venv"] {
            check(!BackupEngine.isSecret(name), "«\(name)» — не секрет")
        }
        let project = scratch.appendingPathComponent("audit-project", isDirectory: true)
        try write("[remote \"origin\"]\n\turl = https://me:ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com/me/app.git\n",
                  to: project.appendingPathComponent(".git/config"))
        try write("{\"type\": \"service_account\", \"private_key\": \"-----BEGIN\"}", to: project.appendingPathComponent("gcp.json"))
        try write("token: gho_abcdef\n", to: project.appendingPathComponent(".config/gh/hosts.yml"))
        try write("-----BEGIN OPENSSH PRIVATE KEY-----\n", to: project.appendingPathComponent(".deploy_key"))
        try write("{\"name\": \"app\"}", to: project.appendingPathComponent("package.json"))
        for relative in [".git/config", "gcp.json", ".config/gh/hosts.yml", ".deploy_key"] {
            check(BackupEngine.isSecretPath(relative, in: project), "«\(relative)» узнаётся как секрет по месту или содержимому")
        }
        check(!BackupEngine.isSecretPath("package.json", in: project), "обычный package.json — не секрет")

        // Журнал на внешнем диске: ссылка на /dev/zero или FIFO на его месте не должны подвешивать программу.
        let zero = scratch.appendingPathComponent("audit-manifest-zero.json")
        try fm.createSymbolicLink(atPath: zero.path, withDestinationPath: "/dev/zero")
        if case .broken = Journal.state(of: zero) { check(true, "журнал-ссылка на /dev/zero — «не читается», без зависания") }
        else { check(false, "журнал-ссылка на /dev/zero — «не читается», без зависания") }
        let fifo = scratch.appendingPathComponent("audit-manifest-fifo.json")
        check(mkfifo(fifo.path, 0o600) == 0, "FIFO для проверки создан")
        if case .broken = Journal.state(of: fifo) { check(true, "журнал-FIFO — «не читается», без зависания") }
        else { check(false, "журнал-FIFO — «не читается», без зависания") }
    }
}
