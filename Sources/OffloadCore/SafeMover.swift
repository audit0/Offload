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
    /// Архив лежит внутри сейфа (зашифрован). У старых записей поля нет — значит, открыто.
    public var inSafe: Bool?

    public var isEncrypted: Bool { inSafe == true }

    public init(id: UUID = UUID(), date: Date = Date(), originalPath: String, archivedPath: String, volumeName: String,
                files: Int, bytes: Int64, originalRemoved: Bool = false, restored: Bool = false, note: String? = nil,
                inSafe: Bool? = nil) {
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
        self.inSafe = inSafe
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

/// Итог возврата: сама запись и оговорки, о которых стоит сказать человеку.
public struct RestoreOutcome: Sendable {
    public var record: MoveRecord
    public var notes: [String]
    /// Есть ли среди оговорок настоящее расхождение, а не только строчка «сверено столько-то
    /// из стольких-то», которая бывает всегда. По одному факту наличия оговорок красить
    /// сообщение в предупреждение нельзя: чистый возврат выглядел бы как беда.
    public var needsAttention: Bool

    public init(record: MoveRecord, notes: [String] = [], needsAttention: Bool = false) {
        self.record = record
        self.notes = notes
        self.needsAttention = needsAttention
    }
}

/// Что дала сверка архива со списком сумм, записанным при переносе.
struct StoredChecksumReport {
    var notes: [String] = []
    /// Архив отличается от того, каким его унесли, или сверить его не с чем.
    var hasDifferences = false
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
        // Сама программа: до переименования её процесс звался Offload, теперь — OffLoadAI.
        holders.subtract(["Offload", "OffLoadAI"])
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
        // План мог часами простоять в окне подтверждения, и за это время файлы успели открыть.
        try Self.assertNotOpen(source)
        if deleteOriginal, let reason = Self.undeletableReason(plan.content, source: source) { throw MoveError.blocked(reason) }
        // .DS_Store едет в копию вместе со всем остальным: это разложенные человеком вид окна
        // и положение иконок, а оригинал после переноса удаляется — не скопировав, мы их теряем.
        // От срыва переносов защищают сверки: assertMatches вычитает .DS_Store с обеих сторон,
        // assertUnchanged их не сравнивает.
        let entries = try TreeWalker.walk(source, strict: true, isCancelled: isCancelled).entries
        try Self.assertMatches(entries, plan.content)
        let total = entries.reduce(Int64(0)) { $0 + $1.size }

        let parent = plan.target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // Копия пишется под временным именем: при сбое удаляется только она, чужие файлы не трогаются.
        let partial = parent.appendingPathComponent(".offload-partial-\(UUID().uuidString)")
        Self.removeStalePartials(in: parent, keeping: partial)
        let hashes: [String: String]
        var wroteModes = false
        var wroteChecksums = false
        do {
            var copied: Int64 = 0
            let marker = PartialMarker(partial: partial)
            hashes = try VerifiedCopy.copyTree(entries, from: source, to: partial, keepPermissions: true, isCancelled: isCancelled,
                                               progress: { name, bytes in
                copied += Int64(bytes)
                marker.touch(whileCopying: name)
                progress(MoveProgress(phase: .copying, bytesDone: copied, bytesTotal: total, item: name))
            }, didCreateRoot: { _ in marker.write() })
            var verified: Int64 = 0
            try VerifiedCopy.verify(entries, hashes: hashes, at: partial, isCancelled: isCancelled) { name, bytes in
                verified += Int64(bytes)
                progress(MoveProgress(phase: .verifying, bytesDone: verified, bytesTotal: total, item: name))
            }
            try VerifiedCopy.assertUnchanged(entries, at: source)
            try Self.writeModes(entries, next: plan.target)
            wroteModes = true
            // Список сумм пишется до переименования: иначе сбой записи оставил бы на диске архив,
            // о котором не знает журнал.
            try SafeFile.createExclusive(Self.checksumURL(for: plan.target),
                                         contents: Data(VerifiedCopy.checksumList(hashes, rootName: plan.target.lastPathComponent).utf8))
            wroteChecksums = true
            // Метка снимается до переименования: в архив она попасть не должна.
            marker.remove(restoring: entries.first)
            try Self.renameExclusive(partial, to: plan.target)
            SafeFile.syncDirectory(parent)
        } catch {
            try? fm.removeItem(at: partial)
            Self.removeSidecar(of: partial)
            if wroteModes { try? fm.removeItem(at: Self.modesURL(for: plan.target)) }
            if wroteChecksums { try? fm.removeItem(at: Self.checksumURL(for: plan.target)) }
            throw error
        }
        if plan.volume.createsAppleDouble {
            VerifiedCopy.removeAppleDouble(for: entries, at: plan.target)
            Self.removeSidecar(of: partial)
        }
        let checksums = Self.checksumURL(for: plan.target)
        if plan.volume.createsAppleDouble {
            Self.removeSidecar(of: checksums)
            Self.removeSidecar(of: Self.modesURL(for: plan.target))
        }

        var record = MoveRecord(originalPath: source.path, archivedPath: plan.target.path, volumeName: plan.volume.name,
                                files: hashes.count, bytes: total, inSafe: plan.volume.isEncryptedImage ? true : nil)
        try Journal.save(record, volume: plan.volume)
        if deleteOriginal {
            progress(MoveProgress(phase: .removing, bytesDone: total, bytesTotal: total, item: source.lastPathComponent))
            try VerifiedCopy.assertUnchanged(entries, at: source)
            try Self.assertNotOpen(source)
            if let reason = Self.undeletableReason(Inspector.inspect(source, isCancelled: isCancelled), source: source) {
                throw MoveError.blocked(reason)
            }
            try fm.removeItem(at: source)
            record.originalRemoved = true
            try? Journal.save(record, volume: plan.volume)
        }
        return record
    }

    // MARK: - Зашифровать перенесённое

    /// Переносит архив, который уже лежит на внешнем диске открыто, внутрь сейфа.
    ///
    /// Та же дисциплина, что при переносе с Mac: копия под временным именем, побайтовая
    /// сверка, и только потом открытый архив удаляется. Журнал переписывается до удаления:
    /// оборвись работа на удалении — запись уже указывает на копию в сейфе, и данные
    /// найдутся. Оговорка, которую надо сказать человеку честно: удалённые с флешки или SSD
    /// байты не затираются физически, их можно восстановить специальными средствами,
    /// пока контроллер диска их не перезапишет. Полную гарантию даёт только диск,
    /// зашифрованный целиком.
    public func relocate(_ record: MoveRecord, into safe: VolumeInfo, isCancelled: () -> Bool = { false },
                         progress: (MoveProgress) -> Void = { _ in }) throws -> MoveRecord {
        guard safe.isEncryptedImage else { throw MoveError.unsafeRecord("сейф не открыт") }
        let (archived, _) = try validate(record)
        guard Self.exists(archived) else {
            throw MoveError.unsafeRecord("архив не найден — подключите диск «\(record.volumeName)»")
        }
        let safeRoot = safe.mountPoint.standardizedFileURL.path
        guard let host = Volumes.info(for: archived), host.mountPoint.standardizedFileURL.path != safeRoot,
              !archived.path.hasPrefix(safeRoot + "/") else {
            throw MoveError.unsafeRecord("архив уже в сейфе")
        }
        // Внутри сейфа путь повторяет путь на диске, чтобы по архиву было видно, откуда он.
        let hostRoot = host.mountPoint.standardizedFileURL.path
        let hostOffload = hostRoot + "/" + Self.folderName + "/"
        let relative = archived.path.hasPrefix(hostOffload)
            ? String(archived.path.dropFirst(hostOffload.count))
            : String(archived.path.dropFirst(hostRoot.count + 1))
        let target = safe.mountPoint.appendingPathComponent(Self.folderName, isDirectory: true).appendingPathComponent(relative)
        guard !Self.exists(target) else { throw MoveError.alreadyExists(target.path) }

        let fm = FileManager.default
        progress(MoveProgress(phase: .inspecting, bytesDone: 0, bytesTotal: 0, item: archived.lastPathComponent))
        // Архивом пользуются на месте (папка моделей LM Studio): пока он открыт, переносить нельзя.
        try Self.assertNotOpen(archived, strict: true)
        // ._-двойники, которые macOS наплодила на exFAT, в сейф не везём: на APFS они не нужны.
        // Настоящие файлы человека с такими именами едут как все.
        let stored = Self.storedChecksums(for: archived)
        let all = try TreeWalker.walk(archived, strict: true, isCancelled: isCancelled).entries
        let entries = host.createsAppleDouble
            ? all.filter { !Self.isGeneratedAppleDouble($0, in: archived, listed: stored.hashes) }
            : all
        try Self.assertMatches(entries, Inspector.inspect(archived, isCancelled: isCancelled), skippedFiles: all.count - entries.count)
        let total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total + (64 << 20) <= safe.availableBytes else {
            throw MoveError.destination(["В сейфе не хватает места: нужно \(Format.bytes(total)), свободно \(Format.bytes(safe.availableBytes)). Освободите место на диске «\(host.name)»."])
        }

        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let partial = parent.appendingPathComponent(".offload-partial-\(UUID().uuidString)")
        Self.removeStalePartials(in: parent, keeping: partial)
        do {
            var copied: Int64 = 0
            let marker = PartialMarker(partial: partial)
            let hashes = try VerifiedCopy.copyTree(entries, from: archived, to: partial, keepPermissions: host.keepsPermissions,
                                                   isCancelled: isCancelled, progress: { name, bytes in
                copied += Int64(bytes)
                marker.touch(whileCopying: name)
                progress(MoveProgress(phase: .copying, bytesDone: copied, bytesTotal: total, item: name))
            }, didCreateRoot: { _ in marker.write() })
            var verified: Int64 = 0
            try VerifiedCopy.verify(entries, hashes: hashes, at: partial, isCancelled: isCancelled) { name, bytes in
                verified += Int64(bytes)
                progress(MoveProgress(phase: .verifying, bytesDone: verified, bytesTotal: total, item: name))
            }
            marker.remove(restoring: entries.first)
            try Self.renameExclusive(partial, to: target)
            SafeFile.syncDirectory(parent)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        // Открытый архив удаляется ниже, поэтому он должен быть ровно тем, что скопировано и сверено:
        // если в него писали, пока шло копирование, — копию в сейфе убираем, архив остаётся как был.
        do {
            try VerifiedCopy.assertUnchanged(all, at: archived)
            try Self.assertNotOpen(archived, strict: true)
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
        // Список сумм и права, записанные при переносе, едут вместе с архивом: возврат из сейфа
        // сверится с тем же списком, что и раньше. Только обычные файлы: ссылка на их месте
        // не должна утащить в сейф что-то с Mac.
        for sidecar in [Self.checksumURL(for: archived), Self.modesURL(for: archived)] {
            guard let data = SafeFile.read(sidecar, limit: Self.maxSidecarBytes) else { continue }
            let destination = target.deletingLastPathComponent()
                .appendingPathComponent(target.lastPathComponent + String(sidecar.lastPathComponent.dropFirst(archived.lastPathComponent.count)))
            try? SafeFile.createExclusive(destination, contents: data)
        }

        var moved = record
        moved.archivedPath = target.path
        moved.volumeName = safe.name
        moved.inSafe = true
        try Journal.save(moved, volume: safe)
        try? Journal.remove(record.id, from: host)

        progress(MoveProgress(phase: .removing, bytesDone: total, bytesTotal: total, item: archived.lastPathComponent))
        try fm.removeItem(at: archived)
        for sidecar in [Self.checksumURL(for: archived), Self.modesURL(for: archived)] {
            try? fm.removeItem(at: sidecar)
            Self.removeSidecar(of: sidecar)
        }
        Self.removeSidecar(of: archived)
        return moved
    }

    // MARK: - Ручные переносы

    /// Регистрирует перенос, сделанный без OffLoadAI: папка или файл уже лежит на внешнем диске.
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
        // pathVerdict разворачивает ссылки и в пути, которого ещё нет: без этого подложенная
        // в журнал запись вида «Documents/Фото/old/LaunchAgents/…», где old — ссылка на
        // ~/Library, прошла бы все проверки и записала бы файл в автозапуск.
        if case .blocked(let reason) = rules.pathVerdict(for: original) {
            throw MoveError.unsafeRecord(reason)
        }
        return (archived, original)
    }

    /// Имя метки внутри `.offload-partial-…`: по ней видно, что копирование идёт прямо сейчас.
    static let partialLockName = ".offload-lock"

    /// Метка «здесь работает OffLoadAI», которую кладут внутрь своей partial-папки.
    ///
    /// Раньше «свежесть» остатка определялась по дате самой папки, и это обманывало: пока
    /// копирование идёт в подпапках, дата корня не меняется, а copyTree в конце и вовсе ставит
    /// корню дату оригинала. Соседний экземпляр OffLoadAI мог принять идущее копирование за мусор
    /// и стереть его вместе с уже скопированными данными. Класс, а не структура: на него смотрят
    /// сразу два замыкания copyTree.
    final class PartialMarker {
        private let partial: URL
        /// Имя верхнего уровня, на котором метку обновляли в прошлый раз: одного обновления
        /// на объект верхнего уровня достаточно, чтобы метка не выглядела заброшенной.
        private var lastTop: String?
        private var lastWrite = Date.distantPast

        init(partial: URL) { self.partial = partial }

        private var url: URL { partial.appendingPathComponent(SafeMover.partialLockName) }

        func write() {
            lastWrite = Date()
            try? SafeMover.partialLockText(at: lastWrite).write(to: url, atomically: false, encoding: .utf8)
        }

        /// Один огромный файл может копироваться сутками, и тогда смены имени верхнего уровня
        /// не случится ни разу — поэтому ещё и по времени: метка, которую не трогали сутки,
        /// точно ничья.
        func touch(whileCopying relativePath: String) {
            let top = relativePath.split(separator: "/", maxSplits: 1).first.map(String.init) ?? relativePath
            guard top != lastTop || Date().timeIntervalSince(lastWrite) > 300 else { return }
            lastTop = top
            write()
        }

        /// Снимает метку перед переименованием копии на место. Удаление файла сбивает дату корня,
        /// а права корня к этому моменту уже выставлены по оригиналу и могут запрещать запись,
        /// поэтому и то и другое восстанавливается.
        func remove(restoring root: TreeEntry?) {
            let fm = FileManager.default
            do {
                try fm.removeItem(at: url)
            } catch {
                guard SafeMover.exists(url) else { return }
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: partial.path)
                try? fm.removeItem(at: url)
                if let permissions = root?.permissions {
                    try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: partial.path)
                }
            }
            if let modified = root?.modified {
                try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: partial.path)
            }
        }
    }

    /// Кто копирует и когда в последний раз подавал признаки жизни. Имя машины нужно потому,
    /// что внешний диск носят между компьютерами: чужой pid на этом Mac может оказаться и свободным,
    /// и занятым посторонней программой — верить ему нельзя.
    struct PartialLock {
        var pid: pid_t
        var date: Date
        var host: String
    }

    static let hostIdentifier = ProcessInfo.processInfo.hostName

    static func partialLockText(at date: Date) -> String {
        "\(getpid()) \(date.timeIntervalSince1970) \(hostIdentifier)\n"
    }

    /// Метка внутри остатка; `nil` — метки нет или она не читается.
    static func readPartialLock(in partial: URL) -> PartialLock? {
        let url = partial.appendingPathComponent(partialLockName)
        guard let data = SafeFile.read(url, limit: 4096), let text = String(data: data, encoding: .utf8) else { return nil }
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2)
        guard fields.count >= 2, let pid = pid_t(fields[0]), pid > 0, let seconds = TimeInterval(fields[1]) else { return nil }
        return PartialLock(pid: pid, date: Date(timeIntervalSince1970: seconds),
                           host: fields.count > 2 ? String(fields[2]) : "")
    }

    /// Процесса с таким номером больше нет. EPERM (процесс чужого пользователя) — он жив,
    /// и трогать его работу нельзя.
    static func processIsGone(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return false }
        return errno == ESRCH
    }

    /// За остатком точно никто не стоит.
    ///
    /// Метку наш OffLoadAI обновляет по ходу работы, поэтому «её не трогали сутки» означает, что
    /// копирования нет, кем бы ни был записанный там процесс: так убираются и остатки после
    /// перезагрузки, где номер процесса достался кому-то другому. Свежая метка чужой машины
    /// бережётся до тех же суток: там прямо сейчас может идти копирование.
    static func partialIsAbandoned(_ url: URL, attributes: [FileAttributeKey: Any], age: TimeInterval) -> Bool {
        guard let lock = readPartialLock(in: url) else {
            // Остаток прежней версии OffLoadAI, которая меток не ставила: судим по дате, как раньше.
            guard let modified = attributes[.modificationDate] as? Date else { return false }
            return Date().timeIntervalSince(modified) > age
        }
        if Date().timeIntervalSince(lock.date) > age { return true }
        guard lock.host == hostIdentifier else { return false }
        return processIsGone(lock.pid)
    }

    /// Остатки прерванных операций: если во время копирования выйти из программы или
    /// выдернуть диск, папка `.offload-partial-…` остаётся лежать рядом и место не возвращается.
    /// Свою папку не трогаем никогда — она передаётся в `keeping`.
    static func removeStalePartials(in parent: URL, keeping own: URL? = nil, olderThan age: TimeInterval = 86_400) {
        let fm = FileManager.default
        guard let names = try? TreeWalker.listDirectory(parent.path) else { return }
        for name in names where name.hasPrefix(".offload-partial-") {
            if own?.lastPathComponent == name { continue }
            let url = parent.appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  partialIsAbandoned(url, attributes: attributes, age: age) else { continue }
            try? fm.removeItem(at: url)
        }
    }

    @discardableResult
    public func restore(_ record: MoveRecord, deleteArchive: Bool,
                        isCancelled: () -> Bool = { false },
                        progress: (MoveProgress) -> Void = { _ in }) throws -> RestoreOutcome {
        let (archived, original) = try validate(record)
        // Приложение могло оставить на старом месте пустую папку (так делает LM Studio с папкой моделей) — её можно заменить.
        if Self.exists(original), !Self.isEmptyDirectory(original) { throw MoveError.alreadyExists(original.path) }
        guard let volume = Volumes.info(for: archived), Self.exists(archived) else {
            throw MoveError.unsafeRecord("архив не найден — подключите диск «\(record.volumeName)»")
        }
        // Место с оговорками (скрытые папки программ и т. п.) — туда кладут то, что программа потом
        // читает и исполняет. Такой возврат принимаем, только если перенос сделан на этом Mac:
        // локальный журнал в ~/Library подложить с внешнего диска нельзя.
        if case .caution = rules.pathVerdict(for: original),
           !Journal.localRecords().contains(where: { $0.id == record.id && $0.originalPath == record.originalPath }) {
            throw MoveError.unsafeRecord("«\(original.path)» — место, откуда программы читают настройки и код, а запись об этом переносе есть только в журнале на диске, не на этом Mac. Если архив ваш, скопируйте его вручную.")
        }
        let fm = FileManager.default
        // Служебные ._-двойники, которые macOS сама наплодила рядом с файлами на внешнем диске,
        // обратно не везём. Настоящие файлы человека с именами на «._» — везём: они значатся
        // в списке сумм или не похожи на AppleDouble. А .DS_Store везём: при переносе он уехал
        // в архив вместе с папкой, в нём лежит разложенный человеком вид окна, и возврат должен
        // вернуть папку как была. Сверкам он не мешает: assertUnchanged его игнорирует, а сверка
        // чисел вычитает .DS_Store с обеих сторон.
        let stored = Self.storedChecksums(for: archived)
        let all = try TreeWalker.walk(archived, strict: true, isCancelled: isCancelled).entries
        let entries = volume.createsAppleDouble
            ? all.filter { !Self.isGeneratedAppleDouble($0, in: archived, listed: stored.hashes) }
            : all
        let skippedFiles = all.count - entries.count
        try Self.assertMatches(entries, Inspector.inspect(archived, isCancelled: isCancelled), skippedFiles: skippedFiles)
        let total = entries.reduce(Int64(0)) { $0 + $1.size }

        let parent = original.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let partial = parent.appendingPathComponent(".offload-partial-\(UUID().uuidString)")
        Self.removeStalePartials(in: parent, keeping: partial)
        var notes: [String] = []
        var needsAttention = false
        do {
            var copied: Int64 = 0
            let marker = PartialMarker(partial: partial)
            // setuid и setgid из недоверенного архива не восстанавливаем.
            let hashes = try VerifiedCopy.copyTree(entries, from: archived, to: partial, keepPermissions: volume.keepsPermissions,
                                                   permissionMask: 0o1777,
                                                   isCancelled: isCancelled, progress: { name, bytes in
                copied += Int64(bytes)
                marker.touch(whileCopying: name)
                progress(MoveProgress(phase: .copying, bytesDone: copied, bytesTotal: total, item: name))
            }, didCreateRoot: { _ in marker.write() })
            // Сверка с тем, что было записано при переносе, — только чтобы рассказать человеку,
            // что в архиве изменилось. Отказывать из-за этого нельзя: архив на внешнем диске
            // живёт своей жизнью (с папкой моделей LM Studio так и задумано), и отказ вернуть
            // данные — это потеря доступа к ним.
            let report = Self.checkStoredChecksums(hashes, stored: stored, archive: archived)
            notes += report.notes
            needsAttention = needsAttention || report.hasDifferences
            var verified: Int64 = 0
            try VerifiedCopy.verify(entries, hashes: hashes, at: partial, isCancelled: isCancelled) { name, bytes in
                verified += Int64(bytes)
                progress(MoveProgress(phase: .verifying, bytesDone: verified, bytesTotal: total, item: name))
            }
            let restoredPaths = Set(entries.filter { if case .symlink = $0.kind { return false } else { return true } }.map(\.relativePath))
            let applied = Self.applyModes(from: Self.modesURL(for: archived), to: partial, allowed: restoredPaths)
            if !applied, !volume.keepsPermissions {
                // Настоящих прав взять неоткуда. Ставим самые узкие, при которых всё работает:
                // приватные ключи, .env и базы паролей не должны вернуться читаемыми всем на машине.
                Self.normalizeModes(entries, at: partial)
                notes.append("Диск «\(volume.name)» (\(volume.fsDisplayName)) не хранит права доступа, а списка прав рядом с архивом нет. Права выставлены только для вас: папки 700, файлы 600, исполняемые 700.")
                needsAttention = true
            }
            marker.remove(restoring: entries.first)
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
            // Данные уже на Mac и сверены. Неудача с удалением архива — повод сказать об этом,
            // а не объявить весь возврат провалившимся.
            do {
                // Удаляется ровно то, что вернулось: если в архив писали, пока шёл возврат,
                // или его держит программа — архив остаётся.
                do {
                    try VerifiedCopy.assertUnchanged(all, at: archived)
                } catch {
                    throw MoveError.blocked("пока шёл возврат, в архиве что-то изменилось, и вернулось не всё новое.")
                }
                try Self.assertNotOpen(archived, strict: true)
                try fm.removeItem(at: archived)
                try? fm.removeItem(at: Self.checksumURL(for: archived))
                try? fm.removeItem(at: Self.modesURL(for: archived))
            } catch {
                notes.append("Данные вернулись на Mac и сверены, а архив удалить не удалось: \(error.localizedDescription) Он остался в «\(archived.path)» — удалите его сами, когда будет удобно.")
                needsAttention = true
            }
        }
        try? Journal.save(updated, volume: volume)
        return RestoreOutcome(record: updated, notes: notes, needsAttention: needsAttention)
    }

    /// Сверяет посчитанное при чтении архива с файлом `<архив>.sha256`, записанным при переносе,
    /// и рассказывает человеку, чем архив отличается от того, каким его унесли.
    ///
    /// Только оговорки, никаких отказов. Программа сама советует переносить то, чему можно указать
    /// новый путь (папка моделей LM Studio), человек продолжает работать с файлами прямо на внешнем
    /// диске — и они законно меняются. Отказ вернуть такой перенос означал бы, что данные к человеку
    /// уже не вернутся никогда. Возвращаемая копия сверена побайтово с тем, что лежит в архиве
    /// сейчас (VerifiedCopy.verify), поэтому потери данных здесь нет.
    ///
    /// Сверка идёт по множествам путей в обе стороны: одного прохода по посчитанным хешам мало —
    /// подложенный в архив файл в списке не значится, и раньше он молча объявлялся «сверенным».
    static func checkStoredChecksums(_ hashes: [String: String], stored list: StoredChecksums, archive: URL) -> StoredChecksumReport {
        // «._»-файлы больше не отбрасываются: служебные двойники в возврат не попадают вовсе,
        // а настоящие файлы с такими именами должны сверяться, как все.
        func isFinderJunk(_ path: String) -> Bool { (path as NSString).lastPathComponent == ".DS_Store" }
        func name(_ path: String) -> String { path.isEmpty ? archive.lastPathComponent : path }
        func listing(_ paths: [String], _ limit: Int) -> String { paths.prefix(limit).map(name).joined(separator: ", ") }

        let present = Set(hashes.keys).filter { !isFinderJunk($0) }
        let stored: [String: String]
        switch list {
        case .missing:
            return StoredChecksumReport(notes: ["Рядом с архивом нет списка контрольных сумм, записанного при переносе, — сверить архив с его прежним состоянием не с чем. Все \(present.count) файлов сверены с тем, что лежит на диске сейчас, и вернулись такими."],
                                        hasDifferences: true)
        case .unreadable:
            return StoredChecksumReport(notes: ["Список контрольных сумм рядом с архивом не читается — сверить архив с его прежним состоянием не с чем. Все \(present.count) файлов сверены с тем, что лежит на диске сейчас, и вернулись такими."],
                                        hasDifferences: true)
        case .list(let hashes):
            stored = hashes
        }
        let expected = Set(stored.keys).filter { !isFinderJunk($0) }
        let common = present.intersection(expected)
        let changed = common.filter { stored[$0] != hashes[$0] }.sorted()
        let extra = present.subtracting(expected).sorted()
        let missing = expected.subtracting(present).sorted()

        var report = StoredChecksumReport()
        // Первым делом — главное: сверено со списком переноса столько-то из стольких-то.
        // Иначе интерфейс скажет «каждый файл сверен» и про изменившиеся файлы там, где это неправда.
        report.notes.append("Со списком, записанным при переносе, сверено \(common.count - changed.count) файлов из \(present.count) в архиве.")
        if !changed.isEmpty {
            report.notes.append("С момента переноса на диске изменилось файлов: \(changed.count) (\(listing(changed, 5))). Вернулось то, что лежит в архиве сейчас, — оно сверено побайтово.")
        }
        if !extra.isEmpty {
            report.notes.append("В архиве появилось \(extra.count) файлов, которых при переносе не было (\(listing(extra, 5))). Они тоже вернулись, но сверить их не с чем — откуда они, программа не знает.")
        }
        if !missing.isEmpty {
            report.notes.append("В архиве не хватает \(missing.count) файлов из списка, записанного при переносе (\(listing(missing, 3))). Остальное сверено и возвращено.")
        }
        report.hasDifferences = !changed.isEmpty || !extra.isEmpty || !missing.isEmpty
        return report
    }

    /// Права, когда взять настоящие неоткуда: exFAT их не хранит, а `.modes.json`
    /// пишет только сам OffLoadAI — у переносов, добавленных вручную, его нет.
    ///
    /// Права только для владельца. 0644 и 0755 вернули бы приватные ключи, .env и базы паролей
    /// читаемыми всем на машине, а угадать чужие права нельзя — можно только не расширять свои.
    /// Бит выполнения ставится не всем подряд (от этого ломались скрипты и программы внутри .app,
    /// когда всё возвращалось с 0600), а тем, кого удаётся распознать по первым байтам.
    static func normalizeModes(_ entries: [TreeEntry], at root: URL) {
        let fm = FileManager.default
        for entry in entries {
            let target = entry.relativePath.isEmpty ? root : root.appendingPathComponent(entry.relativePath)
            switch entry.kind {
            case .symlink:
                continue
            case .directory:
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
            case .file:
                let executable = Self.looksExecutable(target)
                try? fm.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: target.path)
            }
        }
    }

    /// Скрипт с «#!» или программа Mach-O. Бит выполнения с exFAT не приходит,
    /// поэтому исполняемые файлы узнаются по первым байтам.
    static func looksExecutable(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = (try? handle.read(upToCount: 4)) ?? nil, data.count == 4 else { return false }
        if data[0] == 0x23, data[1] == 0x21 { return true }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return [0xfeed_face, 0xfeed_facf, 0xcafe_babe, 0xcffa_edfe, 0xcefa_edfe, 0xbeba_feca].contains(magic)
    }

    // MARK: - Служебное

    /// Независимая сверка двух обходов — TreeWalker и Inspector написаны по-разному.
    /// Если они разошлись, содержимое изменилось с момента проверки или один из обходов что-то пропустил;
    /// удалять оригинал в такой ситуации нельзя.
    ///
    /// .DS_Store вычитается с обеих сторон: Finder заводит и стирает их, пока человек просто смотрит
    /// в папку, и такой пустяк не должен обрывать перенос. Всё остальное, что появилось между
    /// проверкой и обходом, по-прежнему его останавливает.
    static func assertMatches(_ entries: [TreeEntry], _ content: ContentReport, skippedFiles: Int = 0) throws {
        let walkedStores = entries.filter { $0.isFile && ($0.relativePath as NSString).lastPathComponent == ".DS_Store" }.count
        let files = entries.filter(\.isFile).count - walkedStores + skippedFiles
        let expectedFiles = content.files - content.dsStoreFiles
        let directories = entries.filter(\.isDirectory).count
        let symlinks = entries.filter { if case .symlink = $0.kind { return true } else { return false } }.count
        guard files == expectedFiles, directories == content.directories, symlinks == content.symlinkCount else {
            throw MoveError.contentMismatch("проверка насчитала файлов \(expectedFiles), папок \(content.directories), ссылок \(content.symlinkCount), а обход — \(files), \(directories) и \(symlinks)")
        }
    }

    static func exists(_ url: URL) -> Bool {
        // attributesOfItem не переходит по символическим ссылкам.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Почему оригинал нельзя удалить целиком — или `nil`. removeItem останавливается на первой папке
    /// без права записи и оставляет оригинал удалённым наполовину, а возврат потом отказывает:
    /// «уже существует». Поэтому проверяем до того, как удалить хоть что-то.
    static func undeletableReason(_ content: ContentReport, source: URL) -> String? {
        let parent = source.deletingLastPathComponent()
        if access(parent.path, W_OK | X_OK) != 0 {
            return "Оригинал не удалить: нет права записи в «\(parent.lastPathComponent)». Копия на диске цела, оригинал не тронут."
        }
        guard content.undeletable > 0 else { return nil }
        return "Оригинал не удалить целиком: внутри папки только для чтения или защищённые файлы (\(content.undeletableExamples.prefix(3).joined(separator: ", "))). Ничего не удалено; перенесите без удаления оригинала или снимите защиту."
    }

    /// Предел для служебных файлов рядом с архивом: они лежат на недоверенном диске.
    static let maxSidecarBytes = 200 * 1024 * 1024

    /// Список сумм, записанный при переносе рядом с архивом.
    enum StoredChecksums {
        case missing
        case unreadable
        case list([String: String])

        var hashes: [String: String]? {
            if case .list(let hashes) = self { return hashes }
            return nil
        }
    }

    static func storedChecksums(for archive: URL) -> StoredChecksums {
        let url = checksumURL(for: archive)
        guard exists(url) else { return .missing }
        guard let data = SafeFile.read(url, limit: maxSidecarBytes), let text = String(data: data, encoding: .utf8),
              let hashes = VerifiedCopy.parseChecksumList(text, rootName: archive.lastPathComponent) else { return .unreadable }
        return .list(hashes)
    }

    /// Служебный ._-двойник, который macOS сама кладёт рядом с файлом на exFAT и других дисках
    /// без расширенных атрибутов. Признаков три, и нужны все: рядом лежит файл, к которому он
    /// относится; его нет в списке сумм, записанном при переносе (файл человека, уехавший в архив,
    /// там есть); и он начинается с сигнатуры AppleDouble. Раньше хватало одного соседа — и настоящий
    /// файл «._photo.jpg» рядом с «photo.jpg» не возвращался, а потом удалялся вместе с архивом.
    static func isGeneratedAppleDouble(_ entry: TreeEntry, in root: URL, listed: [String: String]?) -> Bool {
        let name = (entry.relativePath as NSString).lastPathComponent
        guard entry.isFile, name.hasPrefix("._"), name.count > 2, listed?[entry.relativePath] == nil else { return false }
        let sibling = ((entry.relativePath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(String(name.dropFirst(2)))
        guard exists(root.appendingPathComponent(sibling)) else { return false }
        return hasAppleDoubleMagic(root.appendingPathComponent(entry.relativePath))
    }

    static func hasAppleDoubleMagic(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var magic = [UInt8](repeating: 0, count: 4)
        guard Darwin.read(descriptor, &magic, 4) == 4 else { return false }
        return magic == [0x00, 0x05, 0x16, 0x07]
    }

    /// Файлы держит другая программа — удалять и копировать их нельзя.
    /// - Parameter strict: `true` — если проверить не удалось, тоже отказ. Иначе неудачная
    ///   проверка пропускается: о ней уже предупредили в плане, и человек подтвердил.
    static func assertNotOpen(_ url: URL, strict: Bool = false) throws {
        guard let holders = openFiles(in: url) else {
            if strict { throw MoveError.blocked("Не удалось проверить, открыты ли файлы «\(url.lastPathComponent)» в других программах. Повторите чуть позже.") }
            return
        }
        guard holders.isEmpty else {
            throw MoveError.blocked("Файлы сейчас открыты: \(holders.prefix(3).joined(separator: ", ")). Закройте приложение и повторите.")
        }
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

    /// Свободное имя — и для самого архива, и для его спутников: оставшийся от удалённого архива
    /// «.modes.json» иначе срывал бы каждый следующий перенос, а подложенный «.sha256» принимал бы запись.
    static func unique(_ url: URL) -> URL {
        func isFree(_ candidate: URL) -> Bool {
            !exists(candidate) && !exists(checksumURL(for: candidate)) && !exists(modesURL(for: candidate))
        }
        guard !isFree(url) else { return url }
        let parent = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
        var number = 2
        while true {
            let name = ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"
            let candidate = parent.appendingPathComponent(name)
            if isFree(candidate) { return candidate }
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

    /// `false` — списка прав рядом с архивом нет или он не читается.
    @discardableResult
    static func applyModes(from url: URL, to root: URL, allowed: Set<String>) -> Bool {
        guard let data = SafeFile.read(url, limit: maxSidecarBytes),
              let modes = try? JSONDecoder().decode([String: Int].self, from: data) else { return false }
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
        return true
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
