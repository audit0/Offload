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
              "ошибка с файлом")

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
