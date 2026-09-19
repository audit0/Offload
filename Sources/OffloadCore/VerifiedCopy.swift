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
            // Данные должны лечь на диск до того, как оригинал будет удалён.
            try output.synchronize()
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
    public static func copyTree(_ entries: [TreeEntry], from source: URL, to destination: URL,
                                keepPermissions: Bool,
                                isCancelled: () -> Bool = { false },
                                progress: (String, Int) -> Void = { _, _ in }) throws -> [String: String] {
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
            if keepPermissions, let permissions = entry.permissions { attributes[.posixPermissions] = permissions }
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
    /// а у каталогов дата изменения (она меняется, когда внутри что-то добавили или удалили).
    public static func assertUnchanged(_ entries: [TreeEntry], at source: URL) throws {
        let fm = FileManager.default
        for entry in entries {
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
                if modified != entry.modified { throw CopyError.changedDuringCopy(name) }
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
