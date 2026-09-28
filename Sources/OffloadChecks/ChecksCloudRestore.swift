import Foundation
import OffloadCore

/// Восстановление из бэкапа restic: разбор вывода — всегда, настоящее хранилище — если restic установлен.
func checksCloudRestore() {
    section("Из iCloud: разбор вывода restic") {
        let snapshots = CloudRestore.parseSnapshots(Data("""
        [{"time":"2026-09-26T20:23:14.99383+03:00","tree":"t","paths":["/Volumes/SSD"],"hostname":"mac","tags":["ssd"],
          "summary":{"total_bytes_processed":160181592064},"id":"c00b9807aaaa","short_id":"c00b9807"},
         {"time":"2026-09-26T18:44:07.123456789+03:00","paths":["/a/b","/a/c"],"hostname":"mac","id":"3e18663fbbbb","short_id":"3e18663f"}]
        """.utf8))
        check(snapshots.count == 2, "два снимка")
        check(snapshots.first?.totalBytes == 160_181_592_064, "размер снимка из summary")
        check(snapshots.last?.totalBytes == nil, "без summary размер неизвестен")
        check(snapshots.first?.root == "/Volumes/SSD", "корень снимка с одним путём")
        check(snapshots.last?.root == "/a", "корень снимка с двумя путями — общая папка")
        check(CloudRestore.parseTime("2026-09-26T18:44:07.123456789+03:00") != nil, "время с наносекундами читается")
        check(CloudRestore.commonDirectory(["/Volumes/SSD", "/Users/q"]) == "/", "разные диски — корень")

        let entries = CloudRestore.parseEntries("""
        {"time":"2026-09-26T20:23:14+03:00","paths":["/Volumes/SSD"],"id":"x","struct_type":"snapshot","message_type":"snapshot"}
        {"name":"SSD","type":"dir","path":"/Volumes/SSD","mtime":"2026-09-26T16:54:14.1+03:00","struct_type":"node"}
        {"name":"a.txt","type":"file","path":"/Volumes/SSD/a.txt","size":12,"mtime":"2026-09-26T16:54:14+03:00","struct_type":"node"}
        {"name":"dev","type":"chardev","path":"/Volumes/SSD/dev","struct_type":"node"}
        """)
        check(entries.count == 2, "строка снимка и устройства пропускаются")
        check(entries.last?.size == 12 && entries.last?.isDirectory == false, "размер файла")
        check(entries.first?.isDirectory == true && entries.first?.size == nil, "у папки размера нет")

        let found = CloudRestore.parseFind(Data("""
        [{"matches":[{"path":"/src/x.pdf","type":"file","size":5},{"path":"/src/d","type":"dir"}],"hits":2,"snapshot":"s"}]
        """.utf8))
        check(found.map(\.path) == ["/src/x.pdf", "/src/d"], "поиск: совпадения всех снимков")

        let status = CloudRestore.parseProgress(#"{"message_type":"status","percent_done":0.25,"total_bytes":400,"bytes_restored":100}"#)
        check(status?.fraction == 0.25 && status?.bytesDone == 100, "прогресс восстановления")
        check(CloudRestore.parseProgress(#"{"message_type":"summary","total_bytes":400,"bytes_restored":400}"#)?.fraction == 1, "итог — 100 %")
        check(CloudRestore.parseProgress("не json") == nil, "посторонние строки — не прогресс")
        check(CloudRestore.parseProblem(#"{"message_type":"error","error":{"message":"read failed"},"during":"restore","item":"/a"}"#) == "/a: read failed",
              "ошибка с файлом (restic 0.17 и новее — JSON в stderr)")
        let old = CloudRestore.failedItem("ignoring error for /Docs/big1.bin: StreamPack: open /r/data/ea/eaea: no such file or directory")
        check(old?.item == "/Docs/big1.bin" && old?.message == "StreamPack: open /r/data/ea/eaea: no such file or directory",
              "ошибка с файлом в restic 0.16 — текстом")
        check(CloudRestore.failedItem("Load(<data/eaeaae5b1e>, 17879973, 0) returned error, retrying after 264ms: open /r/x: no such file") == nil,
              "повтор чтения — не ошибка с файлом")
        check(CloudRestore.failedItem(#"{"message_type":"status","percent_done":0.5}"#) == nil, "прогресс — не ошибка")
        check(CloudRestore.readable("""
            Load(<data/ea>, 1, 0) returned error, retrying after 264ms: open /r/data/ea/x: no such file or directory
            {"message_type":"error","error":{"message":"ciphertext verification failed"},"during":"restore","item":"/Docs/a.bin"}
            {"message_type":"exit_error","code":1,"message":"There were 1 errors"}
            """) == ["/Docs/a.bin: ciphertext verification failed", "There were 1 errors"],
              "сообщение об ошибке — по-человечески: без JSON и без повторов чтения")

        // Испорченное restic оставляет с дырами — его убираем. Но только обычный файл и только внутри папки восстановления.
        let target = scratch.appendingPathComponent("broken-restore", isDirectory: true)
        try write("испорчен", to: target.appendingPathComponent("Docs/big.bin"))
        try write("цел", to: target.appendingPathComponent("Docs/small.txt"))
        try write("чужое", to: scratch.appendingPathComponent("outside.txt"))
        CloudRestore.removeBroken("/Docs/big.bin", in: target)
        CloudRestore.removeBroken("/../outside.txt", in: target)
        CloudRestore.removeBroken("/Docs", in: target)
        check(!fm.fileExists(atPath: target.appendingPathComponent("Docs/big.bin").path), "испорченный файл убран")
        check(fm.fileExists(atPath: target.appendingPathComponent("Docs/small.txt").path), "целый рядом остался")
        check(fm.fileExists(atPath: scratch.appendingPathComponent("outside.txt").path), "путь с «..» из вывода restic за папку не выходит")
        check(fm.fileExists(atPath: target.appendingPathComponent("Docs").path), "папку с ошибкой (например, прав) не удаляем")

        let stall = "Load(<data/a08d985582>, 1425, 57776523) returned error, retrying after 926.43089ms: read /Users/q/Library/Mobile Documents/com~apple~CloudDocs/Бэкапы/ssd-restic/data/a0/a08d98: operation canceled"
        check(CloudRestore.stalledFile(stall)?.path == "/Users/q/Library/Mobile Documents/com~apple~CloudDocs/Бэкапы/ssd-restic/data/a0/a08d98",
              "кусок, который ждёт iCloud")
        check(CloudRestore.stalledFile("Fatal: wrong password") == nil, "прочие ошибки — не ожидание iCloud")

        check(CloudRestore.escapePattern("a[1]*?.txt") == #"a\[1\]\*\?.txt"#, "спецсимволы шаблона экранируются")
        check(CloudRestore.escapePattern("обычное имя.pdf") == "обычное имя.pdf", "обычное имя не меняется")
        check(CloudRestore.parentDirectory("/Volumes") == "/", "родитель верхней папки — корень")
        check(CloudRestore.ancestors(of: "/Volumes/SSD/Проекты") == ["/", "/Volumes", "/Volumes/SSD", "/Volumes/SSD/Проекты"], "хлебные крошки")
        check(CloudRestore.ancestors(of: "/") == ["/"], "крошки корня")
    }

    section("Из iCloud: где искать хранилища") {
        let root = scratch.appendingPathComponent("cloud-drive", isDirectory: true)
        let repository = root.appendingPathComponent("Бэкапы/ssd-restic", isDirectory: true)
        for folder in ["keys", "data/00", "snapshots"] {
            try fm.createDirectory(at: repository.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try write("x", to: repository.appendingPathComponent("config"))
        try write("x", to: root.appendingPathComponent("Документы/письмо.txt"))
        let fake = root.appendingPathComponent("Бэкапы/не-хранилище", isDirectory: true)
        try write("x", to: fake.appendingPathComponent("config"))
        check(CloudRestore.isRepository(repository), "хранилище узнаётся по config, keys и data")
        check(!CloudRestore.isRepository(fake), "одного config мало")
        check(CloudRestore.discover(in: root).map(\.url) == [repository.standardizedFileURL], "найдено одно хранилище на втором уровне")
        check(CloudRestore.discover(in: root, depth: 1).isEmpty, "глубже заданного не ищет")
        check(CloudRestore.discover(in: repository).count == 1, "папка самого хранилища")
    }

    guard env["OFFLOAD_SKIP_INTEGRATION"] != "1" else {
        print("▸ Из iCloud: настоящее хранилище — пропущено (OFFLOAD_SKIP_INTEGRATION=1)")
        return
    }
    guard CloudRestore.isResticInstalled else {
        print("▸ Из iCloud: настоящее хранилище — пропущено (restic не установлен)")
        return
    }

    section("Из iCloud: восстановление из настоящего хранилища") {
        let base = scratch.appendingPathComponent("restic", isDirectory: true)
        let repositoryURL = base.appendingPathComponent("repo", isDirectory: true)
        let source = base.appendingPathComponent("SSD", isDirectory: true)
        let secret = "проверочный пароль 42"
        try write("отчёт", to: source.appendingPathComponent("Документы/отчёт 2025.txt"))
        try write("звёздочка", to: source.appendingPathComponent("Документы/a[1]*.txt"))
        try write("сосед", to: source.appendingPathComponent("Документы/a1x.txt"))
        try write("вложенный", to: source.appendingPathComponent("Документы/Папка/глубже/b.txt"))
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try Runner.check("restic", ["init", "--repo", repositoryURL.path, "--quiet"], stdin: Data(secret.utf8), timeout: 120)
        try Runner.check("restic", ["backup", "--repo", repositoryURL.path, "--quiet", source.path], stdin: Data(secret.utf8), timeout: 300)
        let passwordFile = base.appendingPathComponent("password")
        try write(secret, to: passwordFile)

        let repository = CloudRestore.Repository(url: repositoryURL)
        let before = try listing(repositoryURL)
        expectError("неверный пароль", { _ = try CloudRestore.snapshots(repository, password: .typed("не тот")) }) {
            $0 as? CloudRestore.RestoreError == .wrongPassword
        }
        let snapshots = try CloudRestore.snapshots(repository, password: .typed(secret))
        check(snapshots.count == 1, "снимок читается набранным паролем")
        check(try CloudRestore.snapshots(repository, password: .file(passwordFile)).count == 1, "и паролем из файла")
        guard let snapshot = snapshots.first else { return }
        check(snapshot.root == source.path, "корень снимка — папка бэкапа")

        let password = CloudRestore.Password.typed(secret)
        let top = try CloudRestore.list(repository, password: password, snapshot: snapshot.id, directory: snapshot.root)
        check(top.map(\.name) == ["Документы"], "содержимое корня")
        let documents = try CloudRestore.list(repository, password: password, snapshot: snapshot.id, directory: snapshot.root + "/Документы")
        check(documents.first?.name == "Папка" && documents.first?.isDirectory == true, "папки идут первыми")
        check(documents.count == 4, "в папке четыре элемента, без вложенных")

        let found = try CloudRestore.search(repository, password: password, snapshot: snapshot.id, query: "ОТЧЁТ")
        check(found.map(\.name) == ["отчёт 2025.txt"], "поиск по части имени без учёта регистра")

        let folder = scratch.appendingPathComponent("restored", isDirectory: true)
        guard let star = documents.first(where: { $0.name == "a[1]*.txt" }),
              let nested = documents.first(where: { $0.name == "Папка" }) else { throw CopyError.unreadable("список") }
        let first = try CloudRestore.restore(star, from: repository, password: password, snapshot: snapshot, into: folder)
        check((try? String(contentsOf: first.item, encoding: .utf8)) == "звёздочка", "файл со спецсимволами восстановлен")
        check((try? fm.contentsOfDirectory(atPath: first.item.deletingLastPathComponent().path)) == ["a[1]*.txt"],
              "восстановлен только он — без соседа a1x.txt")
        check(first.problems.isEmpty && first.files == 1, "без проблем")

        let second = try CloudRestore.restore(nested, from: repository, password: .file(passwordFile), snapshot: snapshot, into: folder)
        check(second.item.lastPathComponent == "Папка", "папка восстанавливается со своим именем")
        check((try? String(contentsOf: second.item.appendingPathComponent("глубже/b.txt"), encoding: .utf8)) == "вложенный", "вложенное на месте")
        check(second.item.deletingLastPathComponent() != first.item.deletingLastPathComponent(), "каждый раз — новая папка")
        check(second.item.deletingLastPathComponent().lastPathComponent.hasSuffix("(2)"), "с номером, если имя занято")
        check(try CloudRestore.size(of: nested, in: repository, password: password, snapshot: snapshot.id) == Int64("вложенный".utf8.count),
              "размер папки — сумма файлов")

        let untouched = try fm.contentsOfDirectory(atPath: folder.path).count
        expectError("остановленное восстановление", {
            _ = try CloudRestore.restore(nested, from: repository, password: password, snapshot: snapshot, into: folder, isCancelled: { true })
        }) { $0 is CancellationError }
        check(try fm.contentsOfDirectory(atPath: folder.path).count == untouched, "остановленное убрано целиком")

        check(try listing(repositoryURL) == before, "в хранилище ничего не записано — ни блокировок, ни кэша")
    }

    section("Из iCloud: часть бэкапа испорчена — восстановленное остальное остаётся") {
        // Большой файл займёт свои куски хранилища, маленький ляжет в последний. Испортим самый большой кусок:
        // restic выйдет с 1, а большой файл оставит полного размера с дырами.
        let base = scratch.appendingPathComponent("restic-damaged", isDirectory: true)
        let repositoryURL = base.appendingPathComponent("repo", isDirectory: true)
        let source = base.appendingPathComponent("SSD", isDirectory: true)
        let secret = "проверочный пароль 42"
        var random = SystemRandomNumberGenerator()
        try fm.createDirectory(at: source.appendingPathComponent("Документы"), withIntermediateDirectories: true)
        try Data((0..<20_000_000).map { _ in UInt8.random(in: 0...255, using: &random) })
            .write(to: source.appendingPathComponent("Документы/big.bin"))
        try write("маленький", to: source.appendingPathComponent("Документы/small.txt"))
        try Runner.check("restic", ["init", "--repo", repositoryURL.path, "--quiet"], stdin: Data(secret.utf8), timeout: 120)
        try Runner.check("restic", ["backup", "--repo", repositoryURL.path, "--quiet", source.path], stdin: Data(secret.utf8), timeout: 300)
        let packs = (fm.enumerator(at: repositoryURL.appendingPathComponent("data"), includingPropertiesForKeys: [.fileSizeKey])?
            .compactMap { $0 as? URL } ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard let largest = packs.first else { throw CopyError.unreadable("куски хранилища") }
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: largest.path)
        var bytes = try Data(contentsOf: largest)
        for index in stride(from: 1000, to: bytes.count - 1000, by: 4096) { bytes[index] ^= 0xFF }
        try bytes.write(to: largest)

        let repository = CloudRestore.Repository(url: repositoryURL)
        let password = CloudRestore.Password.typed(secret)
        guard let snapshot = try CloudRestore.snapshots(repository, password: password).first,
              let documents = try CloudRestore.list(repository, password: password, snapshot: snapshot.id, directory: snapshot.root)
                .first(where: { $0.name == "Документы" }) else { throw CopyError.unreadable("снимок") }
        let report = try CloudRestore.restore(documents, from: repository, password: password, snapshot: snapshot,
                                              into: scratch.appendingPathComponent("restored-damaged", isDirectory: true))
        check(!report.verified && report.problems.contains { $0.contains("big.bin") }, "не всё прочиталось: сказано, что именно, и что сверки не было")
        check(!fm.fileExists(atPath: report.item.appendingPathComponent("big.bin").path), "испорченный файл убран, а не оставлен с дырами")
        check((try? String(contentsOf: report.item.appendingPathComponent("small.txt"), encoding: .utf8)) == "маленький",
              "целый файл восстановлен и остался")
        check(report.files == 1, "в отчёте — то, что осталось")
    }
}

/// Все файлы хранилища с размерами — чтобы убедиться, что чтение его не меняет.
private func listing(_ url: URL) throws -> [String: Int] {
    var result: [String: Int] = [:]
    let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
    while let next = enumerator?.nextObject() as? URL {
        result[next.path] = (try next.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? -1
    }
    return result
}
