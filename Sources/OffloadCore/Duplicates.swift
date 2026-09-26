import Foundation

/// Копия файла, у которого есть точные двойники.
public struct DuplicateCopy: Sendable, Hashable {
    public var url: URL
    /// Сколько места освободит удаление копии — занятое на диске: у сжатых файлов оно меньше размера.
    public var allocated: Int64
    public var modified: Date?
    public var created: Date?
    /// Решение правил по пути, то же, что для переноса. Из запрещённого места копия не удаляется.
    public var verdict: Verdict
    /// Данные общие с другой копией группы (клон APFS, как после «Дублировать» в Finder):
    /// удаление такой копии места не освободит.
    public var sharesData: Bool

    public init(url: URL, allocated: Int64, modified: Date?, created: Date?, verdict: Verdict = .safe, sharesData: Bool = false) {
        self.url = url
        self.allocated = allocated
        self.modified = modified
        self.created = created
        self.verdict = verdict
        self.sharesData = sharesData
    }
}

/// Файлы с одинаковым содержимым: совпали размер и SHA-256 всего файла.
public struct DuplicateGroup: Sendable, Hashable, Identifiable {
    /// SHA-256 содержимого.
    public var id: String
    /// Размер одной копии.
    public var bytes: Int64
    public var copies: [DuplicateCopy]

    public init(id: String, bytes: Int64, copies: [DuplicateCopy]) {
        self.id = id
        self.bytes = bytes
        self.copies = copies
    }
}

/// Отпечаток файла для поиска дубликатов. Хранится в базе решений, чтобы при следующем
/// поиске не читать заново файл, который не менялся.
public struct Fingerprint: Sendable, Hashable {
    public var path: String
    public var size: Int64
    public var modified: Double
    /// Номер файла на диске: файл, подменённый другим с той же датой и размером, не выдаст себя за прежний.
    public var inode: Int64
    /// SHA-256 первых и последних 64 КБ — быстро отсеивает разные файлы одного размера.
    public var edges: String?
    /// SHA-256 всего файла.
    public var full: String?

    public init(path: String, size: Int64, modified: Double, inode: Int64, edges: String? = nil, full: String? = nil) {
        self.path = path
        self.size = size
        self.modified = modified
        self.inode = inode
        self.edges = edges
        self.full = full
    }
}

/// Поиск одинаковых файлов в папках человека.
///
/// Файлы сравниваются по нарастающей цене: сначала размер (без чтения), потом первые и последние
/// 64 КБ, и только для совпавших — SHA-256 целиком. Внутрь пакетов (.app, медиатеки),
/// git-репозиториев, скрытых и восстанавливаемых папок (node_modules…) поиск не заходит:
/// одинаковые файлы там нужны программам. Файлы iCloud, которых нет на Mac, не читаются —
/// чтение скачало бы их.
public struct DuplicateFinder: Sendable {
    public struct Progress: Sendable, Equatable {
        /// Сколько файлов просмотрено.
        public var files = 0
        /// Сколько прочитано для сравнения.
        public var readBytes: Int64 = 0
        /// Папка, которую смотрю сейчас.
        public var current = ""

        public init() {}
    }

    public struct Result: Sendable {
        /// Группы по убыванию места, которое освободится.
        public var groups: [DuplicateGroup] = []
        /// Отпечатки прочитанных файлов: сохранить, чтобы в следующий раз не читать их заново.
        public var fingerprints: [Fingerprint] = []
        /// Сколько байт пришлось прочитать; неизменившиеся файлы берутся из отпечатков.
        public var readBytes: Int64 = 0
        /// false — поиск остановлен: итог неполный, и старые отпечатки удалять нельзя.
        public var completed = false

        public init() {}
    }

    /// Файлы меньше этого не сравниваются: мелочь не стоит времени на поиск.
    public var minimumBytes: Int64 = 1_000_000
    /// Сколько байт с начала и с конца файла идёт в быстрый отпечаток.
    public var edgeBytes = 64 * 1024
    /// Папки, внутрь которых поиск не заходит: восстанавливаются одной командой, и одинаковые файлы в них — норма.
    public var skippedFolders: Set<String> = BackupEngine.defaultExcludedNames
    /// Общий идентификатор содержимого у клонов APFS; nil — неизвестно.
    public var contentIdentifier: @Sendable (URL) -> Int64? = DuplicateFinder.apfsContentIdentifier

    public init() {}

    struct Entry {
        var url: URL
        var size: Int64
        var allocated: Int64
        var modified: Date?
        var created: Date?
        var device: Int64?
        var inode: Int64 = 0
        var clone: Int64?
        var edges: String?
        var full: String?

        var modifiedStamp: Double { modified?.timeIntervalSince1970 ?? 0 }
    }

    public func find(in roots: [URL], rules: SafetyRules, known: [String: Fingerprint] = [:],
                     isCancelled: () -> Bool = { false }, progress: (Progress) -> Void = { _ in }) -> Result {
        var result = Result()
        var state = Progress()
        guard let entries = walk(roots, isCancelled: isCancelled, state: &state, progress: progress) else { return result }

        // 1. Размер: одинаковыми могут быть только файлы одного размера. Читать пока нечего.
        let sized = Dictionary(grouping: entries, by: \.size).values
            .filter { $0.count > 1 }.map(probe).filter { $0.count > 1 }
            .sorted { ($0[0].size, $0[0].url.path) > ($1[0].size, $1[0].url.path) }

        // 2. Начало и конец: разные файлы одного размера почти всегда расходятся уже здесь.
        var printed: [String: Entry] = [:]
        var byEdges: [[Entry]] = []
        for group in sized {
            var split: [String: [Entry]] = [:]
            for var entry in group {
                if isCancelled() { return result }
                let edges: String
                if let stored = cached(entry, known), let known = stored.edges {
                    edges = known
                    entry.full = stored.full
                } else {
                    guard let read = try? FileHasher.sha256(edgesOf: entry.url, size: entry.size, edge: edgeBytes) else { continue }
                    edges = read
                    let count = min(entry.size, Int64(edgeBytes) * 2)
                    result.readBytes += count
                    state.readBytes += count
                }
                entry.edges = edges
                printed[entry.url.path] = entry
                split[edges, default: []].append(entry)
            }
            state.current = group[0].url.deletingLastPathComponent().lastPathComponent
            progress(state)
            byEdges += split.values.filter { $0.count > 1 }
        }

        // 3. Содержимое целиком — только у совпавших по краям.
        for group in byEdges {
            var split: [String: [Entry]] = [:]
            for var entry in group {
                if isCancelled() { return result }
                let full: String
                if let known = entry.full {
                    full = known
                } else if entry.size <= Int64(edgeBytes) * 2, let edges = entry.edges {
                    // Такой файл уже прочитан весь: его края и есть всё содержимое.
                    full = edges
                } else {
                    state.current = entry.url.lastPathComponent
                    progress(state)
                    do {
                        full = try FileHasher.sha256(of: entry.url, isCancelled: isCancelled) { read in
                            state.readBytes += Int64(read)
                            progress(state)
                        }
                    } catch {
                        if isCancelled() { return result }
                        continue
                    }
                    result.readBytes += entry.size
                }
                entry.full = full
                printed[entry.url.path] = entry
                split[full, default: []].append(entry)
            }
            for (hash, same) in split where same.count > 1 {
                result.groups.append(DuplicateGroup(id: hash, bytes: same[0].size, copies: copies(same, rules: rules)))
            }
        }

        result.fingerprints = printed.values
            .map { Fingerprint(path: $0.url.path, size: $0.size, modified: $0.modifiedStamp, inode: $0.inode, edges: $0.edges, full: $0.full) }
            .sorted { $0.path < $1.path }
        result.groups.sort { lhs, rhs in
            let left = Self.savings(lhs), right = Self.savings(rhs)
            return left != right ? left > right : lhs.id < rhs.id
        }
        result.completed = true
        return result
    }

    /// Сколько освободится, если оставить одну копию.
    public static func savings(_ group: DuplicateGroup) -> Int64 {
        group.copies.map(\.allocated).sorted().dropLast().reduce(0, +)
    }

    // MARK: - Обход

    func walk(_ roots: [URL], isCancelled: () -> Bool, state: inout Progress, progress: (Progress) -> Void) -> [Entry]? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                                      .totalFileAllocatedSizeKey, .contentModificationDateKey, .creationDateKey]
        let wanted = Set(keys)
        let fm = FileManager.default
        var entries: [Entry] = []
        var seen = Set<String>()
        for root in roots {
            let rootDevice = (try? fm.attributesOfItem(atPath: root.path))?[.systemNumber] as? NSNumber
            state.current = root.lastPathComponent
            progress(state)
            // Скрытые пропускаются целиком: там настройки программ, а не копии человека.
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                 errorHandler: { _, _ in true }) else { continue }
            while let url = enumerator.nextObject() as? URL {
                if isCancelled() { return nil }
                guard let values = try? url.resourceValues(forKeys: wanted), values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    if isSkipped(directory: url) { enumerator.skipDescendants() }
                    continue
                }
                state.files += 1
                if state.files % 500 == 0 {
                    state.current = url.deletingLastPathComponent().lastPathComponent
                    progress(state)
                }
                guard values.isRegularFile == true, let size = values.fileSize.map(Int64.init), size >= minimumBytes,
                      seen.insert(url.standardizedFileURL.path).inserted else { continue }
                // Файл без занятых на Mac блоков — в iCloud или другом облаке: чтение скачало бы его,
                // а удаление копии места не освободит.
                let allocated = Int64(values.totalFileAllocatedSize ?? 0)
                guard allocated > 0 else { continue }
                entries.append(Entry(url: url.standardizedFileURL, size: size, allocated: allocated,
                                     modified: values.contentModificationDate, created: values.creationDate,
                                     device: rootDevice?.int64Value))
            }
        }
        return entries
    }

    func isSkipped(directory url: URL) -> Bool {
        let name = url.lastPathComponent
        if skippedFolders.contains(name) { return true }
        // Пакеты пропускает и сам обход, но не каждый .utm или .app macOS считает пакетом,
        // если нужная программа не установлена.
        let ext = url.pathExtension.lowercased()
        if ext == "app" || SafetyRules.registeredBundleExtensions.contains(ext) { return true }
        // Проект с git: одинаковые файлы в нём — часть проекта, и о нём заботится git.
        return FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    /// Номер файла и клон: одно и то же содержимое под двумя именами (жёсткая ссылка) — это
    /// один файл, а не две копии. Файлы с другого диска, смонтированного внутри домашней папки,
    /// отбрасываются: копия на нём может исчезнуть вместе с диском.
    func probe(_ group: [Entry]) -> [Entry] {
        var result: [Entry] = []
        var files = Set<[Int64]>()
        for var entry in group {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: entry.url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let device = (attributes[.systemNumber] as? NSNumber)?.int64Value,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.int64Value else { continue }
            if let root = entry.device, root != device { continue }
            guard files.insert([device, inode]).inserted else { continue }
            entry.device = device
            entry.inode = inode
            entry.clone = contentIdentifier(entry.url)
            result.append(entry)
        }
        return result
    }

    func cached(_ entry: Entry, _ known: [String: Fingerprint]) -> Fingerprint? {
        guard let stored = known[entry.url.path], stored.size == entry.size, stored.modified == entry.modifiedStamp,
              stored.inode == entry.inode else { return nil }
        return stored
    }

    func copies(_ same: [Entry], rules: SafetyRules) -> [DuplicateCopy] {
        var clones: [[Int64]: Int] = [:]
        for entry in same {
            if let clone = entry.clone, let device = entry.device { clones[[device, clone], default: 0] += 1 }
        }
        return same.sorted { $0.url.path < $1.url.path }.map { entry in
            let shared = entry.clone.flatMap { clone in entry.device.map { clones[[$0, clone]] ?? 0 } } ?? 0
            return DuplicateCopy(url: entry.url, allocated: entry.allocated, modified: entry.modified, created: entry.created,
                                 verdict: rules.pathVerdict(for: entry.url), sharesData: shared > 1)
        }
    }

    // MARK: - Сверка перед удалением

    public enum CompareError: LocalizedError {
        case notRegularFile(String)

        public var errorDescription: String? {
            switch self {
            case .notRegularFile(let name): return "«\(name)» — уже не обычный файл."
            }
        }
    }

    /// Совпадают ли два файла байт в байт — прямо сейчас. Сравнивается содержимое, а не
    /// отпечаток из базы: файл могли поменять после поиска, не тронув дату. Одно и то же имя
    /// дважды (жёсткая ссылка) копией не считается: удаление второго имени места не освободит.
    public static func sameContent(_ first: URL, _ second: URL, isCancelled: () -> Bool = { false },
                                   progress: (Int) -> Void = { _ in }) throws -> Bool {
        let fm = FileManager.default
        let a = try fm.attributesOfItem(atPath: first.path)
        let b = try fm.attributesOfItem(atPath: second.path)
        guard a[.type] as? FileAttributeType == .typeRegular else { throw CompareError.notRegularFile(first.lastPathComponent) }
        guard b[.type] as? FileAttributeType == .typeRegular else { throw CompareError.notRegularFile(second.lastPathComponent) }
        guard let size = (a[.size] as? NSNumber)?.int64Value, size == (b[.size] as? NSNumber)?.int64Value else { return false }
        if (a[.systemNumber] as? NSNumber) == (b[.systemNumber] as? NSNumber),
           (a[.systemFileNumber] as? NSNumber) == (b[.systemFileNumber] as? NSNumber) { return false }

        let left = try FileHandle(forReadingFrom: first)
        defer { try? left.close() }
        let right = try FileHandle(forReadingFrom: second)
        defer { try? right.close() }
        while true {
            if isCancelled() { throw CancellationError() }
            let same: Bool? = try autoreleasepool {
                let one = try left.read(upToCount: FileHasher.chunkSize) ?? Data()
                let two = try right.read(upToCount: FileHasher.chunkSize) ?? Data()
                guard one == two else { return false }
                if one.isEmpty { return true }
                progress(one.count)
                return nil
            }
            if let same { return same }
        }
    }
}
