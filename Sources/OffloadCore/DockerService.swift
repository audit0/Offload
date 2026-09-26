import Darwin
import Foundation

public struct DockerVolume: Sendable, Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let createdAt: Date?
    public let sizeBytes: Int64?
    public let usedBy: [String]

    public init(name: String, createdAt: Date?, sizeBytes: Int64?, usedBy: [String]) {
        self.name = name
        self.createdAt = createdAt
        self.sizeBytes = sizeBytes
        self.usedBy = usedBy
    }
}

/// Что Docker пересоздаст сам, если понадобится. Тома сюда не входят: в них данные.
/// Порядок случаев — порядок очистки: сначала контейнеры, иначе их образы ещё считаются занятыми.
public enum DockerPruneTarget: String, CaseIterable, Sendable, Hashable {
    case containers, images, buildCache
}

/// Сколько места внутри Docker занимают образы, контейнеры, тома и кеш сборки — по `docker system df`.
public struct DockerUsage: Sendable, Equatable {
    public struct Part: Sendable, Equatable {
        public var count: Int
        public var active: Int
        public var bytes: Int64
        /// Сколько Docker готов отдать: у образов — не нужные ни одному контейнеру,
        /// у контейнеров — остановленные, у кеша — не занятый идущей сборкой.
        public var reclaimable: Int64

        public init(count: Int, active: Int, bytes: Int64, reclaimable: Int64) {
            self.count = count
            self.active = active
            self.bytes = bytes
            self.reclaimable = reclaimable
        }
    }

    public var images: Part?
    public var containers: Part?
    public var volumes: Part?
    public var buildCache: Part?

    public init(images: Part? = nil, containers: Part? = nil, volumes: Part? = nil, buildCache: Part? = nil) {
        self.images = images
        self.containers = containers
        self.volumes = volumes
        self.buildCache = buildCache
    }

    public func part(_ target: DockerPruneTarget) -> Part? {
        switch target {
        case .containers: return containers
        case .images: return images
        case .buildCache: return buildCache
        }
    }

    /// Сколько уйдёт, если очистить выбранное. Оценка снизу: образы остановленных контейнеров
    /// освобождаются, только когда удалены и сами контейнеры.
    public func reclaimable(_ targets: Set<DockerPruneTarget>) -> Int64 {
        targets.reduce(0) { $0 + (part($1)?.reclaimable ?? 0) }
    }
}

public enum DockerError: LocalizedError, Equatable {
    case notInstalled
    case notRunning
    case invalidName(String)
    case inUse(String, [String])
    case alreadyExists(String)
    case diskGuard(String)
    case failed(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "Docker не установлен."
        case .notRunning: return "Docker не запущен. Откройте Docker Desktop и повторите."
        case .invalidName(let name): return "Недопустимое имя тома: «\(name)»."
        case .inUse(let name, let containers): return "Том «\(name)» используется контейнерами: \(containers.joined(separator: ", "))."
        case .alreadyExists(let name): return "Том «\(name)» уже существует — перезаписывать не буду."
        case .diskGuard(let reason): return "Остановлено, чтобы не забить диск Mac: \(reason)"
        case .failed(let message): return message
        case .verificationFailed(let name): return "Архив тома «\(name)» не совпал с томом — том не тронут."
        }
    }
}

/// Архивация томов Docker на внешний диск и возврат обратно.
///
/// Урок из практики: вывод контейнера Docker по умолчанию пишет ещё и в свой лог внутри Docker.raw,
/// и поток архива на десятки гигабайт забивает Mac. Поэтому все потоковые запуски идут
/// с `--log-driver none` и `--network none`, у каждого контейнера есть имя (останавливается
/// сам контейнер, а не только клиент docker), а рост Docker.raw и свободное место отслеживаются.
public struct DockerService: Sendable {
    public static let helperImage = "offload-gnutar:1"
    static let helperDockerfile = "FROM alpine:3\nRUN apk add --no-cache tar\n"
    static let runPrefix = ["run", "--rm", "--log-driver", "none", "--network", "none"]

    public struct DiskGuard: Sendable {
        public var maxRawGrowth: Int64?
        public var minFreeBytes: Int64?
        public static let archiving = DiskGuard(maxRawGrowth: 3 << 30, minFreeBytes: 5 << 30)
        public static let restoring = DiskGuard(maxRawGrowth: nil, minFreeBytes: 5 << 30)
    }

    public let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    // MARK: - Проверки

    /// Имена томов Docker: `[a-zA-Z0-9][a-zA-Z0-9_.-]+`. Всё остальное (например, «/» или «:»)
    /// в аргументе `-v` превратилось бы в монтирование папки с Mac.
    public static func isValidVolumeName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count >= 2, bytes.count <= 255 else { return false }
        func alphanumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        guard alphanumeric(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { alphanumeric($0) || $0 == 95 || $0 == 46 || $0 == 45 }
    }

    public static func volumeName(fromArchive url: URL) -> String? {
        let fileName = url.lastPathComponent
        for suffix in [".tar.zst", ".tar"] where fileName.hasSuffix(suffix) {
            let name = String(fileName.dropLast(suffix.count))
            return isValidVolumeName(name) ? name : nil
        }
        return nil
    }

    /// Docker пишет размеры десятичными единицами: 31.65GB, 867.4MB, 1.002kB, 264B.
    public static func parseSize(_ text: String) -> Int64? {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for (suffix, factor) in units where trimmed.hasSuffix(suffix) {
            guard let value = Double(trimmed.dropLast(suffix.count)) else { return nil }
            return Int64((value * factor).rounded())
        }
        return nil
    }

    /// Архивы томов на диске: в папке Offload/docker-volumes и в папках docker-volumes внутри
    /// любой папки верхнего уровня — туда их кладут и ручные скрипты.
    public static func archives(on volume: VolumeInfo) -> [URL] {
        let root = volume.mountPoint
        var folders = [root.appendingPathComponent("\(SafeMover.folderName)/docker-volumes", isDirectory: true)]
        let top = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        for item in top where (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true && item.lastPathComponent != SafeMover.folderName {
            folders.append(item.appendingPathComponent("docker-volumes", isDirectory: true))
        }
        return folders.flatMap(listArchives).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func listArchives(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter {
            let name = $0.lastPathComponent
            return !name.hasPrefix(".") && (name.hasSuffix(".tar.zst") || name.hasSuffix(".tar"))
        }
    }

    public var rawDiskURL: URL {
        home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
    }

    public func rawDiskBytes() -> Int64? {
        (try? rawDiskURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize.map(Int64.init)
    }

    public var isInstalled: Bool { Runner.locate("docker") != nil }

    public func ensureRunning() throws {
        guard isInstalled else { throw DockerError.notInstalled }
        guard let result = try? Runner.run("docker", ["info", "--format", "{{.ServerVersion}}"], timeout: 20),
              result.succeeded else { throw DockerError.notRunning }
    }

    // MARK: - Тома

    /// Размеры (`docker system df`) Docker считает десятки секунд — их можно запросить отдельно через `volumeSizes()`.
    public func volumes(withSizes: Bool = true) throws -> [DockerVolume] {
        try ensureRunning()
        let names = try Runner.check("docker", ["volume", "ls", "--format", "{{.Name}}"], timeout: 60).output
            .split(separator: "\n").map(String.init).filter(Self.isValidVolumeName)
        guard !names.isEmpty else { return [] }
        let sizes = withSizes ? volumeSizes() : [:]
        var created: [String: Date] = [:]
        if let inspect = try? Runner.run("docker", ["volume", "inspect", "--format", "{{.Name}}\t{{.CreatedAt}}"] + names, timeout: 60) {
            let formatter = ISO8601DateFormatter()
            for line in inspect.output.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                if parts.count == 2, let date = formatter.date(from: parts[1]) { created[parts[0]] = date }
            }
        }
        let usage = containersByVolume()
        return names.map { name in
            DockerVolume(name: name, createdAt: created[name], sizeBytes: sizes[name], usedBy: usage[name] ?? [])
        }
    }

    /// Какие контейнеры подключают какие тома — одним вызовом, а не по вызову на каждый том.
    func containersByVolume() -> [String: [String]] {
        guard let list = try? Runner.run("docker", ["ps", "-aq"], timeout: 30), list.succeeded else { return [:] }
        let ids = list.output.split(separator: "\n").map(String.init)
        guard !ids.isEmpty,
              let inspect = try? Runner.run("docker", ["inspect", "--format",
                                                       "{{.Name}}\t{{range .Mounts}}{{if .Name}}{{.Name}}\t{{end}}{{end}}"] + ids,
                                            timeout: 60), inspect.succeeded else { return [:] }
        var usage: [String: [String]] = [:]
        for line in inspect.output.split(separator: "\n") {
            let fields = line.split(separator: "\t").map(String.init)
            guard let container = fields.first else { continue }
            let name = container.hasPrefix("/") ? String(container.dropFirst()) : container
            for volume in fields.dropFirst() { usage[volume, default: []].append(name) }
        }
        return usage
    }

    public func volumeSizes() -> [String: Int64] {
        guard let result = try? Runner.run("docker", ["system", "df", "-v", "--format", "{{json .Volumes}}"], timeout: 180),
              result.succeeded,
              let items = try? JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]] else { return [:] }
        var sizes: [String: Int64] = [:]
        for item in items {
            guard let name = item["Name"] as? String else { continue }
            if let text = item["Size"] as? String, let bytes = Self.parseSize(text) {
                sizes[name] = bytes
            } else if let number = item["Size"] as? NSNumber {
                sizes[name] = number.int64Value
            }
        }
        return sizes
    }

    // MARK: - Место внутри Docker

    static let usageFormat = "{{.Type}}\t{{.TotalCount}}\t{{.Active}}\t{{.Size}}\t{{.Reclaimable}}"

    /// Docker, как и для размеров томов, считает это десятки секунд.
    public func usage() -> DockerUsage? {
        guard let result = try? Runner.run("docker", ["system", "df", "--format", Self.usageFormat], timeout: 180),
              result.succeeded else { return nil }
        return Self.parseUsage(result.output)
    }

    /// Строки `docker system df` в формате `usageFormat`: «Images⇥25⇥3⇥12.34GB⇥10.2GB (82%)».
    /// У кеша сборки доля в скобках не пишется.
    public static func parseUsage(_ text: String) -> DockerUsage? {
        var usage = DockerUsage()
        var found = false
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 5, let count = Int(fields[1]), let active = Int(fields[2]),
                  let bytes = parseSize(fields[3]),
                  let reclaimable = parseSize(fields[4].split(separator: "(").first.map(String.init) ?? "") else { continue }
            let part = DockerUsage.Part(count: count, active: active, bytes: bytes, reclaimable: reclaimable)
            switch fields[0] {
            case "Images": usage.images = part
            case "Containers": usage.containers = part
            case "Local Volumes": usage.volumes = part
            case "Build Cache": usage.buildCache = part
            default: continue
            }
            found = true
        }
        return found ? usage : nil
    }

    public static func pruneArguments(_ target: DockerPruneTarget) -> [String] {
        switch target {
        case .containers: return ["container", "prune", "--force"]
        case .images: return ["image", "prune", "--all", "--force"]
        case .buildCache: return ["builder", "prune", "--all", "--force"]
        }
    }

    /// Итог очистки: «Total reclaimed space: 1.2GB» у `docker image prune` и `docker container prune`,
    /// «Total:⇥5.6GB» у `docker builder prune` (buildx).
    public static func parseReclaimed(_ output: String) -> Int64? {
        for line in output.split(separator: "\n").reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["Total reclaimed space:", "Total:"] where text.hasPrefix(prefix) {
                return parseSize(String(text.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    /// Удаляет выбранное из того, что Docker пересоздаст сам. Тома не трогаются никогда.
    /// Возвращает, сколько места Docker назвал освободившимся, или nil, если он не сказал.
    public func prune(_ targets: Set<DockerPruneTarget>, status: (DockerPruneTarget) -> Void = { _ in }) throws -> Int64? {
        try ensureRunning()
        var reclaimed: Int64?
        for target in DockerPruneTarget.allCases where targets.contains(target) {
            status(target)
            let result = try Runner.check("docker", Self.pruneArguments(target), timeout: 1800)
            if let bytes = Self.parseReclaimed(result.output) { reclaimed = (reclaimed ?? 0) + bytes }
        }
        return reclaimed
    }

    public func containers(using name: String) throws -> [String] {
        guard Self.isValidVolumeName(name) else { throw DockerError.invalidName(name) }
        let result = try Runner.check("docker", ["ps", "-a", "--filter", "volume=\(name)", "--format", "{{.Names}}"], timeout: 30)
        return result.output.split(separator: "\n").map(String.init)
    }

    /// Когда в томе последний раз что-то менялось (по датам файлов и папок на глубине до трёх уровней).
    public func lastActivity(of name: String, isCancelled: () -> Bool = { false }) throws -> Date? {
        guard Self.isValidVolumeName(name) else { throw DockerError.invalidName(name) }
        try ensureRunning()
        try ensureHelperImage()
        let output = try stream(["-v", "\(name):/v:ro", Self.helperImage, "sh", "-c",
                                 "find /v -maxdepth 3 -exec stat -c %Y {} + 2>/dev/null | sort -n | tail -1"],
                                feed: nil, sink: .capture, guard: nil, isCancelled: isCancelled)
        return TimeInterval(output).map { Date(timeIntervalSince1970: $0) }
    }

    func ensureHelperImage() throws {
        if (try? Runner.run("docker", ["image", "inspect", Self.helperImage], timeout: 30))?.succeeded == true { return }
        try Runner.check("docker", ["build", "-q", "-t", Self.helperImage, "-"],
                         stdin: Data(Self.helperDockerfile.utf8), timeout: 900)
    }

    // MARK: - Архивация и возврат

    /// Упаковывает том в архив и сверяет список всех путей архива со списком тома.
    /// Сам том не удаляется — это отдельный шаг `removeVolume` после успешной архивации.
    public func archive(_ name: String, into directory: URL, isCancelled: () -> Bool = { false },
                        status: (String) -> Void = { _ in }) throws -> URL {
        guard Self.isValidVolumeName(name) else { throw DockerError.invalidName(name) }
        try ensureRunning()
        let users = try containers(using: name)
        guard users.isEmpty else { throw DockerError.inUse(name, users) }
        status("Подготовка образа с GNU tar")
        try ensureHelperImage()

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let compressed = Runner.locate("zstd") != nil
        let final = SafeMover.unique(directory.appendingPathComponent(compressed ? "\(name).tar.zst" : "\(name).tar"))
        let partial = directory.appendingPathComponent(".\(name).partial-\(UUID().uuidString)")
        do {
            status("Упаковка тома")
            _ = try stream(["-v", "\(name):/v:ro", Self.helperImage, "tar", "-cf", "-", "-C", "/v", "."],
                           feed: nil, sink: compressed ? .compress(partial) : .file(partial),
                           guard: .archiving, isCancelled: isCancelled)
            status("Сверка: список файлов тома")
            let volumeDigest = try digest(ofVolume: name, isCancelled: isCancelled)
            status("Сверка: список файлов архива")
            let archiveDigest = try digest(ofArchive: partial, compressed: compressed, isCancelled: isCancelled)
            guard !volumeDigest.isEmpty, volumeDigest == archiveDigest else { throw DockerError.verificationFailed(name) }
            try SafeMover.renameExclusive(partial, to: final)
        } catch {
            try? fm.removeItem(at: partial)
            SafeMover.removeSidecar(of: partial)
            throw error
        }
        if Volumes.info(for: directory)?.createsAppleDouble == true {
            SafeMover.removeSidecar(of: final)
            SafeMover.removeSidecar(of: partial)
        }
        return final
    }

    public func removeVolume(_ name: String) throws {
        guard Self.isValidVolumeName(name) else { throw DockerError.invalidName(name) }
        let users = try containers(using: name)
        guard users.isEmpty else { throw DockerError.inUse(name, users) }
        try Runner.check("docker", ["volume", "rm", name], timeout: 120)
    }

    /// Создаёт том из архива и сверяет результат. Существующий том не перезаписывается.
    public func restore(archive: URL, as name: String, isCancelled: () -> Bool = { false },
                        status: (String) -> Void = { _ in }) throws {
        guard Self.isValidVolumeName(name) else { throw DockerError.invalidName(name) }
        try ensureRunning()
        if (try? Runner.run("docker", ["volume", "inspect", name], timeout: 30))?.succeeded == true {
            throw DockerError.alreadyExists(name)
        }
        status("Подготовка образа с GNU tar")
        try ensureHelperImage()
        let compressed = archive.pathExtension.lowercased() == "zst"
        try Runner.check("docker", ["volume", "create", name], timeout: 60)
        do {
            status("Распаковка в том")
            _ = try stream(["-i", "-v", "\(name):/v", Self.helperImage, "tar", "-xpf", "-", "-C", "/v"],
                           feed: compressed ? .decompress(archive) : .file(archive), sink: .capture,
                           guard: .restoring, isCancelled: isCancelled)
            status("Сверка")
            let volumeDigest = try digest(ofVolume: name, isCancelled: isCancelled)
            let archiveDigest = try digest(ofArchive: archive, compressed: compressed, isCancelled: isCancelled)
            guard !volumeDigest.isEmpty, volumeDigest == archiveDigest else { throw DockerError.verificationFailed(name) }
        } catch {
            // Том создан нами в этом же вызове — при сбое его можно убрать.
            _ = try? Runner.run("docker", ["volume", "rm", name], timeout: 120)
            throw error
        }
    }

    static func listing(_ producer: String) -> String {
        producer + " | sed 's|/$||' | LC_ALL=C sort > /tmp/list && echo \"$(wc -l < /tmp/list) $(sha256sum /tmp/list | cut -d' ' -f1)\""
    }

    func digest(ofVolume name: String, isCancelled: () -> Bool) throws -> String {
        try stream(["-v", "\(name):/v:ro", Self.helperImage, "sh", "-c", "cd /v && " + Self.listing("find . ! -type s")],
                   feed: nil, sink: .capture, guard: nil, isCancelled: isCancelled)
    }

    func digest(ofArchive url: URL, compressed: Bool, isCancelled: () -> Bool) throws -> String {
        try stream(["-i", Self.helperImage, "sh", "-c", Self.listing("tar -tf - --quoting-style=literal")],
                   feed: compressed ? .decompress(url) : .file(url), sink: .capture, guard: nil, isCancelled: isCancelled)
    }

    // MARK: - Потоки

    enum Feed {
        case file(URL)
        case decompress(URL)
    }

    enum Sink {
        case file(URL)
        case compress(URL)
        case capture
    }

    /// Запускает контейнер с потоковым вводом и выводом, следя за отменой и диском.
    func stream(_ arguments: [String], feed: Feed?, sink: Sink, guard diskGuard: DiskGuard?,
                isCancelled: () -> Bool) throws -> String {
        let container = "offload-\(UUID().uuidString.prefix(12).lowercased())"
        let docker = try Runner.makeProcess("docker", Self.runPrefix + ["--name", container] + arguments)
        docker.standardError = FileHandle.nullDevice
        var helpers: [Process] = []
        var readHandle: FileHandle?
        var writeHandle: FileHandle?

        switch feed {
        case .file(let url)?:
            let handle = try FileHandle(forReadingFrom: url)
            readHandle = handle
            docker.standardInput = handle
        case .decompress(let url)?:
            let zstd = try Runner.makeProcess("zstd", ["-dcq", "--", url.path])
            let pipe = Pipe()
            zstd.standardOutput = pipe
            zstd.standardError = FileHandle.nullDevice
            docker.standardInput = pipe
            helpers.append(zstd)
        case nil:
            docker.standardInput = FileHandle.nullDevice
        }

        let captured = Pipe()
        switch sink {
        case .file(let url):
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
            guard descriptor >= 0 else { throw CopyError.writeFailed(url.path, String(cString: strerror(errno))) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            writeHandle = handle
            docker.standardOutput = handle
        case .compress(let url):
            let zstd = try Runner.makeProcess("zstd", ["-T0", "-3", "-q", "-o", url.path])
            let pipe = Pipe()
            zstd.standardInput = pipe
            zstd.standardError = FileHandle.nullDevice
            docker.standardOutput = pipe
            helpers.append(zstd)
        case .capture:
            docker.standardOutput = captured
        }

        let collected = Collected()
        let group = DispatchGroup()
        if case .capture = sink {
            group.enter()
            DispatchQueue.global().async {
                collected.out = captured.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        let startRaw = diskGuard?.maxRawGrowth == nil ? nil : rawDiskBytes()
        var launched: [Process] = []
        do {
            for helper in helpers {
                try helper.run()
                launched.append(helper)
            }
            try docker.run()
            launched.append(docker)
            try watch(launched, container: container, startRaw: startRaw, diskGuard: diskGuard, isCancelled: isCancelled)
        } catch {
            stop(launched, container: container)
            if !launched.contains(where: { $0 === docker }) { try? captured.fileHandleForWriting.close() }
            try? readHandle?.close()
            try? writeHandle?.close()
            group.wait()
            throw error
        }
        try? writeHandle?.synchronize()
        try? writeHandle?.close()
        try? readHandle?.close()
        group.wait()
        guard docker.terminationStatus == 0 else {
            throw DockerError.failed("docker завершился с кодом \(docker.terminationStatus)")
        }
        if let helper = helpers.first(where: { $0.terminationStatus != 0 }) {
            throw DockerError.failed("zstd завершился с кодом \(helper.terminationStatus)")
        }
        return String(decoding: collected.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func watch(_ processes: [Process], container: String, startRaw: Int64?, diskGuard: DiskGuard?,
               isCancelled: () -> Bool) throws {
        var lastCheck = Date()
        while processes.contains(where: { $0.isRunning }) {
            if isCancelled() {
                stop(processes, container: container)
                throw CancellationError()
            }
            if let diskGuard, Date().timeIntervalSince(lastCheck) >= 5 {
                lastCheck = Date()
                if let limit = diskGuard.maxRawGrowth, let startRaw, let now = rawDiskBytes(), now - startRaw > limit {
                    stop(processes, container: container)
                    throw DockerError.diskGuard("Docker.raw вырос на \(Format.bytes(now - startRaw)).")
                }
                if let minimum = diskGuard.minFreeBytes, let free = Volumes.info(for: home)?.availableBytes, free < minimum {
                    stop(processes, container: container)
                    throw DockerError.diskGuard("на Mac осталось \(Format.bytes(free)).")
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    func stop(_ processes: [Process], container: String) {
        // Останавливаем именно контейнер: если убить только клиент docker, контейнер продолжит работать.
        _ = try? Runner.run("docker", ["rm", "-f", container], timeout: 60)
        for process in processes where process.isRunning { process.terminate() }
        for process in processes { process.waitUntilExit() }
    }
}
