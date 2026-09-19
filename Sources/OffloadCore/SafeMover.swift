import Darwin
import Foundation

public struct MoveRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var date: Date
    public var originalPath: String
    public var archivedPath: String
    public var volumeName: String
    public var files: Int
    public var bytes: Int64
    public var originalRemoved: Bool
    public var restored: Bool
    /// Пояснение для человека: например, что архив упакован в tar.gz.
    public var note: String?

    public init(id: UUID = UUID(), date: Date = Date(), originalPath: String, archivedPath: String, volumeName: String,
                files: Int, bytes: Int64, originalRemoved: Bool = false, restored: Bool = false, note: String? = nil) {
        self.id = id
        self.date = date
        self.originalPath = originalPath
        self.archivedPath = archivedPath
        self.volumeName = volumeName
        self.files = files
        self.bytes = bytes
        self.originalRemoved = originalRemoved
        self.restored = restored
        self.note = note
    }
}

public enum MovePhase: String, Sendable {
    case inspecting = "Проверка"
    case copying = "Копирование"
    case verifying = "Сверка"
    case removing = "Удаление оригинала"
}

public struct MoveProgress: Sendable {
    public var phase: MovePhase
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var item: String

    public init(phase: MovePhase, bytesDone: Int64, bytesTotal: Int64, item: String) {
        self.phase = phase
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.item = item
    }

    public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }
}

public enum MoveError: LocalizedError, Equatable {
    case blocked(String)
    case needsConfirmation([String])
    case destination([String])
    case unsafeRecord(String)
    case alreadyExists(String)
    case contentMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .blocked(let reason): return reason
        case .needsConfirmation(let notes): return "Нужно подтверждение: " + notes.joined(separator: " ")
        case .destination(let blockers): return blockers.joined(separator: " ")
        case .unsafeRecord(let reason): return "Запись журнала выглядит небезопасной: \(reason)"
        case .alreadyExists(let path): return "«\(path)» уже существует — перезаписывать не буду."
        case .contentMismatch(let detail): return "Содержимое не совпало с проверкой, ничего не удалено: \(detail). Проверьте ещё раз."
        }
    }
}

public struct MovePlan: Sendable {
    public let source: URL
    public let content: ContentReport
    public let verdict: Verdict
    public let volume: VolumeInfo
    public let check: DestinationCheck
    public let target: URL

    public var canProceed: Bool { !verdict.isBlocked && check.isOK }
}

/// Перенос на внешний диск: копия → сверка SHA-256 → проверка, что оригинал не менялся → удаление оригинала.
public struct SafeMover: Sendable {
    public static let folderName = "Offload"
    public let rules: SafetyRules

    public init(rules: SafetyRules = SafetyRules()) { self.rules = rules }

    // MARK: - План

    public func plan(source: URL, volume: VolumeInfo, isCancelled: () -> Bool = { false }) -> MovePlan {
        let content = Inspector.inspect(source, isCancelled: isCancelled)
        let openBy = Self.openFiles(in: source)
        var verdict = rules.verdict(for: source, content: content, openBy: openBy ?? [])
        if openBy == nil {
            // Проверить не удалось — не делаем вид, что всё чисто.
            let note = "Не удалось проверить, открыты ли файлы в других приложениях. Закройте приложения, которые могут с ними работать."
            switch verdict {
            case .safe: verdict = .caution([note])
            case .caution(let notes): verdict = .caution(notes + [note])
            case .blocked: break
            }
        }
        let check = SafetyRules.checkDestination(volume, sourceVolume: Volumes.info(for: source), content: content)
        return MovePlan(source: source, content: content, verdict: verdict, volume: volume, check: check,
                        target: targetURL(for: source, on: volume))
    }

    /// Offload/<путь относительно домашней папки>: по архиву сразу видно, откуда объект.
    public func targetURL(for source: URL, on volume: VolumeInfo) -> URL {
        let path = source.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(source.lastPathComponent).standardizedFileURL.path
        let home = rules.home.path
        let relative: String
        if path.hasPrefix(home + "/") {
            relative = String(path.dropFirst(home.count + 1))
        } else if path.hasPrefix("/Users/Shared/") {
            relative = "Shared/" + path.dropFirst("/Users/Shared/".count)
        } else {
            relative = source.lastPathComponent
        }
        return Self.unique(volume.mountPoint.appendingPathComponent(Self.folderName, isDirectory: true)
            .appendingPathComponent(relative))
    }

    /// Кто держит файлы открытыми. Один общий вызов lsof быстрее, чем `lsof +D` по большой папке.
    /// `nil` — проверить не удалось.
    public static func openFiles(in url: URL) -> [String]? {
        guard let result = try? Runner.run("lsof", ["-w", "-n", "-P", "-F", "cn"], timeout: 30),
              !result.output.isEmpty else { return nil }
        let prefixes = Set([url.standardizedFileURL.path, url.resolvingSymlinksInPath().path])
        var command = ""
        var holders = Set<String>()
        for line in result.output.split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "c": command = value
            case "n" where prefixes.contains(where: { value == $0 || value.hasPrefix($0 + "/") }): holders.insert(command)
            default: break
            }
        }
        holders.remove("Offload")
        return holders.sorted()
    }

    // MARK: - Перенос

    public func execute(_ plan: MovePlan, deleteOriginal: Bool, acceptCautions: Bool,
                        isCancelled: () -> Bool = { false },
                        progress: (MoveProgress) -> Void = { _ in }) throws -> MoveRecord {
        if case .blocked(let reason) = plan.verdict { throw MoveError.blocked(reason) }
        if case .caution(let notes) = plan.verdict, !acceptCautions { throw MoveError.needsConfirmation(notes) }
        guard plan.check.isOK else { throw MoveError.destination(plan.check.blockers) }
        guard !Self.exists(plan.target) else { throw MoveError.alreadyExists(plan.target.path) }

        let fm = FileManager.default
        let source = plan.source
        progress(MoveProgress(phase: .inspecting, bytesDone: 0, bytesTotal: 0, item: source.lastPathComponent))
        let entries = try TreeWalker.walk(source, strict: true, isCancelled: isCancelled).entries
        try Self.assertMatches(entries, plan.content)
        let total = entries.reduce(Int64(0)) { $0 + $1.size }

        let parent = plan.target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // Копия пишется под временным именем: при сбое удаляется только она, чужие файлы не трогаются.
        let partial = parent.appendingPathComponent(".offload-partial-\(UUID().uuidString)")
        let hashes: [String: String]
        var wroteModes = false
        do {
            var copied: Int64 = 0
            hashes = try VerifiedCopy.copyTree(entries, from: source, to: partial, keepPermissions: true, isCancelled: isCancelled) { name, bytes in
                copied += Int64(bytes)
                progress(MoveProgress(phase: .copying, bytesDone: copied, bytesTotal: total, item: name))
            }
            var verified: Int64 = 0
            try VerifiedCopy.verify(entries, hashes: hashes, at: partial, isCancelled: isCancelled) { name, bytes in
                verified += Int64(bytes)
                progress(MoveProgress(phase: .verifying, bytesDone: verified, bytesTotal: total, item: name))
            }
            try VerifiedCopy.assertUnchanged(entries, at: source)
            try Self.writeModes(entries, next: plan.target)
            wroteModes = true
            try Self.renameExclusive(partial, to: plan.target)
        } catch {
            try? fm.removeItem(at: partial)
            Self.removeSidecar(of: partial)
            if wroteModes { try? fm.removeItem(at: Self.modesURL(for: plan.target)) }
            throw error
        }
        if plan.volume.createsAppleDouble {
            VerifiedCopy.removeAppleDouble(for: entries, at: plan.target)
            Self.removeSidecar(of: partial)
        }
        let checksums = Self.checksumURL(for: plan.target)
        try VerifiedCopy.checksumList(hashes, rootName: plan.target.lastPathComponent)
            .write(to: checksums, atomically: false, encoding: .utf8)
        if plan.volume.createsAppleDouble {
            Self.removeSidecar(of: checksums)
            Self.removeSidecar(of: Self.modesURL(for: plan.target))
        }

        var record = MoveRecord(originalPath: source.path, archivedPath: plan.target.path, volumeName: plan.volume.name,
                                files: hashes.count, bytes: total)
        try Journal.save(record, volume: plan.volume)
        if deleteOriginal {
            progress(MoveProgress(phase: .removing, bytesDone: total, bytesTotal: total, item: source.lastPathComponent))
            try VerifiedCopy.assertUnchanged(entries, at: source)
            try fm.removeItem(at: source)
            record.originalRemoved = true
            try? Journal.save(record, volume: plan.volume)
        }
        return record
    }

    // MARK: - Ручные переносы

    /// Регистрирует перенос, сделанный без Offload: папка или файл уже лежит на внешнем диске.
    /// Запись попадает в журнал, и вернуть данные можно как обычно.
    public func importRecord(archived: URL, original: URL, originalRemoved: Bool, note: String? = nil) throws -> MoveRecord {
        var record = MoveRecord(originalPath: original.standardizedFileURL.path, archivedPath: archived.standardizedFileURL.path,
                                volumeName: "", files: 0, bytes: 0, originalRemoved: originalRemoved, note: note)
        let (archivedURL, _) = try validate(record)
        guard Self.exists(archivedURL) else { throw MoveError.unsafeRecord("на диске нет «\(archivedURL.path)»") }
        guard let volume = Volumes.info(for: archivedURL), volume.mountPoint.path.hasPrefix("/Volumes/") else {
            throw MoveError.unsafeRecord("«\(archivedURL.path)» лежит не на внешнем диске")
        }
        let content = Inspector.inspect(archivedURL)
        record.volumeName = volume.name
        record.files = content.files
        record.bytes = content.logicalBytes
        try Journal.save(record, volume: volume)
        return record
    }

    // MARK: - Возврат

    /// Журнал лежит на внешнем диске, и его могли изменить. Прежде чем читать и писать
    /// по путям из него, убеждаемся, что они не выходят за разрешённые границы.
    public func validate(_ record: MoveRecord) throws -> (archived: URL, original: URL) {
        let archived = URL(fileURLWithPath: record.archivedPath).standardizedFileURL
        let original = URL(fileURLWithPath: record.originalPath).standardizedFileURL
        guard record.archivedPath.hasPrefix("/"), record.originalPath.hasPrefix("/"),
              archived.path == record.archivedPath, original.path == record.originalPath else {
            throw MoveError.unsafeRecord("пути должны быть абсолютными и без «..»")
        }
        // Не только папка Offload: переносы, сделанные вручную, лежат где угодно на внешнем диске.
        let components = archived.pathComponents
        guard components.count >= 4, components[1] == "Volumes" else {
            throw MoveError.unsafeRecord("архив должен лежать на внешнем диске, в /Volumes")
        }
        guard archived.resolvingSymlinksInPath().path == archived.path else {
            throw MoveError.unsafeRecord("путь к архиву проходит через символическую ссылку")
        }
        if case .blocked(let reason) = rules.pathVerdict(for: original) {
            throw MoveError.unsafeRecord(reason)
        }
        return (archived, original)
    }

    public func restore(_ record: MoveRecord, deleteArchive: Bool,
                        isCancelled: () -> Bool = { false },
                        progress: (MoveProgress) -> Void = { _ in }) throws -> MoveRecord {
        let (archived, original) = try validate(record)
        // Приложение могло оставить на старом месте пустую папку (так делает LM Studio с папкой моделей) — её можно заменить.
        if Self.exists(original), !Self.isEmptyDirectory(original) { throw MoveError.alreadyExists(original.path) }
        guard let volume = Volumes.info(for: archived), Self.exists(archived) else {
            throw MoveError.unsafeRecord("архив не найден — подключите диск «\(record.volumeName)»")
        }
        let fm = FileManager.default
        // Служебные файлы Finder на внешнем диске обратно не везём.
        var skippedFiles = 0
        let entries = try TreeWalker.walk(archived, strict: true, exclude: { relative, isDirectory in
            let name = (relative as NSString).lastPathComponent
            if !isDirectory, name == ".DS_Store" {
                skippedFiles += 1
                return true
            }
            guard !isDirectory, name.hasPrefix("._") else { return false }
            let sibling = ((relative as NSString).deletingLastPathComponent as NSString).appendingPathComponent(String(name.dropFirst(2)))
            guard Self.exists(archived.appendingPathComponent(sibling)) else { return false }
            skippedFiles += 1
            return true
        }, isCancelled: isCancelled).entries
        try Self.assertMatches(entries, Inspector.inspect(archived, isCancelled: isCancelled), skippedFiles: skippedFiles)
        let total = entries.reduce(Int64(0)) { $0 + $1.size }

        let parent = original.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let partial = parent.appendingPathComponent(".offload-partial-\(UUID().uuidString)")
        do {
            var copied: Int64 = 0
            let hashes = try VerifiedCopy.copyTree(entries, from: archived, to: partial, keepPermissions: volume.fsType == "apfs",
                                                   isCancelled: isCancelled) { name, bytes in
                copied += Int64(bytes)
                progress(MoveProgress(phase: .copying, bytesDone: copied, bytesTotal: total, item: name))
            }
            var verified: Int64 = 0
            try VerifiedCopy.verify(entries, hashes: hashes, at: partial, isCancelled: isCancelled) { name, bytes in
                verified += Int64(bytes)
                progress(MoveProgress(phase: .verifying, bytesDone: verified, bytesTotal: total, item: name))
            }
            let restoredPaths = Set(entries.filter { if case .symlink = $0.kind { return false } else { return true } }.map(\.relativePath))
            Self.applyModes(from: Self.modesURL(for: archived), to: partial, allowed: restoredPaths)
            if Self.exists(original) {
                guard Self.isEmptyDirectory(original) else { throw MoveError.alreadyExists(original.path) }
                try Self.removeEmptyDirectory(original)
            }
            try Self.renameExclusive(partial, to: original)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        var updated = record
        updated.restored = true
        if deleteArchive {
            try fm.removeItem(at: archived)
            try? fm.removeItem(at: Self.checksumURL(for: archived))
            try? fm.removeItem(at: Self.modesURL(for: archived))
        }
        try? Journal.save(updated, volume: volume)
        return updated
    }

    // MARK: - Служебное

    /// Независимая сверка двух обходов — TreeWalker и Inspector написаны по-разному.
    /// Если они разошлись, содержимое изменилось с момента проверки или один из обходов что-то пропустил;
    /// удалять оригинал в такой ситуации нельзя.
    static func assertMatches(_ entries: [TreeEntry], _ content: ContentReport, skippedFiles: Int = 0) throws {
        let files = entries.filter(\.isFile).count + skippedFiles
        let directories = entries.filter(\.isDirectory).count
        let symlinks = entries.filter { if case .symlink = $0.kind { return true } else { return false } }.count
        guard files == content.files, directories == content.directories, symlinks == content.symlinkCount else {
            throw MoveError.contentMismatch("проверка насчитала файлов \(content.files), папок \(content.directories), ссылок \(content.symlinkCount), а обход — \(files), \(directories) и \(symlinks)")
        }
    }

    static func exists(_ url: URL) -> Bool {
        // attributesOfItem не переходит по символическим ссылкам.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Настоящая папка (не ссылка), в которой нет ничего, кроме .DS_Store.
    static func isEmptyDirectory(_ url: URL) -> Bool {
        guard (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory,
              let names = try? TreeWalker.listDirectory(url.path) else { return false }
        return names.allSatisfy { $0 == ".DS_Store" }
    }

    /// rmdir не удалит папку, в которой успело что-то появиться.
    static func removeEmptyDirectory(_ url: URL) throws {
        let store = url.appendingPathComponent(".DS_Store")
        if (try? FileManager.default.attributesOfItem(atPath: store.path))?[.type] as? FileAttributeType == .typeRegular {
            try FileManager.default.removeItem(at: store)
        }
        guard rmdir(url.path) == 0 else { throw MoveError.alreadyExists(url.path) }
    }

    static func unique(_ url: URL) -> URL {
        guard exists(url) else { return url }
        let parent = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
        var number = 2
        while true {
            let name = ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"
            let candidate = parent.appendingPathComponent(name)
            if !exists(candidate) { return candidate }
            number += 1
        }
    }

    static func checksumURL(for item: URL) -> URL {
        item.deletingLastPathComponent().appendingPathComponent(item.lastPathComponent + ".sha256")
    }

    static func modesURL(for item: URL) -> URL {
        item.deletingLastPathComponent().appendingPathComponent(item.lastPathComponent + ".modes.json")
    }

    /// exFAT не хранит права доступа, поэтому они сохраняются рядом с архивом и возвращаются при восстановлении.
    static func writeModes(_ entries: [TreeEntry], next item: URL) throws {
        var modes: [String: Int] = [:]
        for entry in entries {
            if case .symlink = entry.kind { continue }
            if let permissions = entry.permissions { modes[entry.relativePath] = permissions }
        }
        let data = try JSONEncoder().encode(modes)
        try data.write(to: modesURL(for: item), options: .withoutOverwriting)
    }

    static func applyModes(from url: URL, to root: URL, allowed: Set<String>) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue < 200 * 1024 * 1024,
              let data = try? Data(contentsOf: url),
              let modes = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        // Сначала файлы, потом каталоги — от глубоких к корню.
        for (relative, mode) in modes.sorted(by: { $0.key.count > $1.key.count }) {
            // Только объекты, которые обход действительно восстановил: путь через подложенную
            // в архив символическую ссылку сюда не попадёт, и права чужого файла не изменятся.
            guard allowed.contains(relative), !relative.contains(".."), !relative.hasPrefix("/") else { continue }
            let target = relative.isEmpty ? root : root.appendingPathComponent(relative)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
                  attributes[.type] as? FileAttributeType != .typeSymbolicLink else { continue }
            // setuid/setgid из непроверенного файла не восстанавливаем.
            try? FileManager.default.setAttributes([.posixPermissions: mode & 0o1777], ofItemAtPath: target.path)
        }
    }

    static func removeSidecar(of url: URL) {
        let sidecar = url.deletingLastPathComponent().appendingPathComponent("._" + url.lastPathComponent)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sidecar.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.int64Value ?? .max) < 1 << 20 else { return }
        try? FileManager.default.removeItem(at: sidecar)
    }

    static func renameExclusive(_ from: URL, to: URL) throws {
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        if code == EEXIST { throw MoveError.alreadyExists(to.path) }
        // exFAT и некоторые другие файловые системы не поддерживают RENAME_EXCL.
        guard code == ENOTSUP || code == EINVAL else { throw CopyError.writeFailed(to.path, String(cString: strerror(code))) }
        guard !exists(to) else { throw MoveError.alreadyExists(to.path) }
        guard rename(from.path, to.path) == 0 else { throw CopyError.writeFailed(to.path, String(cString: strerror(errno))) }
    }
}
