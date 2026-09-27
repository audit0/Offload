import CryptoKit
import Darwin
import Foundation

/// Один объект дерева, снятый при обходе.
public struct TreeEntry: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case directory
        case file
        case symlink(target: String)
    }

    /// Путь относительно корня; пустая строка — сам корень.
    public let relativePath: String
    public let kind: Kind
    public let size: Int64
    public let modified: Date?
    public let permissions: Int?

    public var isDirectory: Bool { kind == .directory }
    public var isFile: Bool { kind == .file }
}

public enum CopyError: LocalizedError, Equatable {
    case unreadable(String)
    case destinationExists(String)
    case writeFailed(String, String)
    case verificationFailed(String)
    case changedDuringCopy(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "Не удалось прочитать «\(path)»."
        case .destinationExists(let path): return "На диске назначения уже есть «\(path)» — перезаписывать не буду."
        case .writeFailed(let path, let reason): return "Не удалось записать «\(path)»: \(reason)"
        case .verificationFailed(let path): return "Копия «\(path)» не совпала с оригиналом."
        case .changedDuringCopy(let path): return "«\(path)» изменился во время переноса — оригинал не тронут."
        }
    }
}

public enum TreeWalker {
    /// Обходит дерево, не переходя по символическим ссылкам.
    /// - Parameters:
    ///   - strict: любая ошибка чтения прерывает обход; иначе ошибки собираются в `problems`.
    ///   - exclude: относительный путь и признак каталога; `true` — пропустить вместе с содержимым.
    public static func walk(_ root: URL, strict: Bool,
                            exclude: (String, Bool) -> Bool = { _, _ in false },
                            isCancelled: () -> Bool = { false }) throws -> (entries: [TreeEntry], problems: [String]) {
        let fm = FileManager.default
        let rootPath = root.path
        var entries: [TreeEntry] = []
        var problems: [String] = []

        func entry(at path: String, relative: String) throws -> TreeEntry? {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fm.attributesOfItem(atPath: path)
            } catch {
                if strict { throw CopyError.unreadable(relative.isEmpty ? root.lastPathComponent : relative) }
                problems.append(relative)
                return nil
            }
            let modified = attributes[.modificationDate] as? Date
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory?:
                return TreeEntry(relativePath: relative, kind: .directory, size: 0, modified: modified, permissions: permissions)
            case .typeRegular?:
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                return TreeEntry(relativePath: relative, kind: .file, size: size, modified: modified, permissions: permissions)
            case .typeSymbolicLink?:
                let target = try fm.destinationOfSymbolicLink(atPath: path)
                return TreeEntry(relativePath: relative, kind: .symlink(target: target), size: 0, modified: modified, permissions: permissions)
            default:
                // Сокеты, FIFO и устройства не копируются.
                if strict { throw CopyError.unreadable("\(relative) (особый файл)") }
                problems.append("\(relative) (особый файл пропущен)")
                return nil
            }
        }

        guard let rootEntry = try entry(at: rootPath, relative: "") else { return ([], problems) }
        entries.append(rootEntry)
        guard rootEntry.isDirectory else { return (entries, problems) }

        // Свой обход через readdir: FileManager.enumerator молча скрывает файлы с именами на «._»,
        // и они не попали бы в копию, а потом исчезли бы вместе с оригиналом.
        var pending = [""]
        while let directory = pending.popLast() {
            if isCancelled() { throw CancellationError() }
            let names: [String]
            do {
                names = try listDirectory(directory.isEmpty ? rootPath : rootPath + "/" + directory)
            } catch {
                let label = directory.isEmpty ? root.lastPathComponent : directory
                if strict { throw CopyError.unreadable(label) }
                problems.append(label)
                continue
            }
            for name in names.sorted() {
                let relative = directory.isEmpty ? name : directory + "/" + name
                guard let item = try entry(at: rootPath + "/" + relative, relative: relative) else { continue }
                if exclude(relative, item.isDirectory) { continue }
                entries.append(item)
                if item.isDirectory { pending.append(relative) }
            }
        }
        return (entries, problems)
    }

    /// Имена в каталоге без «.» и «..», ничего не скрывая.
    static func listDirectory(_ path: String) throws -> [String] {
        guard let directory = opendir(path) else {
            let code = errno
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let item = readdir(directory) {
            let length = Int(item.pointee.d_namlen)
            let name = withUnsafeBytes(of: item.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }
}

/// Копирование, при котором оригинал удаляется только после побайтовой сверки копии.
public enum VerifiedCopy {
    public static let chunkSize = 4 * 1024 * 1024

    /// Копирует данные файла без расширенных атрибутов и возвращает SHA-256 прочитанных байтов.
    ///
    /// Файл назначения открывается с `O_EXCL | O_NOFOLLOW`: существующий файл
    /// или подложенная символическая ссылка не будут перезаписаны.
    public static func copyFile(from source: URL, to destination: URL,
                                isCancelled: () -> Bool = { false },
                                progress: (Int) -> Void = { _ in }) throws -> String {
        // O_NOFOLLOW: если после обхода файл подменят символической ссылкой, чтение не уйдёт по ней.
        let sourceDescriptor = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else { throw CopyError.unreadable(source.path) }
        let input = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
        defer { try? input.close() }

        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            let code = errno
            if code == EEXIST { throw CopyError.destinationExists(destination.path) }
            throw CopyError.writeFailed(destination.path, String(cString: strerror(code)))
        }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        // Записанное не оседает в кеше: сверка потом перечитывает копию с носителя, а не из памяти,
        // где она совпала бы с оригиналом, даже если на диск легло не то.
        _ = fcntl(descriptor, F_NOCACHE, 1)
        var hasher = SHA256()
        do {
            while true {
                if isCancelled() { throw CancellationError() }
                let count: Int = try autoreleasepool {
                    guard let data = try input.read(upToCount: chunkSize), !data.isEmpty else { return 0 }
                    hasher.update(data: data)
                    try output.write(contentsOf: data)
                    return data.count
                }
                if count == 0 { break }
                progress(count)
            }
            // Данные должны лечь на диск до того, как оригинал будет удалён. fsync на macOS
            // оставляет их в кеше самого накопителя — выдерни флешку, и они пропадут; нужен F_FULLFSYNC.
            try SafeFile.fullSync(descriptor, path: destination.path)
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return FileHasher.hex(hasher.finalize())
    }

    static func url(_ base: URL, _ entry: TreeEntry) -> URL {
        entry.relativePath.isEmpty ? base : base.appendingPathComponent(entry.relativePath)
    }

    static func displayName(_ base: URL, _ entry: TreeEntry) -> String {
        entry.relativePath.isEmpty ? base.lastPathComponent : entry.relativePath
    }

    /// Создаёт копию дерева в `destination` (его ещё не должно существовать).
    /// Возвращает SHA-256 исходных байтов каждого файла.
    /// - Parameter didCreateRoot: вызывается сразу после создания корневой папки копии и до того,
    ///   как в неё что-то записано. Через него кладётся метка «здесь идёт копирование»: без неё
    ///   соседний экземпляр Offload видит только имя `.offload-partial-…` и дату, которая по ходу
    ///   работы не меняется.
    /// - Parameter permissionMask: какие биты прав переносить. При возврате из недоверенного архива
    ///   setuid и setgid отбрасываются.
    public static func copyTree(_ entries: [TreeEntry], from source: URL, to destination: URL,
                                keepPermissions: Bool, permissionMask: Int = 0o7777,
                                isCancelled: () -> Bool = { false },
                                progress: (String, Int) -> Void = { _, _ in },
                                didCreateRoot: (URL) -> Void = { _ in }) throws -> [String: String] {
        let fm = FileManager.default
        var hashes: [String: String] = [:]
        for entry in entries {
            if isCancelled() { throw CancellationError() }
            let target = url(destination, entry)
            switch entry.kind {
            case .directory:
                do { try fm.createDirectory(at: target, withIntermediateDirectories: false) } catch {
                    throw CopyError.writeFailed(target.path, error.localizedDescription)
                }
                if entry.relativePath.isEmpty { didCreateRoot(destination) }
            case .file:
                hashes[entry.relativePath] = try copyFile(from: url(source, entry), to: target, isCancelled: isCancelled,
                                                          progress: { progress(entry.relativePath, $0) })
            case .symlink(let linkTarget):
                do { try fm.createSymbolicLink(atPath: target.path, withDestinationPath: linkTarget) } catch {
                    throw CopyError.writeFailed(target.path, "символическая ссылка не создана: \(error.localizedDescription)")
                }
            }
        }
        // Метаданные — в обратном порядке, чтобы права каталогов не мешали записи внутрь.
        for entry in entries.reversed() {
            if case .symlink = entry.kind { continue }
            var attributes: [FileAttributeKey: Any] = [:]
            if let modified = entry.modified { attributes[.modificationDate] = modified }
            if keepPermissions, let permissions = entry.permissions { attributes[.posixPermissions] = permissions & permissionMask }
            try? fm.setAttributes(attributes, ofItemAtPath: url(destination, entry).path)
        }
        return hashes
    }

    /// Перечитывает копию с диска и сравнивает с хешами оригинала.
    public static func verify(_ entries: [TreeEntry], hashes: [String: String], at destination: URL,
                              isCancelled: () -> Bool = { false },
                              progress: (String, Int) -> Void = { _, _ in }) throws {
        let fm = FileManager.default
        for entry in entries {
            if isCancelled() { throw CancellationError() }
            let target = url(destination, entry)
            let name = displayName(destination, entry)
            switch entry.kind {
            case .directory:
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw CopyError.verificationFailed(name)
                }
            case .file:
                let size = ((try? fm.attributesOfItem(atPath: target.path))?[.size] as? NSNumber)?.int64Value
                guard size == entry.size, let expected = hashes[entry.relativePath] else { throw CopyError.verificationFailed(name) }
                let actual = try FileHasher.sha256(of: target, isCancelled: isCancelled, progress: { progress(entry.relativePath, $0) })
                guard actual == expected else { throw CopyError.verificationFailed(name) }
            case .symlink(let linkTarget):
                guard (try? fm.destinationOfSymbolicLink(atPath: target.path)) == linkTarget else {
                    throw CopyError.verificationFailed(name)
                }
            }
        }
    }

    /// Проверяет, что источник не менялся с момента обхода: размеры и даты файлов,
    /// а у каталогов — их состав.
    ///
    /// Дату каталога сверять нельзя: Finder меняет её, просто записав рядом свой `.DS_Store`
    /// (достаточно открыть папку и поменять вид окна). Раньше такой пустяк обрывал
    /// многочасовой перенос и выбрасывал уже проверенную копию, поэтому у каталога
    /// при изменившейся дате перечитывается список имён — важно только это.
    /// - Parameter ignoring: имена, появление, исчезновение и изменение которых изменением не считается.
    public static func assertUnchanged(_ entries: [TreeEntry], at source: URL, ignoring: Set<String> = [".DS_Store"]) throws {
        let fm = FileManager.default
        var children: [String: Set<String>] = [:]
        for entry in entries where !entry.relativePath.isEmpty {
            let parent = (entry.relativePath as NSString).deletingLastPathComponent
            children[parent, default: []].insert((entry.relativePath as NSString).lastPathComponent)
        }
        for entry in entries {
            // Сам .DS_Store теперь едет в копию, но сверять его нельзя: Finder переписывает его,
            // стоит человеку изменить вид окна, и многочасовой перенос обрывался бы ради того,
            // чтобы вместе с данными доехало точное положение иконок.
            if !entry.relativePath.isEmpty, ignoring.contains((entry.relativePath as NSString).lastPathComponent) { continue }
            let name = displayName(source, entry)
            guard let attributes = try? fm.attributesOfItem(atPath: url(source, entry).path) else {
                throw CopyError.changedDuringCopy(name)
            }
            let modified = attributes[.modificationDate] as? Date
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            switch entry.kind {
            case .file:
                if size != entry.size || modified != entry.modified { throw CopyError.changedDuringCopy(name) }
            case .directory:
                if modified != entry.modified {
                    guard let names = try? TreeWalker.listDirectory(url(source, entry).path),
                          Set(names).subtracting(ignoring) == (children[entry.relativePath] ?? []).subtracting(ignoring) else {
                        throw CopyError.changedDuringCopy(name)
                    }
                }
            case .symlink(let target):
                if (try? fm.destinationOfSymbolicLink(atPath: url(source, entry).path)) != target { throw CopyError.changedDuringCopy(name) }
            }
        }
    }

    /// Удаляет служебные файлы ._*, которые macOS создала рядом со скопированными объектами.
    /// Настоящие файлы с именами на ._ из самого источника не трогаются.
    public static func removeAppleDouble(for entries: [TreeEntry], at destination: URL) {
        let fm = FileManager.default
        let own = Set(entries.map(\.relativePath))
        for entry in entries {
            let item = url(destination, entry)
            let sidecar = item.deletingLastPathComponent().appendingPathComponent("._" + item.lastPathComponent)
            let sidecarRelative = entry.relativePath.isEmpty
                ? nil
                : ((entry.relativePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("._" + item.lastPathComponent)
            if let sidecarRelative, own.contains(sidecarRelative) { continue }
            guard let attributes = try? fm.attributesOfItem(atPath: sidecar.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.int64Value ?? .max) < 1 << 20 else { continue }
            try? fm.removeItem(at: sidecar)
        }
    }

    /// Разбирает список, записанный `checksumList`. `nil` — файл не в том формате.
    public static func parseChecksumList(_ text: String, rootName: String) -> [String: String]? {
        var hashes: [String: String] = [:]
        for line in text.split(separator: "\n") {
            var body = Substring(line)
            let escaped = body.hasPrefix("\\")
            if escaped { body = body.dropFirst() }
            guard let separator = body.range(of: "  ") else { return nil }
            let hash = String(body[body.startIndex..<separator.lowerBound])
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
            var path = String(body[separator.upperBound...])
            if escaped { path = unescape(path) }
            if path == rootName {
                hashes[""] = hash
            } else if path.hasPrefix(rootName + "/") {
                hashes[String(path.dropFirst(rootName.count + 1))] = hash
            } else {
                return nil
            }
        }
        return hashes
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                result.append(character)
                continue
            }
            result.append(next == "n" ? "\n" : next)
        }
        return result
    }

    /// Список в формате `shasum -a 256 -c`: пути относительно папки, где лежит перенесённый объект.
    public static func checksumList(_ hashes: [String: String], rootName: String) -> String {
        hashes.keys.sorted().map { relative -> String in
            let path = relative.isEmpty ? rootName : rootName + "/" + relative
            let hash = hashes[relative] ?? ""
            if path.contains("\\") || path.contains("\n") {
                let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
                return "\\\(hash)  \(escaped)"
            }
            return "\(hash)  \(path)"
        }.joined(separator: "\n") + "\n"
    }
}

/// Служебные файлы рядом с архивом лежат на недоверенном диске: на месте любого из них может
/// оказаться символическая ссылка на файл с Mac, FIFO или /dev/zero.
enum SafeFile {
    /// Содержимое обычного файла не больше `limit` байт. Ссылка, FIFO, устройство или файл
    /// больше предела — `nil`. O_NONBLOCK — чтобы FIFO не подвесил открытие.
    static func read(_ url: URL, limit: Int) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { return nil }
        guard let data = try? handle.read(upToCount: limit + 1) else { return nil }
        let result = data ?? Data()
        return result.count <= limit ? result : nil
    }

    /// Создаёт новый файл: существующий файл или подложенная на его месте ссылка — ошибка, а не перезапись.
    static func createExclusive(_ url: URL, contents: Data, mode: mode_t = 0o644) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard descriptor >= 0 else {
            let code = errno
            if code == EEXIST { throw CopyError.destinationExists(url.path) }
            throw CopyError.writeFailed(url.path, String(cString: strerror(code)))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: contents)
            try fullSync(descriptor, path: url.path)
            try handle.close()
        } catch {
            try? handle.close()
            unlink(url.path)
            throw error
        }
    }

    /// Сбросить файл на носитель, минуя кеш накопителя. Файловые системы без F_FULLFSYNC
    /// (сетевые, часть сторонних) получают обычный fsync.
    static func fullSync(_ descriptor: Int32, path: String) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else { throw CopyError.writeFailed(path, String(cString: strerror(errno))) }
    }

    /// Переименование — запись в каталоге; без сброса каталога после выдернутого диска копия
    /// может остаться под временным именем или пропасть, хотя оригинал уже удалён.
    static func syncDirectory(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        try? fullSync(descriptor, path: url.path)
    }
}
