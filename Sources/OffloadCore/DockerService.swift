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
///
/// `danglingImages` — образы без имени (`<none>`), остатки пересборок: их не пересобрать и не скачать,
/// но они и не нужны — у них нет имени, по которому их можно запустить. `images` — все образы,
/// не нужные ни одному контейнеру: из реестра Docker скачает их снова, а собранные вами
/// и никуда не отправленные придётся собрать заново, поэтому сами они не отмечаются.
public enum DockerPruneTarget: String, CaseIterable, Sendable, Hashable {
    case containers, danglingImages, images, buildCache
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
        // Сколько занимают образы без имени, docker system df не сообщает.
        case .danglingImages: return nil
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
    case remoteDaemon(String)
    /// Часть целей очищена, на следующей Docker ответил ошибкой.
    case pruneIncomplete(done: Int, reclaimed: Int64?, message: String)

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
        case .pruneIncomplete(let done, let reclaimed, let message):
            let freed = reclaimed.map { ", освобождено \(Format.bytes($0))" } ?? ""
            return "Docker очистил только часть выбранного (\(done) из выбранных пунктов\(freed)), а дальше остановился: \(message)"
        case .remoteDaemon(let host): return "Docker сейчас смотрит не на этот Mac, а на «\(host)» (контекст Docker или DOCKER_HOST). Очищать и архивировать чужой Docker OffLoadAI не будет: переключитесь на локальный контекст (docker context use desktop-linux или default) и повторите."
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
    /// От этого образа зависит сверка перед удалением тома, поэтому база закреплена по digest,
    /// а свой образ узнаётся по метке: чужой образ с тем же тегом (docker build, compose) пересобирается.
    public static let helperImage = "offload-gnutar:2"
    static let helperLabel = "io.github.audit0.offload.helper"
    static let helperLabelValue = "2"
    static let helperDockerfile = """
        FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
        RUN apk add --no-cache tar
        LABEL \(helperLabel)=\(helperLabelValue)

        """
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
        // Контекст Docker (docker context use …) или DOCKER_HOST могут вести на сервер. Тогда
        // «Очистить Docker» удалил бы кеш и образы там, а архивация — перекачала бы и удалила его тома.
        let host = endpoint()
        guard let host, host.hasPrefix("unix://") else { throw DockerError.remoteDaemon(host ?? "неизвестно") }
    }

    /// Куда смотрит клиент docker: DOCKER_HOST или адрес текущего контекста.
    func endpoint() -> String? {
        if let host = Runner.environment["DOCKER_HOST"], !host.isEmpty { return host }
        guard let result = try? Runner.run("docker", ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], timeout: 20),
              result.succeeded else { return nil }
        let host = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? nil : host
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

    /// Что и в каком порядке чистить: сначала контейнеры, иначе их образы ещё заняты.
    /// Все неиспользуемые образы включают и образы без имени — второй раз их не чистим.
    public static func pruneOrder(_ targets: Set<DockerPruneTarget>) -> [DockerPruneTarget] {
        DockerPruneTarget.allCases.filter { targets.contains($0) && !($0 == .danglingImages && targets.contains(.images)) }
    }

    public static func pruneArguments(_ target: DockerPruneTarget) -> [String] {
        switch target {
        case .containers: return ["container", "prune", "--force"]
        case .danglingImages: return ["image", "prune", "--force"]
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
        var done = 0
        for target in Self.pruneOrder(targets) {
            status(target)
            do {
                let result = try Runner.check("docker", Self.pruneArguments(target), timeout: 1800)
                if let bytes = Self.parseReclaimed(result.output) { reclaimed = (reclaimed ?? 0) + bytes }
                done += 1
            } catch {
                // Удалённое до ошибки уже не вернуть: «не получилось» было бы неправдой.
                guard done > 0 else { throw error }
                throw DockerError.pruneIncomplete(done: done, reclaimed: reclaimed, message: error.localizedDescription)
            }
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
        let format = "{{index .Config.Labels \"\(Self.helperLabel)\"}}"
        if let result = try? Runner.run("docker", ["image", "inspect", "--format", format, Self.helperImage], timeout: 30),
           result.succeeded, result.output.trimmingCharacters(in: .whitespacesAndNewlines) == Self.helperLabelValue { return }
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
        if rawDiskBytes() == nil {
            // Не Docker Desktop (OrbStack, Colima) или Docker.raw лежит в другом месте: за ростом его
            // диска следить нечем. Остаётся защита по свободному месту на Mac — и об этом надо сказать.
            status("Диск Docker не найден: за его ростом не слежу, только за свободным местом на Mac")
        }
        let final = SafeMover.unique(directory.appendingPathComponent(compressed ? "\(name).tar.zst" : "\(name).tar"))
        let partial = directory.appendingPathComponent(".\(name).partial-\(UUID().uuidString)")
        do {
            status("Упаковка тома")
            // --hard-dereference: жёсткая ссылка иначе ляжет в архив ссылкой без содержимого,
            // и сверка содержимого её не увидит.
            _ = try stream(["-v", "\(name):/v:ro", Self.helperImage, "tar", "--hard-dereference", "-cf", "-", "-C", "/v", "."],
                           feed: nil, sink: compressed ? .compress(partial) : .file(partial),
                           guard: .archiving, isCancelled: isCancelled)
            status("Сверка: список файлов тома")
            let volumeDigest = try digest(ofVolume: name, isCancelled: isCancelled)
            status("Сверка: список файлов архива")
            let archiveDigest = try digest(ofArchive: partial, compressed: compressed, isCancelled: isCancelled)
            guard !volumeDigest.isEmpty, volumeDigest == archiveDigest else { throw DockerError.verificationFailed(name) }
            // Оба отпечатка считает один и тот же вспомогательный образ. Независимо от него архив
            // читает системный tar на Mac: число записей должно совпасть с числом путей в томе.
            status("Сверка: архив читается на Mac")
            guard let listed = Self.archiveEntryCount(partial, compressed: compressed, isCancelled: isCancelled),
                  listed == Int(volumeDigest.split(separator: " ").first ?? "") else {
                throw DockerError.verificationFailed(name)
            }
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
        try Self.requireRegularFile(archive)
        try ensureRunning()
        // «Тома нет» — только когда Docker так и ответил. Тайм-аут или любая другая ошибка раньше
        // тоже считались отсутствием тома: архив распаковывался в живой том, а при неудачной
        // сверке тот ещё и удалялся.
        let inspect = try Runner.run("docker", ["volume", "inspect", name], timeout: 30)
        if inspect.succeeded { throw DockerError.alreadyExists(name) }
        guard inspect.stderr.lowercased().contains("no such volume") else {
            throw DockerError.failed("Не удалось проверить, есть ли уже том «\(name)»: \(inspect.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        status("Подготовка образа с GNU tar")
        try ensureHelperImage()
        let compressed = archive.pathExtension.lowercased() == "zst"
        // Метка с одноразовым значением: по ней видно, что том создан этим вызовом. Если том
        // появился между проверкой и созданием, `volume create` ответит успехом и вернёт чужой том —
        // метки на нём не будет, и ни распаковки, ни удаления не случится.
        let mark = UUID().uuidString
        try Runner.check("docker", ["volume", "create", "--label", "\(Self.restoreLabel)=\(mark)", name], timeout: 60)
        guard restoreMark(of: name) == mark else { throw DockerError.alreadyExists(name) }
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
            // Удаляем, только если на томе наша метка: том создан этим вызовом.
            if restoreMark(of: name) == mark {
                _ = try? Runner.run("docker", ["volume", "rm", name], timeout: 120)
            }
            throw error
        }
    }

    /// Сколько записей в архиве по мнению /usr/bin/tar (libarchive) — без Docker и без
    /// вспомогательного образа. `nil` — архив не читается.
    static func archiveEntryCount(_ url: URL, compressed: Bool, isCancelled: () -> Bool) -> Int? {
        guard let tar = try? Runner.makeProcess("tar", ["-tf", compressed ? "-" : url.path]) else { return nil }
        var helpers: [Process] = []
        if compressed {
            guard let zstd = try? Runner.makeProcess("zstd", ["-dcq", "--", url.path]) else { return nil }
            let pipe = Pipe()
            zstd.standardOutput = pipe
            zstd.standardError = FileHandle.nullDevice
            tar.standardInput = pipe
            helpers.append(zstd)
        } else {
            tar.standardInput = FileHandle.nullDevice
        }
        let output = Pipe()
        tar.standardOutput = output
        tar.standardError = FileHandle.nullDevice
        let collected = Collected()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            collected.out = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        do {
            for helper in helpers { try helper.run() }
            try tar.run()
        } catch {
            for helper in helpers where helper.isRunning { helper.terminate() }
            try? output.fileHandleForWriting.close()
            group.wait()
            return nil
        }
        while tar.isRunning || helpers.contains(where: \.isRunning) {
            if isCancelled() {
                tar.terminate()
                for helper in helpers { helper.terminate() }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        group.wait()
        guard !isCancelled(), tar.terminationStatus == 0, helpers.allSatisfy({ $0.terminationStatus == 0 }) else { return nil }
        return collected.out.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
    }

    static let restoreLabel = "io.github.audit0.offload.restore"

    func restoreMark(of name: String) -> String? {
        let format = "{{index .Labels \"\(Self.restoreLabel)\"}}"
        guard let result = try? Runner.run("docker", ["volume", "inspect", "--format", format, name], timeout: 30),
              result.succeeded else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Архив с чужого диска: на его месте может лежать ссылка на файл с Mac или FIFO,
    /// на котором чтение повисло бы навсегда.
    static func requireRegularFile(_ url: URL) throws {
        guard (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular else {
            throw CopyError.unreadable(url.path)
        }
    }

    /// Отпечаток: число и SHA-256 отсортированного списка путей, затем число и SHA-256 списка
    /// «хеш содержимого — путь» для обычных файлов. Раньше сверялись только имена: архив,
    /// обрезанный посередине последнего файла, давал тот же отпечаток, что и целый, и том удалялся.
    /// pipefail — чтобы ошибка tar или find не терялась в конвейере.
    static func summary(names: String, files: String) -> String {
        "set -eo pipefail; " + names + " | sed 's|/$||' | LC_ALL=C sort > /tmp/list; "
            + files + " | LC_ALL=C sort > /tmp/files; "
            + "echo \"$(wc -l < /tmp/list) $(sha256sum < /tmp/list | cut -d' ' -f1) $(wc -l < /tmp/files) $(sha256sum < /tmp/files | cut -d' ' -f1)\""
    }

    /// «хеш — путь» для файла в $f; содержимое читается из `input` (пусто — из stdin).
    /// Строка одна и та же для тома и архива, иначе отпечатки разошлись бы на ровном месте.
    static func hashLine(input: String) -> String {
        #"h=$(sha256sum"# + input + #" | cut -d' ' -f1) && printf '%s  %s\n' "$h" "$f""#
    }

    static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// Отпечаток тома, смонтированного в /v.
    static var volumeDigestScript: String {
        summary(names: "cd /v && find . ! -type s",
                files: "find . -type f -exec sh -c " + quoted("for f; do " + hashLine(input: #" < "$f""#) + "; done") + " _ {} +")
    }

    /// Отпечаток архива из stdin. Архив читается один раз: -v выдаёт все имена, --to-command получает
    /// содержимое каждого обычного файла (имя — в TAR_FILENAME). Остальное tar создаёт во временной папке контейнера.
    static func archiveDigestScript(tar: String = "tar") -> String {
        let command = #"f="$TAR_FILENAME"; "# + hashLine(input: "") + " >> /tmp/hashes"
        return summary(names: "mkdir -p /tmp/x && : > /tmp/hashes && " + tar
                        + " -xvf - -C /tmp/x --quoting-style=literal --to-command=" + quoted(command),
                       files: "cat /tmp/hashes")
    }

    func digest(ofVolume name: String, isCancelled: () -> Bool) throws -> String {
        try stream(["-v", "\(name):/v:ro", Self.helperImage, "sh", "-c", Self.volumeDigestScript],
                   feed: nil, sink: .capture, guard: nil, isCancelled: isCancelled)
    }

    func digest(ofArchive url: URL, compressed: Bool, isCancelled: () -> Bool) throws -> String {
        try Self.requireRegularFile(url)
        return try stream(["-i", Self.helperImage, "sh", "-c", Self.archiveDigestScript()],
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
            // Без перехода по ссылке и без зависания на FIFO: архив лежит на чужом диске.
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw CopyError.unreadable(url.path) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                try? handle.close()
                throw CopyError.unreadable(url.path)
            }
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
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
