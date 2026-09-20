import Darwin
import Foundation
import OffloadCore

// Проверки ядра Offload. XCTest и swift-testing есть только в Xcode, поэтому здесь свой минимальный раннер.
// Запуск: swift run OffloadChecks
//   OFFLOAD_SKIP_INTEGRATION=1 — без проверок на настоящих дисковых образах (hdiutil)
//   OFFLOAD_SKIP_DOCKER=1      — без проверок с Docker

var passed = 0
var failed = 0

func check(_ condition: @autoclosure () throws -> Bool, _ message: String, line: Int = #line) {
    do {
        if try condition() {
            passed += 1
        } else {
            failed += 1
            print("  ✗ \(message) [строка \(line)]")
        }
    } catch {
        failed += 1
        print("  ✗ \(message): \(error) [строка \(line)]")
    }
}

func expectError(_ message: String, line: Int = #line, _ body: () throws -> Void, matching: (Error) -> Bool = { _ in true }) {
    do {
        try body()
        failed += 1
        print("  ✗ \(message): ошибки не было [строка \(line)]")
    } catch {
        if matching(error) {
            passed += 1
        } else {
            failed += 1
            print("  ✗ \(message): неожиданная ошибка \(error) [строка \(line)]")
        }
    }
}

func section(_ title: String, _ body: () throws -> Void) {
    print("▸ \(title)")
    do { try body() } catch {
        failed += 1
        print("  ✗ раздел прерван: \(error)")
    }
}

func isCaution(_ verdict: Verdict) -> Bool {
    if case .caution = verdict { return true }
    return false
}

func isBlocked(_ verdict: Verdict, containing text: String? = nil) -> Bool {
    guard case .blocked(let reason) = verdict else { return false }
    return text.map { reason.contains($0) } ?? true
}

let fm = FileManager.default
let env = ProcessInfo.processInfo.environment
let scratch = fm.temporaryDirectory.appendingPathComponent("offload-checks-\(UUID().uuidString)", isDirectory: true)
    .resolvingSymlinksInPath()
try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
Journal.localOverride = scratch.appendingPathComponent("history.json")

func write(_ text: String, to url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: false, encoding: .utf8)
}

func mode(_ url: URL) -> Int? {
    ((try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue
}

func mountPoint(fromAttachPlist data: Data) -> URL? {
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let entities = plist["system-entities"] as? [[String: Any]],
          let mount = entities.compactMap({ $0["mount-point"] as? String }).first else { return nil }
    return URL(fileURLWithPath: mount, isDirectory: true)
}

// MARK: - Правила

section("Правила безопасности: пути") {
    let rules = SafetyRules(home: scratch.appendingPathComponent("home-a", isDirectory: true))
    func verdict(_ relative: String) -> Verdict { rules.pathVerdict(for: rules.home.appendingPathComponent(relative)) }

    check(isBlocked(rules.pathVerdict(for: rules.home)), "домашняя папка целиком запрещена")
    check(isBlocked(rules.pathVerdict(for: URL(fileURLWithPath: "/etc/hosts"))), "вне домашней папки запрещено")
    check(isBlocked(verdict("Downloads")), "стандартная папка целиком запрещена")
    check(verdict("Downloads/archive.zip") == .safe, "файл в Загрузках разрешён")
    check(isBlocked(verdict("Downloads/vms/Debian.utm")), "пакет UTM запрещён")
    check(isBlocked(verdict("Downloads/home/debian/18.1/Whonix-Gateway.utm/Data/disk.raw"), containing: "Whonix-Gateway.utm"),
          "файл внутри пакета UTM запрещён")
    check(isBlocked(verdict("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"), containing: "Docker"),
          "Docker.raw — с подсказкой про раздел Docker")
    check(isBlocked(verdict("Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable"), containing: "Telegram"),
          "кеш Telegram — с подсказкой")
    check(isBlocked(verdict("Library/Application Support/Claude/vm_bundles/claudevm.bundle")), "виртуалка Claude запрещена")
    check(verdict("Library/iTunes/iPhone Software Updates/iPhone.ipsw") == .safe, "прошивка iPhone разрешена")
    check(verdict("Library/Application Support/com.gamemac.www/wine-engine/wine-logs/run.log") == .safe, "лог-файл разрешён")
    check(isBlocked(verdict("Library/Application Support/SomeApp/data.db")), "данные приложений в Library запрещены")
    check(isCaution(verdict("Library/Application Support/MobileSync/Backup/0000")), "бэкап iPhone — с предупреждением")
    check(isBlocked(verdict(".ssh/id_ed25519")), "~/.ssh запрещена")
    check(isBlocked(verdict(".lmstudio")), "скрытая папка приложения целиком запрещена")
    check(isCaution(verdict(".lmstudio/models")), "данные внутри скрытой папки — с предупреждением")
    check(isBlocked(rules.pathVerdict(for: URL(fileURLWithPath: "/Users/Shared/Library/Application Support/BlueStacks"))),
          "BlueStacks в /Users/Shared запрещён")
}

section("Проверка содержимого") {
    let rules = SafetyRules(home: scratch.appendingPathComponent("home-b", isDirectory: true))
    let folder = rules.home.appendingPathComponent("Downloads/stuff", isDirectory: true)
    try write("a", to: folder.appendingPathComponent("a.txt"))
    try fm.createDirectory(at: folder.appendingPathComponent("vms/Test.utm/Data"), withIntermediateDirectories: true)
    try fm.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "a.txt")
    try fm.createDirectory(at: folder.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
    let report = Inspector.inspect(folder)
    check(report.registeredBundle == "vms/Test.utm", "найден вложенный пакет UTM (ловушка с папками home)")
    check(report.symlinkCount == 1, "посчитана символическая ссылка")
    check(report.containsGitRepo, "найден git-репозиторий")
    check(rules.verdict(for: folder, content: report).isBlocked, "папка с вложенной виртуалкой запрещена")

    let clean = rules.home.appendingPathComponent("Downloads/clean", isDirectory: true)
    try write("b", to: clean.appendingPathComponent("b.txt"))
    let fresh = rules.verdict(for: clean, content: Inspector.inspect(clean))
    check(fresh.notes.contains { $0.contains("Менялось") } && isCaution(fresh), "свежие файлы — с предупреждением")
    check(rules.verdict(for: clean, content: Inspector.inspect(clean), now: Date().addingTimeInterval(30 * 86_400)) == .safe,
          "давно не менявшиеся файлы разрешены без оговорок")
    check(rules.verdict(for: clean, content: nil, openBy: ["Preview"]).isBlocked, "открытые файлы запрещают перенос")
}

section("Проверка диска назначения") {
    func volume(_ fs: String, free: Int64 = 100 << 30, readOnly: Bool = false) -> VolumeInfo {
        VolumeInfo(mountPoint: URL(fileURLWithPath: "/Volumes/X"), name: "X", fsType: fs, totalBytes: 500 << 30,
                   availableBytes: free, blockSize: 131_072, isReadOnly: readOnly, isInternal: false)
    }
    var content = ContentReport()
    content.files = 10
    content.directories = 2
    content.logicalBytes = 1 << 30
    content.allocatedBytes = 1 << 30
    content.symlinkCount = 3
    let exfat = SafetyRules.checkDestination(volume("exfat"), sourceVolume: nil, content: content)
    check(exfat.isOK, "exFAT с символическими ссылками допустим: \(exfat.blockers)")
    check(exfat.notes.contains { $0.contains("Символических ссылок") }, "есть пояснение про ссылки на exFAT")
    var big = content
    big.largestFile = 5 << 30
    check(!SafetyRules.checkDestination(volume("msdos"), sourceVolume: nil, content: big).isOK, "FAT32 не принимает файл больше 4 ГБ")
    check(!SafetyRules.checkDestination(volume("exfat", free: 100 << 20), sourceVolume: nil, content: content).isOK, "мало места — запрет")
    check(!SafetyRules.checkDestination(volume("apfs", readOnly: true), sourceVolume: nil, content: content).isOK, "только чтение — запрет")
    check(!SafetyRules.checkDestination(volume("apfs"), sourceVolume: volume("apfs"), content: content).isOK, "тот же диск — запрет")
    var sparse = content
    sparse.sparseFiles = 1
    sparse.allocatedBytes = 100 << 20
    check(SafetyRules.checkDestination(volume("exfat"), sourceVolume: nil, content: sparse).notes.contains { $0.contains("Разрежённые") },
          "предупреждение о разрежённых файлах")
}

// MARK: - Низкий уровень

section("Запуск программ и хеши") {
    check(Runner.locate("hdiutil")?.path == "/usr/bin/hdiutil", "hdiutil берётся из системного каталога")
    check(Runner.locate("../bin/sh") == nil, "путь вместо имени программы отклоняется")
    let hostile = "a b; touch /tmp/offload-pwned $(id) `id`"
    let echoed = try Runner.check("echo", [hostile])
    check(echoed.output == hostile + "\n", "аргументы не интерпретируются оболочкой")
    check(!fm.fileExists(atPath: "/tmp/offload-pwned"), "подстановка команды не выполнилась")
    check(try Runner.check("cat", [], stdin: Data("секрет".utf8)).output == "секрет", "stdin передаётся программе")
    expectError("зависшая программа прерывается по таймауту", { _ = try Runner.run("sleep", ["5"], timeout: 0.3) },
                matching: { ($0 as? RunnerError) == .timedOut("sleep") })
    let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check(FileHasher.sha256(of: Data("abc".utf8)) == abc, "SHA-256 по эталону")
    let file = scratch.appendingPathComponent("abc.txt")
    try write("abc", to: file)
    check(try FileHasher.sha256(of: file) == abc, "SHA-256 файла по эталону")
}

section("Копирование со сверкой") {
    let source = scratch.appendingPathComponent("copy-src", isDirectory: true)
    try write("hello", to: source.appendingPathComponent("a.txt"))
    try write("", to: source.appendingPathComponent("empty"))
    try write("nested", to: source.appendingPathComponent("dir/sub/n.txt"))
    try write("user file", to: source.appendingPathComponent("._real"))
    try fm.createSymbolicLink(atPath: source.appendingPathComponent("dir/link").path, withDestinationPath: "sub/n.txt")
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("a.txt").path)

    let entries = try TreeWalker.walk(source, strict: true).entries
    check(entries.count == 8, "обход видит все объекты, включая корень, ссылку и файл ._real (\(entries.count))")
    check(Inspector.inspect(source).files == entries.filter(\.isFile).count, "Inspector и TreeWalker видят одинаковое число файлов")

    let destination = scratch.appendingPathComponent("copy-dst", isDirectory: true)
    let hashes = try VerifiedCopy.copyTree(entries, from: source, to: destination, keepPermissions: true)
    try VerifiedCopy.verify(entries, hashes: hashes, at: destination)
    check(try fm.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("dir/link").path) == "sub/n.txt",
          "ссылка скопирована как ссылка")
    check(mode(destination.appendingPathComponent("a.txt")) == 0o755, "права доступа сохранены")
    try VerifiedCopy.assertUnchanged(entries, at: source)

    try write("fake sidecar", to: destination.appendingPathComponent("._a.txt"))
    VerifiedCopy.removeAppleDouble(for: entries, at: destination)
    check(!fm.fileExists(atPath: destination.appendingPathComponent("._a.txt").path), "служебный ._-файл удалён")
    check(fm.fileExists(atPath: destination.appendingPathComponent("._real").path), "настоящий файл с именем на ._ сохранён")

    try write("NESTED", to: destination.appendingPathComponent("dir/sub/n.txt"))
    expectError("порча копии того же размера обнаруживается сверкой", { try VerifiedCopy.verify(entries, hashes: hashes, at: destination) },
                matching: { ($0 as? CopyError) == .verificationFailed("dir/sub/n.txt") })

    try write("changed!", to: source.appendingPathComponent("a.txt"))
    expectError("изменение источника во время переноса обнаруживается", { try VerifiedCopy.assertUnchanged(entries, at: source) },
                matching: { ($0 as? CopyError) == .changedDuringCopy("a.txt") })

    let victim = scratch.appendingPathComponent("victim.txt")
    try write("do not touch", to: victim)
    let trap = scratch.appendingPathComponent("trap")
    try fm.createSymbolicLink(atPath: trap.path, withDestinationPath: victim.path)
    expectError("подложенная ссылка на месте копии не срабатывает",
                { _ = try VerifiedCopy.copyFile(from: source.appendingPathComponent("a.txt"), to: trap) })
    check(try String(contentsOf: victim, encoding: .utf8) == "do not touch", "файл, на который указывала ссылка, не изменился")

    let list = VerifiedCopy.checksumList(["": "ab", "x\ny": "cd"], rootName: "item")
    check(list.contains("ab  item\n") && list.contains("\\cd  item/x\\ny"), "имена с переводом строки экранируются для shasum")

    let sample = ["": String(repeating: "a", count: 64), "dir/f.txt": String(repeating: "b", count: 64),
                  "x\ny": String(repeating: "c", count: 64)]
    let parsed = VerifiedCopy.parseChecksumList(VerifiedCopy.checksumList(sample, rootName: "item"), rootName: "item")
    check(parsed == sample, "список контрольных сумм читается обратно, включая имя с переводом строки")
    check(VerifiedCopy.parseChecksumList("мусор\n", rootName: "item") == nil, "чужой файл вместо списка сумм не разбирается")
}

section("Финдер не срывает перенос") {
    let source = scratch.appendingPathComponent("ds-src", isDirectory: true)
    try write("data", to: source.appendingPathComponent("sub/file.txt"))
    let entries = try TreeWalker.walk(source, strict: true).entries
    // Finder пишет .DS_Store, когда человек просто открывает папку и меняет вид окна.
    try write("", to: source.appendingPathComponent("sub/.DS_Store"))
    check({ () -> Bool in
        do { try VerifiedCopy.assertUnchanged(entries, at: source); return true } catch { return false }
    }(), "появление .DS_Store не считается изменением источника")
    try write("new", to: source.appendingPathComponent("sub/other.txt"))
    expectError("настоящий новый файл в папке по-прежнему останавливает перенос",
                { try VerifiedCopy.assertUnchanged(entries, at: source) },
                matching: { if case CopyError.changedDuringCopy = $0 { return true }; return false })
}

section("Журнал") {
    let manifestVolume = VolumeInfo(mountPoint: scratch.appendingPathComponent("journal-disk", isDirectory: true), name: "J",
                                    fsType: "apfs", totalBytes: 1, availableBytes: 1, blockSize: 4096,
                                    isReadOnly: false, isInternal: false)
    let manifest = Journal.manifestURL(on: manifestVolume)
    let archived = manifestVolume.mountPoint.appendingPathComponent("Offload/Downloads/one").path
    let first = MoveRecord(originalPath: scratch.appendingPathComponent("j-home/Downloads/one").path,
                           archivedPath: archived, volumeName: "J", files: 1, bytes: 10)
    try Journal.save(first, volume: manifestVolume)
    check(Journal.records(on: manifestVolume).count == 1, "запись попала в журнал на диске")

    try write("{это не журнал", to: manifest)
    let second = MoveRecord(originalPath: scratch.appendingPathComponent("j-home/Downloads/two").path,
                            archivedPath: manifestVolume.mountPoint.appendingPathComponent("Offload/Downloads/two").path,
                            volumeName: "J", files: 1, bytes: 10)
    try Journal.save(second, volume: manifestVolume)
    let afterBreak = Journal.records(on: manifestVolume)
    check(afterBreak.count == 2, "испорченный журнал восстановлен из второй копии, а не начат с нуля (\(afterBreak.count))")
    let brokenCopies = ((try? fm.contentsOfDirectory(atPath: manifest.deletingLastPathComponent().path)) ?? [])
        .filter { $0.hasPrefix("manifest.json.broken-") }
    check(brokenCopies.count == 1, "испорченный файл отложен рядом, а не затёрт (\(brokenCopies))")
}

section("Размеры папок") {
    let folder = scratch.appendingPathComponent("home-sizes/sized", isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(repeating: 0x5a, count: 5 << 20).write(to: folder.appendingPathComponent("blob"))
    let item = SpaceScanner.measure(folder, rules: SafetyRules(home: scratch.appendingPathComponent("home-sizes")))
    if item.bytes < 5 << 20 {
        let raw = try? Runner.run("du", ["-sk", "-x", "--", folder.path])
        print("  du: status \(raw?.status ?? -1), stdout «\(raw?.output ?? "")», stderr «\(raw?.stderr ?? "")»")
    }
    check(item.bytes >= 5 << 20, "размер папки считается через du (\(item.bytes) байт)")
    check(!item.accessDenied && item.isDirectory && item.verdict == .safe, "папка читается и разрешена к переносу")
}

section("Бэкап") {
    check(BackupEngine.isSecret(".env") && BackupEngine.isSecret(".env.production"), ".env считается секретом")
    check(!BackupEngine.isSecret(".env.example"), ".env.example — не секрет")
    check(BackupEngine.isSecret("id_ed25519") && BackupEngine.isSecret("server.KEY") && BackupEngine.isSecret("vault.kdbx"),
          "ключи и базы паролей — секреты")
    check(!BackupEngine.isSecret("id_ed25519.pub") && !BackupEngine.isSecret("README.md"), "публичный ключ и обычные файлы — не секреты")
    check(BackupEngine.isSecret(".envrc") && BackupEngine.isSecret("key.p8") && BackupEngine.isSecret("credentials"),
          ".envrc, ключ Apple .p8 и файл credentials — секреты")
    check(BackupEngine.isSecretFolder(".ssh") && BackupEngine.isSecretFolder(".gnupg") && BackupEngine.isSecretFolder(".aws"),
          "каталоги с ключами распознаются целиком")

    let keyProbe = scratch.appendingPathComponent("key-probe", isDirectory: true)
    try write("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n", to: keyProbe.appendingPathComponent("deploy_key"))
    try write("just text\n", to: keyProbe.appendingPathComponent("NOTES"))
    check(BackupEngine.isSecretPath("deploy_key", in: keyProbe), "ключ без расширения узнаётся по первым байтам")
    check(!BackupEngine.isSecretPath("NOTES", in: keyProbe), "обычный файл без расширения секретом не считается")
    check(BackupEngine.isSecretPath(".ssh/config", in: keyProbe), "файл внутри .ssh — секрет по каталогу")

    let project = scratch.appendingPathComponent("proj", isDirectory: true)
    try write("code", to: project.appendingPathComponent("main.swift"))
    try write("TOKEN=1", to: project.appendingPathComponent(".env"))
    try write("dep", to: project.appendingPathComponent("node_modules/lib/index.js"))
    try write("export AWS_SECRET_ACCESS_KEY=1", to: project.appendingPathComponent(".envrc"))
    try write("key", to: project.appendingPathComponent(".ssh/id_work"))
    let backup = scratch.appendingPathComponent("backup", isDirectory: true)
    let first = try BackupEngine.run(sources: [project], destination: backup)
    check(fm.fileExists(atPath: backup.appendingPathComponent("proj/main.swift").path), "код попал в бэкап")
    check(!fm.fileExists(atPath: backup.appendingPathComponent("proj/.env").path), ".env не попал в открытый бэкап")
    check(!fm.fileExists(atPath: backup.appendingPathComponent("proj/.envrc").path), ".envrc не попал в открытый бэкап")
    check(!fm.fileExists(atPath: backup.appendingPathComponent("proj/.ssh").path), "папка .ssh внутри проекта не попала в открытый бэкап")
    check(Set(first.secretsSkipped) == ["proj/.env", "proj/.envrc", "proj/.ssh/"], "пропущенные секреты отмечены в отчёте (\(first.secretsSkipped))")
    check(!fm.fileExists(atPath: backup.appendingPathComponent("proj/node_modules").path), "node_modules исключены")
    let second = try BackupEngine.run(sources: [project], destination: backup)
    check(second.copied == 0 && second.unchanged >= 1, "повторный бэкап ничего не копирует заново")
    try write("code v2", to: project.appendingPathComponent("main.swift"))
    check(try BackupEngine.run(sources: [project], destination: backup).copied == 1, "изменённый файл копируется")
    expectError("бэкап внутрь копируемой папки запрещён",
                { _ = try BackupEngine.run(sources: [project], destination: project.appendingPathComponent("backup")) })
}

section("Место на диске назначения") {
    var content = ContentReport()
    content.files = 1
    content.directories = 1
    content.logicalBytes = 200 << 30
    content.allocatedBytes = 20 << 30
    content.sparseFiles = 1
    let apfs = VolumeInfo(mountPoint: URL(fileURLWithPath: "/Volumes/Probe"), name: "Probe", fsType: "apfs",
                          totalBytes: 500 << 30, availableBytes: 60 << 30, blockSize: 4096, isReadOnly: false, isInternal: false)
    let sparse = SafetyRules.checkDestination(apfs, sourceVolume: nil, content: content)
    // Копия пишется обычной записью, дыры не переносятся: на приёмнике будет полный размер.
    check(!sparse.isOK, "разрежённый файл на 200 ГБ не пускают на диск, где свободно 60 ГБ")
    check(sparse.notes.contains { $0.contains("полный размер") }, "про разрежённые файлы сказано и на APFS")

    var tagged = ContentReport()
    tagged.files = 2
    tagged.logicalBytes = 1 << 20
    tagged.taggedFiles = 2
    tagged.hardLinkedFiles = 3
    let notes = SafetyRules.checkDestination(apfs, sourceVolume: nil, content: tagged).notes.joined(separator: " ")
    check(notes.contains("метки Finder"), "о потере меток Finder предупреждают заранее")
    check(notes.contains("жёсткие ссылки"), "о разрыве жёстких ссылок предупреждают заранее")
}

section("Docker: имена и размеры") {
    check(DockerService.isValidVolumeName("openwrt-build-arm64") && DockerService.isValidVolumeName("ok_name.1"), "обычные имена томов допустимы")
    for bad in ["a", "-rm", "/Users/q:/v", "x:y", "name with space", "../etc", ""] {
        check(!DockerService.isValidVolumeName(bad), "имя «\(bad)» отклоняется")
    }
    check(DockerService.volumeName(fromArchive: URL(fileURLWithPath: "/Volumes/SSD/vol-1.tar.zst")) == "vol-1", "имя тома из имени архива")
    check(DockerService.volumeName(fromArchive: URL(fileURLWithPath: "/Volumes/SSD/vol (2).tar.zst")) == nil,
          "имя архива с пробелом не превращается в имя тома")
    check(DockerService.parseSize("31.65GB") == 31_650_000_000, "31.65GB разбирается без ошибки округления")
    check(DockerService.parseSize("1.002kB") == 1_002 && DockerService.parseSize("264B") == 264, "мелкие размеры разбираются")
    check(DockerService.parseSize("N/A") == nil, "мусор вместо размера не разбирается")
    let disk = scratch.appendingPathComponent("docker-disk", isDirectory: true)
    try write("", to: disk.appendingPathComponent("Offload/docker-volumes/a.tar.zst"))
    try write("", to: disk.appendingPathComponent("Archive-2026/docker-volumes/b.tar"))
    try write("", to: disk.appendingPathComponent("Archive-2026/docker-volumes/notes.txt"))
    let found = DockerService.archives(on: VolumeInfo(mountPoint: disk, name: "d", fsType: "apfs", totalBytes: 1, availableBytes: 1,
                                                       blockSize: 4096, isReadOnly: false, isInternal: false)).map(\.lastPathComponent)
    check(Set(found) == ["a.tar.zst", "b.tar"], "архивы томов находятся и в Offload, и в ручных папках docker-volumes (\(found))")
}

section("Память") {
    let snapshot = MemoryStats.snapshot()
    check(snapshot.physicalBytes > 0, "объём памяти известен")
    check(snapshot.swapUsedBytes <= snapshot.swapTotalBytes, "swap: занято не больше, чем всего")
    check(!snapshot.apps.isEmpty, "видны приложения")
    check(MemoryStats.appName(forExecutable: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)") == "Google Chrome",
          "процессы-помощники относятся к своему приложению")
    check(MemoryStats.appName(forExecutable: "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine") == MemoryStats.virtualMachinesName,
          "виртуальные машины распознаются")
}

// MARK: - Интеграция

if env["OFFLOAD_SKIP_INTEGRATION"] != "1" {
    section("Перенос на настоящий exFAT и возврат") {
        let image = scratch.appendingPathComponent("exfat.sparseimage")
        try Runner.check("hdiutil", ["create", "-size", "1g", "-type", "SPARSE", "-fs", "ExFAT", "-volname", "OFFCHECK", "-quiet", image.path], timeout: 180)
        guard let mount = mountPoint(fromAttachPlist: try Runner.check("hdiutil", ["attach", "-nobrowse", "-plist", image.path], timeout: 120).stdout) else {
            throw CopyError.unreadable(image.path)
        }
        defer { _ = try? Runner.run("hdiutil", ["detach", "-force", mount.path], timeout: 60) }
        guard let volume = Volumes.info(for: mount) else { throw CopyError.unreadable(mount.path) }
        check(volume.fsType == "exfat", "тестовый том — exFAT (\(volume.fsType))")

        let rules = SafetyRules(home: scratch.appendingPathComponent("home-move", isDirectory: true))
        let source = rules.home.appendingPathComponent("Downloads/project", isDirectory: true)
        try write("#!/bin/sh\necho hi\n", to: source.appendingPathComponent("run.sh"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("run.sh").path)
        try write(String(repeating: "x", count: 300_000), to: source.appendingPathComponent("data/big.txt"))
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("data/link").path, withDestinationPath: "big.txt")

        let mover = SafeMover(rules: rules)
        let stale = mover.plan(source: source, volume: volume)
        try write("late", to: source.appendingPathComponent("late.txt"))
        expectError("файл, появившийся после проверки, останавливает перенос",
                    { _ = try mover.execute(stale, deleteOriginal: true, acceptCautions: true) },
                    matching: { if case MoveError.contentMismatch = $0 { return true }; return false })
        check(fm.fileExists(atPath: source.appendingPathComponent("data/big.txt").path), "после остановки оригинал на месте")
        check(!fm.fileExists(atPath: mount.appendingPathComponent("Offload").path), "после остановки на диске ничего не осталось")
        try fm.removeItem(at: source.appendingPathComponent("late.txt"))
        let plan = mover.plan(source: source, volume: volume)
        check(plan.check.isOK, "план: диск подходит \(plan.check.blockers)")
        expectError("свежие файлы без подтверждения не переносятся",
                    { _ = try mover.execute(plan, deleteOriginal: true, acceptCautions: false) },
                    matching: { if case MoveError.needsConfirmation = $0 { return true }; return false })

        let record = try mover.execute(plan, deleteOriginal: true, acceptCautions: true)
        let target = URL(fileURLWithPath: record.archivedPath)
        check(record.originalRemoved && !fm.fileExists(atPath: source.path), "оригинал удалён после сверки")
        check(target.path == mount.path + "/Offload/Downloads/project", "архив лежит в Offload/<путь от домашней папки>")
        check(try fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("data/link").path) == "big.txt",
              "символическая ссылка пережила перенос на exFAT")
        let sidecars = ((try? fm.subpathsOfDirectory(atPath: mount.path)) ?? []).filter {
            ($0 as NSString).lastPathComponent.hasPrefix("._") && !$0.hasPrefix(".fseventsd")
        }
        check(sidecars.isEmpty, "служебных ._-файлов не осталось \(sidecars.prefix(3))")
        let shasum = try Runner.run("shasum", ["-a", "256", "-c", target.lastPathComponent + ".sha256"],
                                    currentDirectory: target.deletingLastPathComponent())
        check(shasum.succeeded, "архив проходит shasum -c: \(shasum.stderr)")

        // Архивом пользовались: человек работал с файлами прямо на внешнем диске, и они изменились.
        // Возврат обязан состояться — иначе к данным уже не подступиться, — но сказать об этом надо.
        let archivedFile = target.appendingPathComponent("data/big.txt")
        let goodContent = try String(contentsOf: archivedFile, encoding: .utf8)
        try write(String(repeating: "y", count: goodContent.count), to: archivedFile)
        let usedArchive = try mover.restore(record, deleteArchive: false)
        check(usedArchive.notes.contains { $0.contains("изменилось файлов: 1") },
              "изменённый архив вернулся с оговоркой: \(usedArchive.notes)")
        check((try? String(contentsOf: source.appendingPathComponent("data/big.txt"), encoding: .utf8))?.hasPrefix("y") == true,
              "вернулось то, что лежит в архиве сейчас")
        check(fm.fileExists(atPath: target.path), "архив на месте — удалять его не просили")
        try fm.removeItem(at: source)
        try write(goodContent, to: archivedFile)
        check(Journal.records(on: volume).contains { $0.id == record.id }, "перенос записан в журнал на диске")

        expectError("журнал с путём наружу отклоняется", {
            var bad = record
            bad.archivedPath = mount.path + "/Offload/../../../etc"
            _ = try mover.validate(bad)
        })
        expectError("журнал с возвратом в системное место отклоняется", {
            var bad = record
            bad.originalPath = "/etc/hosts"
            _ = try mover.validate(bad)
        })
        expectError("журнал с возвратом в данные приложений отклоняется", {
            var bad = record
            bad.originalPath = rules.home.appendingPathComponent("Library/Containers/com.docker.docker/x").path
            _ = try mover.validate(bad)
        })
        // Путь возврата ведёт в несуществующее место, и Foundation ссылки в нём не разворачивает:
        // без своей проверки такая запись из журнала записала бы файл в автозапуск.
        try fm.createDirectory(at: rules.home.appendingPathComponent("Library/LaunchAgents"), withIntermediateDirectories: true)
        let trapParent = rules.home.appendingPathComponent("Documents/Фото", isDirectory: true)
        try fm.createDirectory(at: trapParent, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: trapParent.appendingPathComponent("old").path,
                                  withDestinationPath: rules.home.appendingPathComponent("Library").path)
        expectError("возврат через подложенную ссылку в ~/Library отклоняется", {
            var bad = record
            bad.originalPath = trapParent.appendingPathComponent("old/LaunchAgents/com.evil.plist").path
            _ = try mover.validate(bad)
        })
        check(!fm.fileExists(atPath: rules.home.appendingPathComponent("Library/LaunchAgents/com.evil.plist").path),
              "в ~/Library/LaunchAgents ничего не появилось")

        // Подделанный архив: ссылка наружу и запись в .modes.json через неё.
        let victim = scratch.appendingPathComponent("victim-dir", isDirectory: true)
        try write("secret", to: victim.appendingPathComponent("victim.txt"))
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: victim.appendingPathComponent("victim.txt").path)
        try fm.createSymbolicLink(atPath: target.appendingPathComponent("evil").path, withDestinationPath: victim.path)
        let modesFile = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".modes.json")
        var modes = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: modesFile))
        modes["evil/victim.txt"] = 0o777
        try fm.removeItem(at: modesFile)
        try JSONEncoder().encode(modes).write(to: modesFile)

        expectError("архив вне внешнего диска отклоняется", {
            var bad = record
            bad.archivedPath = scratch.appendingPathComponent("elsewhere").path
            _ = try mover.validate(bad)
        })

        // Перенос, сделанный без Offload: папка уже лежит на диске в произвольном месте.
        let manual = mount.appendingPathComponent("Archive-2026/old-stuff", isDirectory: true)
        try write("manual", to: manual.appendingPathComponent("file.txt"))
        try write("#!/bin/sh\necho hi\n", to: manual.appendingPathComponent("tool.sh"))
        let imported = try mover.importRecord(archived: manual, original: rules.home.appendingPathComponent("Downloads/old-stuff"),
                                              originalRemoved: true, note: "вручную")
        check(imported.files >= 1 && imported.volumeName == volume.name && imported.note == "вручную", "ручная запись посчитана и привязана к диску")
        check(Journal.records(on: volume).contains { $0.id == imported.id }, "ручная запись сохранена в журнал на диске")
        let emptyPlace = rules.home.appendingPathComponent("Downloads/old-stuff", isDirectory: true)
        try write("", to: emptyPlace.appendingPathComponent(".DS_Store"))
        let back = try mover.restore(imported, deleteArchive: false).record
        check(back.restored && (try? String(contentsOf: rules.home.appendingPathComponent("Downloads/old-stuff/file.txt"), encoding: .utf8)) == "manual",
              "ручная запись возвращается на место пустой папки со сверкой")
        // У ручного переноса нет списка прав, а exFAT их не хранит: без своей ветки скрипт вернулся бы
        // неисполняемым, а с прежними 644/755 — читаемым всем на машине.
        check(mode(rules.home.appendingPathComponent("Downloads/old-stuff/tool.sh")) == 0o700,
              "скрипт из ручного переноса вернулся исполняемым (\(mode(rules.home.appendingPathComponent("Downloads/old-stuff/tool.sh")) ?? -1))")
        check(mode(rules.home.appendingPathComponent("Downloads/old-stuff/file.txt")) == 0o600,
              "обычный файл из ручного переноса вернулся правами только для владельца")
        let busyPlace = rules.home.appendingPathComponent("Downloads/busy", isDirectory: true)
        try write("keep me", to: busyPlace.appendingPathComponent("own.txt"))
        let clashing = try mover.importRecord(archived: manual, original: busyPlace, originalRemoved: true)
        expectError("возврат в непустую папку отклоняется", { _ = try mover.restore(clashing, deleteArchive: false) },
                    matching: { if case MoveError.alreadyExists = $0 { return true }; return false })
        check((try? String(contentsOf: busyPlace.appendingPathComponent("own.txt"), encoding: .utf8)) == "keep me", "содержимое непустой папки не тронуто")
        expectError("ручная запись с возвратом в ~/.ssh отклоняется", {
            _ = try mover.importRecord(archived: manual, original: rules.home.appendingPathComponent(".ssh/keys"), originalRemoved: true)
        })
        expectError("ручная запись на несуществующий архив отклоняется", {
            _ = try mover.importRecord(archived: mount.appendingPathComponent("nope"), original: rules.home.appendingPathComponent("Downloads/nope"), originalRemoved: true)
        })

        let restored = try mover.restore(record, deleteArchive: true).record
        check(mode(victim.appendingPathComponent("victim.txt")) == 0o600, "подделанный архив не изменил права файла вне папки")
        check(restored.restored, "возврат отмечен")
        check(try String(contentsOf: source.appendingPathComponent("data/big.txt"), encoding: .utf8).count == 300_000, "данные вернулись")
        check(mode(source.appendingPathComponent("run.sh")) == 0o755, "права доступа вернулись, хотя exFAT их не хранит")
        check(!fm.fileExists(atPath: target.path), "архив удалён после возврата")
    }

    section("Шифрованный контейнер") {
        let vault = SecretsVault(imageURL: scratch.appendingPathComponent("vault.sparsebundle"))
        expectError("короткий пароль отклоняется", { try vault.create(password: "short") },
                    matching: { ($0 as? VaultError) == .weakPassword })
        let password = "offload-check-\(UUID().uuidString)"
        try vault.create(password: password, sizeGB: 1)
        check(vault.isEncrypted, "контейнер действительно зашифрован (есть token)")
        expectError("неверный пароль не открывает контейнер", { _ = try vault.attach(password: "wrong-password-123") },
                    matching: { ($0 as? VaultError) == .wrongPassword })
        let mount = try vault.attach(password: password)
        defer { try? SecretsVault.detach(mount) }
        check(Volumes.info(for: mount)?.fsType == "apfs", "внутри контейнера APFS")
        check(vault.currentMountPoint()?.path == mount.path, "открытый контейнер находится по точке монтирования")
        let manualVault = scratch.appendingPathComponent("disk-root/Secrets.sparsebundle", isDirectory: true)
        try fm.createDirectory(at: manualVault.appendingPathComponent("bands"), withIntermediateDirectories: true)
        // Заголовок настоящего зашифрованного образа начинается с «encrcdsa».
        try write("encrcdsa\u{0}\u{0}", to: manualVault.appendingPathComponent("token"))
        try fm.createDirectory(at: scratch.appendingPathComponent("disk-root/Plain.sparsebundle"), withIntermediateDirectories: true)
        check(SecretsVault.existingEncryptedBundle(in: scratch.appendingPathComponent("disk-root"))?.standardizedFileURL.path == manualVault.standardizedFileURL.path,
              "созданный вручную зашифрованный контейнер находится, незашифрованный — нет")

        // Пустой файл token, подложенный в обычный образ: раньше он выдавал образ за зашифрованный,
        // а пароль к такому образу подходит любой — ключи легли бы на диск открытым текстом.
        let disguised = scratch.appendingPathComponent("disk-root/Archive.sparsebundle", isDirectory: true)
        try fm.createDirectory(at: disguised, withIntermediateDirectories: true)
        try write("", to: disguised.appendingPathComponent("token"))
        let disguisedVault = SecretsVault(imageURL: disguised)
        check(!disguisedVault.isEncrypted, "пустой token не выдаёт обычный образ за зашифрованный")
        expectError("незашифрованный образ не открывается как контейнер",
                    { _ = try disguisedVault.attach(password: "any-password-12345") },
                    matching: { ($0 as? VaultError) == .notEncrypted })
        check(SecretsVault.existingEncryptedBundle(in: scratch.appendingPathComponent("disk-root"))?.lastPathComponent == "Secrets.sparsebundle",
              "подделка не выбирается как контейнер диска, хотя стоит раньше по алфавиту")

        let home = scratch.appendingPathComponent("home-vault", isDirectory: true)
        try fm.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try Runner.check("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "offload-check",
                                        "-f", home.appendingPathComponent(".ssh/id_check").path], timeout: 30)
        try write("export TOKEN=1\n", to: home.appendingPathComponent(".zshrc"))
        let app = home.appendingPathComponent("projects/app", isDirectory: true)
        try write("API_KEY=1", to: app.appendingPathComponent(".env"))
        try write("KEY", to: app.appendingPathComponent("config/server.key"))
        try write("API_KEY=", to: app.appendingPathComponent(".env.example"))
        try write("x", to: app.appendingPathComponent("node_modules/pkg/.env"))
        try write("export AWS_SECRET_ACCESS_KEY=1", to: app.appendingPathComponent(".envrc"))
        try write("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n", to: app.appendingPathComponent("deploy_key"))

        try write("моя заметка", to: mount.appendingPathComponent("КАК-ВОССТАНОВИТЬ.txt"))
        try write("kdbx", to: home.appendingPathComponent("Downloads/base.kdbx"))
        let projects = home.appendingPathComponent("projects", isDirectory: true)
        let report = SecretsVault.fill(mount, home: home, projectRoots: [projects])
        check(report.problems.isEmpty, "без ошибок \(report.problems.prefix(2))")
        check(mode(mount.appendingPathComponent("ssh/id_check")) == 0o600, "права ключа сохранены")
        check(fm.fileExists(atPath: mount.appendingPathComponent("dotfiles/.zshrc").path), "дотфайлы на месте")
        check(fm.fileExists(atPath: mount.appendingPathComponent("project-secrets/app/.env").path), ".env проекта на месте")
        check(fm.fileExists(atPath: mount.appendingPathComponent("project-secrets/app/config/server.key").path), "ключ из подпапки на месте")
        check(!fm.fileExists(atPath: mount.appendingPathComponent("project-secrets/app/.env.example").path), "шаблон .env.example не считается секретом")
        check(!fm.fileExists(atPath: mount.appendingPathComponent("project-secrets/app/node_modules").path), "node_modules пропущены")
        check(fm.fileExists(atPath: mount.appendingPathComponent("project-secrets/app/.envrc").path), ".envrc проекта попал в контейнер")
        check(fm.fileExists(atPath: mount.appendingPathComponent("project-secrets/app/deploy_key").path), "ключ без расширения попал в контейнер")
        check(report.unprotectedKeys == ["id_check"], "найден ключ без парольной фразы \(report.unprotectedKeys)")
        check(fm.fileExists(atPath: mount.appendingPathComponent("keepass/base.kdbx").path), "база KeePass из Загрузок на месте")
        check((try? String(contentsOf: mount.appendingPathComponent("КАК-ВОССТАНОВИТЬ.txt"), encoding: .utf8)) == "моя заметка",
              "существующая заметка в контейнере не затёрта")
        let other = home.appendingPathComponent("other", isDirectory: true)
        try write("OTHER=1", to: other.appendingPathComponent("app/.env"))
        let clash = SecretsVault.fill(mount, home: home, projectRoots: [projects, other])
        check(clash.problems.contains { $0.contains("app/.env") }, "одинаковый путь из двух папок отмечен как проблема")
        check((try? String(contentsOf: mount.appendingPathComponent("project-secrets/app/.env"), encoding: .utf8)) == "API_KEY=1",
              "секрет первой папки не затёрт второй")
    }
}

if env["OFFLOAD_SKIP_DOCKER"] != "1", (try? DockerService().ensureRunning()) != nil {
    section("Docker: архивация тома и возврат") {
        let docker = DockerService()
        let name = "offload-check-\(UUID().uuidString.prefix(8).lowercased())"
        try Runner.check("docker", ["volume", "create", name], timeout: 60)
        defer { _ = try? Runner.run("docker", ["volume", "rm", "-f", name], timeout: 60) }
        _ = try docker.lastActivity(of: name)
        try Runner.check("docker", ["run", "--rm", "--log-driver", "none", "--network", "none", "-v", "\(name):/v", DockerService.helperImage,
                                    "sh", "-c", "mkdir -p /v/a/b && echo hello > '/v/a/b/файл с пробелом.txt' && ln -s b /v/a/link"], timeout: 120)
        let rawBefore = docker.rawDiskBytes()
        let archive = try docker.archive(name, into: scratch.appendingPathComponent("docker-archives", isDirectory: true))
        check(fm.fileExists(atPath: archive.path), "архив создан: \(archive.lastPathComponent)")
        if let rawBefore, let rawAfter = docker.rawDiskBytes() {
            check(rawAfter - rawBefore < 512 << 20, "Docker.raw не раздулся: \(Format.bytes(rawAfter - rawBefore))")
        }
        try docker.removeVolume(name)
        try docker.restore(archive: archive, as: name)
        let content = try Runner.check("docker", ["run", "--rm", "--log-driver", "none", "--network", "none", "-v", "\(name):/v:ro",
                                                  DockerService.helperImage, "cat", "/v/a/b/файл с пробелом.txt"], timeout: 60)
        check(content.output == "hello\n", "том восстановлен из архива")
        expectError("существующий том не перезаписывается", { try docker.restore(archive: archive, as: name) },
                    matching: { ($0 as? DockerError) == .alreadyExists(name) })
        expectError("опасное имя тома отклоняется до запуска docker", { _ = try docker.archive("/etc:/v", into: scratch) },
                    matching: { ($0 as? DockerError) == .invalidName("/etc:/v") })
    }
} else {
    print("▸ Docker: пропущено (не запущен или OFFLOAD_SKIP_DOCKER=1)")
}

checksRestore()
checksContainer()
checksInterface()

try? fm.removeItem(at: scratch)
print("")
print(failed == 0 ? "✅ Все проверки пройдены: \(passed)" : "❌ Не пройдено: \(failed), пройдено: \(passed)")
exit(failed == 0 ? 0 : 1)
