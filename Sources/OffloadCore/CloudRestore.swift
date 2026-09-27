import Foundation

/// Восстановление из бэкапа restic — например, из хранилища в iCloud Drive, куда бэкап
/// кладёт «Панель агентов». Offload хранилище только читает: все команды идут с `--no-lock`,
/// в хранилище не пишется ничего, даже файл блокировки. Восстановленное ложится в новую
/// папку, поэтому ничего существующего не перезаписывается.
public enum CloudRestore {
    /// Пароль хранилища. Набранный передаётся restic только через stdin; файл с паролем
    /// restic читает сам, Offload его содержимое не видит.
    public enum Password: Sendable, Equatable {
        case typed(String)
        case file(URL)
    }

    public struct Repository: Sendable, Hashable, Identifiable {
        public let url: URL
        public var id: String { url.path }
        public var name: String { url.lastPathComponent }

        public init(url: URL) { self.url = url.standardizedFileURL }
    }

    public struct Snapshot: Sendable, Hashable, Identifiable {
        public let id: String
        public let shortID: String
        public let time: Date
        public let paths: [String]
        public let hostname: String
        public let tags: [String]
        /// Сколько данных было в снимке — если restic это записал.
        public let totalBytes: Int64?

        public init(id: String, shortID: String, time: Date, paths: [String], hostname: String, tags: [String], totalBytes: Int64?) {
            self.id = id
            self.shortID = shortID
            self.time = time
            self.paths = paths
            self.hostname = hostname
            self.tags = tags
            self.totalBytes = totalBytes
        }

        /// С какой папки начинать просмотр: общая часть путей снимка.
        public var root: String { CloudRestore.commonDirectory(paths) }
    }

    /// Файл или папка внутри снимка. Путь — как в снимке, от корня: «/Volumes/SSD/Проекты».
    public struct Entry: Sendable, Hashable, Identifiable {
        public let path: String
        public let isDirectory: Bool
        public let size: Int64?
        public let modified: Date?
        public var id: String { path }
        public var name: String { (path as NSString).lastPathComponent }

        public init(path: String, isDirectory: Bool, size: Int64?, modified: Date?) {
            self.path = path
            self.isDirectory = isDirectory
            self.size = size
            self.modified = modified
        }
    }

    public struct Progress: Sendable, Equatable {
        public var fraction: Double
        public var bytesDone: Int64
        public var bytesTotal: Int64
    }

    public struct Report: Sendable {
        /// Где лежит восстановленное.
        public let item: URL
        public let bytes: Int64
        public let files: Int
        /// Что восстановить не удалось — по файлу на строку.
        public let problems: [String]
    }

    public enum RestoreError: LocalizedError, Equatable {
        case resticMissing
        case wrongPassword
        case notARepository(String)
        case notEnoughSpace(needed: Int64, available: Int64)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .resticMissing:
                return "Для восстановления нужна программа restic. Установите её: brew install restic — и нажмите «Проверить снова»."
            case .wrongPassword:
                return "Пароль не подходит к этому хранилищу."
            case .notARepository(let path):
                return "В папке «\(path)» нет хранилища restic."
            case .notEnoughSpace(let needed, let available):
                return "Не хватает места: нужно \(Format.bytes(needed)), свободно \(Format.bytes(available))."
            case .failed(let message):
                return message
            }
        }
    }

    // MARK: - Где искать

    public static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// Хранилище restic узнаётся по файлу config и папкам keys и data рядом.
    public static func isRepository(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.appendingPathComponent("config").path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return ["keys", "data"].allSatisfy {
            fm.fileExists(atPath: url.appendingPathComponent($0).path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// Хранилища в папке и на два уровня вглубь: «iCloud Drive/Бэкапы/ssd-restic».
    /// Внутрь найденного хранилища не заходит — там тысячи папок с данными.
    public static func discover(in root: URL = iCloudDrive, depth: Int = 2) -> [Repository] {
        if isRepository(root) { return [Repository(url: root)] }
        guard depth > 0 else { return [] }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .flatMap { discover(in: $0, depth: depth - 1) }
    }

    // MARK: - Команды

    public static var isResticInstalled: Bool { Runner.locate("restic") != nil }

    /// Общие аргументы: хранилище, пароль и то, что Offload его только читает.
    static func invocation(_ command: [String], repository: Repository, password: Password) -> (arguments: [String], stdin: Data?) {
        var arguments = command + ["--repo", repository.url.path, "--no-lock", "--json"]
        switch password {
        case .typed(let text):
            return (arguments, Data(text.utf8))
        case .file(let url):
            arguments += ["--password-file", url.path]
            return (arguments, nil)
        }
    }

    static func run(_ command: [String], repository: Repository, password: Password, timeout: TimeInterval = 900) throws -> CommandResult {
        guard isResticInstalled else { throw RestoreError.resticMissing }
        let call = invocation(command, repository: repository, password: password)
        let result = try Runner.run("restic", call.arguments, stdin: call.stdin, timeout: timeout)
        guard result.succeeded else { throw error(status: result.status, stderr: result.stderr, repository: repository) }
        return result
    }

    /// Коды restic: 10 — хранилища нет, 12 — пароль не подошёл.
    static func error(status: Int32, stderr: String, repository: Repository) -> RestoreError {
        switch status {
        case 12: return .wrongPassword
        case 10: return .notARepository(repository.url.path)
        default:
            let message = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.suffix(3).joined(separator: " ")
            if message.localizedCaseInsensitiveContains("wrong password") { return .wrongPassword }
            return .failed("restic завершился с кодом \(status)" + (message.isEmpty ? "." : ": \(message)"))
        }
    }

    /// Снимки хранилища, новые сверху. Проверяет и пароль: с неверным restic не отдаст ничего.
    public static func snapshots(_ repository: Repository, password: Password) throws -> [Snapshot] {
        parseSnapshots(try run(["snapshots"], repository: repository, password: password).stdout)
            .sorted { $0.time > $1.time }
    }

    /// Содержимое папки снимка: сначала папки, потом файлы, по имени.
    public static func list(_ repository: Repository, password: Password, snapshot: String, directory: String) throws -> [Entry] {
        let output = try run(["ls", snapshot, directory], repository: repository, password: password).output
        return sorted(parseEntries(output).filter { $0.path != directory && parentDirectory($0.path) == directory })
    }

    /// Поиск по имени во всём снимке. Без * и ? ищется часть имени, без учёта регистра.
    public static func search(_ repository: Repository, password: Password, snapshot: String, query: String, limit: Int = 500) throws -> [Entry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let pattern = trimmed.contains(where: { "*?[".contains($0) }) ? trimmed : "*\(trimmed)*"
        let output = try run(["find", "--ignore-case", "--snapshot", snapshot, pattern], repository: repository, password: password).stdout
        return Array(parseFind(output).prefix(limit))
    }

    /// Сколько займёт восстановление: у файла — его размер, у папки — сумма всех файлов внутри.
    public static func size(of entry: Entry, in repository: Repository, password: Password, snapshot: String) throws -> Int64 {
        if !entry.isDirectory { return entry.size ?? 0 }
        let output = try run(["ls", "--recursive", snapshot, entry.path], repository: repository, password: password).output
        return parseEntries(output).filter { !$0.isDirectory && $0.path.hasPrefix(entry.path + "/") }.reduce(0) { $0 + ($1.size ?? 0) }
    }

    /// Восстанавливает файл или папку из снимка в новую папку внутри `folder`
    /// и сверяет восстановленное с хранилищем (`--verify`). Существующее не трогается:
    /// новая папка создаётся всегда своя. Прерванное — убирается целиком.
    public static func restore(_ entry: Entry, from repository: Repository, password: Password, snapshot: Snapshot,
                               into folder: URL, isCancelled: @escaping @Sendable () -> Bool = { false },
                               waitingForCloud: @escaping @Sendable (URL) -> Void = { _ in },
                               progress: @escaping @Sendable (Progress) -> Void = { _ in }) throws -> Report {
        guard isResticInstalled else { throw RestoreError.resticMissing }
        let fm = FileManager.default
        let needed = try size(of: entry, in: repository, password: password, snapshot: snapshot.id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let volume = Volumes.info(for: folder) {
            // Запас: на восстановление не должен уйти последний свободный гигабайт Mac.
            let reserve: Int64 = 1 << 30
            guard needed + reserve <= volume.availableBytes else {
                throw RestoreError.notEnoughSpace(needed: needed + reserve, available: volume.availableBytes)
            }
        }
        let target = uniqueFolder(in: folder, snapshot: snapshot)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)

        let parent = parentDirectory(entry.path)
        let call = invocation(["restore", "\(snapshot.id):\(parent)", "--include", "/" + escapePattern(entry.name),
                               "--target", target.path, "--verify"],
                              repository: repository, password: password)
        let lines = LineLog()
        let result: CommandResult
        do {
            result = try Runner.stream("restic", call.arguments, stdin: call.stdin, isCancelled: isCancelled, onErrorLine: { line in
                // Кусок бэкапа убран с Mac и лежит только в iCloud: просим iCloud его скачать.
                guard let pack = stalledFile(line) else { return }
                try? FileManager.default.startDownloadingUbiquitousItem(at: pack)
                waitingForCloud(pack)
            }) { line in
                if let update = parseProgress(line) { progress(update) }
                if let problem = parseProblem(line) { lines.append(problem) }
            }
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
        // 3 — восстановлено не всё: часть файлов не прочиталась. Остальное оставляем.
        guard result.succeeded || result.status == 3 else {
            try? fm.removeItem(at: target)
            throw Self.error(status: result.status, stderr: result.stderr, repository: repository)
        }
        let item = target.appendingPathComponent(entry.name)
        guard fm.fileExists(atPath: item.path) else {
            try? fm.removeItem(at: target)
            throw RestoreError.failed("restic ничего не восстановил: «\(entry.path)» нет в снимке.")
        }
        var stderrProblems = result.status == 3
            ? result.stderr.split(separator: "\n").map(String.init).filter { !$0.isEmpty && stalledFile($0) == nil } : []
        if stderrProblems.count > 20 { stderrProblems = Array(stderrProblems.prefix(20)) }
        let counted = count(item)
        return Report(item: item, bytes: counted.bytes, files: counted.files, problems: lines.all + stderrProblems)
    }

    // MARK: - Разбор вывода restic

    public static func parseSnapshots(_ data: Data) -> [Snapshot] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { object in
            guard let id = object["id"] as? String, let time = (object["time"] as? String).flatMap(parseTime) else { return nil }
            let summary = object["summary"] as? [String: Any]
            return Snapshot(id: id, shortID: object["short_id"] as? String ?? String(id.prefix(8)), time: time,
                            paths: object["paths"] as? [String] ?? [], hostname: object["hostname"] as? String ?? "",
                            tags: object["tags"] as? [String] ?? [],
                            totalBytes: (summary?["total_bytes_processed"] as? NSNumber)?.int64Value)
        }
    }

    /// Вывод `restic ls --json`: строка на объект; первая — сам снимок, её пропускаем.
    public static func parseEntries(_ output: String) -> [Entry] {
        output.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            return entry(from: object)
        }
    }

    /// Вывод `restic find --json`: массив по снимкам, в каждом — совпадения.
    public static func parseFind(_ data: Data) -> [Entry] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.flatMap { ($0["matches"] as? [[String: Any]] ?? []).compactMap(entry) }
    }

    static func entry(from object: [String: Any]) -> Entry? {
        guard let path = object["path"] as? String, let type = object["type"] as? String,
              object["struct_type"] as? String != "snapshot", ["dir", "file", "symlink"].contains(type) else { return nil }
        return Entry(path: path, isDirectory: type == "dir", size: type == "dir" ? nil : (object["size"] as? NSNumber)?.int64Value ?? 0,
                     modified: (object["mtime"] as? String).flatMap(parseTime))
    }

    public static func parseProgress(_ line: String) -> Progress? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["message_type"] as? String, type == "status" || type == "summary" else { return nil }
        let total = (object["total_bytes"] as? NSNumber)?.int64Value ?? 0
        let done = (object["bytes_restored"] as? NSNumber)?.int64Value ?? 0
        let fraction = type == "summary" ? 1 : (object["percent_done"] as? NSNumber)?.doubleValue ?? (total > 0 ? Double(done) / Double(total) : 0)
        return Progress(fraction: min(max(fraction, 0), 1), bytesDone: done, bytesTotal: total)
    }

    /// Сообщение restic об ошибке с конкретным файлом: «путь: что случилось».
    public static func parseProblem(_ line: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["message_type"] as? String == "error" else { return nil }
        let message = (object["error"] as? [String: Any])?["message"] as? String ?? "ошибка"
        if let item = object["item"] as? String, !item.isEmpty { return "\(item): \(message)" }
        return message
    }

    /// Строка restic о том, что файл хранилища не прочитался и чтение будет повторено:
    /// «Load(<data/a08d98>, 1425, 57776523) returned error, retrying after 926ms: read /…/data/a0/a08d…: operation canceled».
    /// Так выглядит кусок бэкапа, который iCloud убрал с Mac и ещё не скачал обратно.
    public static func stalledFile(_ line: String) -> URL? {
        guard line.contains("returned error, retrying"), let start = line.range(of: ": read /") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.range(of: ": ", options: .backwards) else { return nil }
        return URL(fileURLWithPath: "/" + rest[..<end.lowerBound])
    }

    /// Время restic — с долями секунды до наносекунд, которые ISO8601DateFormatter не читает.
    public static func parseTime(_ text: String) -> Date? {
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }

    // MARK: - Пути

    /// Шаблоны restic (`--include`) понимают *, ?, [ ] и \ — в имени файла они должны значить сами себя.
    public static func escapePattern(_ name: String) -> String {
        var escaped = ""
        for character in name {
            if "*?[]\\".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    public static func parentDirectory(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    /// Общая папка нескольких путей: для «/Volumes/SSD» — она сама, для разных дисков — «/».
    public static func commonDirectory(_ paths: [String]) -> String {
        guard var common = paths.first.map({ ($0 as NSString).pathComponents }) else { return "/" }
        for path in paths.dropFirst() {
            let components = (path as NSString).pathComponents
            common = Array(zip(common, components).prefix { $0 == $1 }.map(\.0))
        }
        let joined = NSString.path(withComponents: common)
        return joined.isEmpty ? "/" : joined
    }

    /// Хлебные крошки: «/Volumes/SSD/Проекты» → «/», «/Volumes», «/Volumes/SSD», «/Volumes/SSD/Проекты».
    public static func ancestors(of path: String) -> [String] {
        var result = ["/"]
        var current = ""
        for component in (path as NSString).pathComponents where component != "/" {
            current += "/" + component
            result.append(current)
        }
        return result
    }

    static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// «Из бэкапа 26.09.2026 20-23», при совпадении — с номером.
    static func uniqueFolder(in folder: URL, snapshot: Snapshot) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy HH-mm"
        let base = "Из бэкапа \(formatter.string(from: snapshot.time))"
        var candidate = folder.appendingPathComponent(base, isDirectory: true)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(number))", isDirectory: true)
            number += 1
        }
        return candidate
    }

    static func count(_ url: URL) -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return (0, 0) }
        guard isDirectory.boolValue else {
            return (1, Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
        var files = 0
        var bytes: Int64 = 0
        let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        while let next = enumerator?.nextObject() as? URL {
            guard let values = try? next.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (files, bytes)
    }
}

/// Строки, которые собираются из фонового потока.
final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let limit: Int

    init(limit: Int = 200) { self.limit = limit }

    func append(_ line: String) { lock.withLock { if lines.count < limit { lines.append(line) } } }
    var all: [String] { lock.withLock { lines } }
}
