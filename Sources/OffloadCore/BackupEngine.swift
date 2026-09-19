import Darwin
import Foundation

public struct BackupReport: Sendable {
    public var copied = 0
    public var unchanged = 0
    public var bytesCopied: Int64 = 0
    /// Файлы с ключами и токенами, пропущенные в открытом бэкапе.
    public var secretsSkipped: [String] = []
    public var problems: [String] = []

    public init() {}
}

public enum BackupError: LocalizedError, Equatable {
    case destinationInsideSource(String)

    public var errorDescription: String? {
        switch self {
        case .destinationInsideSource(let path): return "Папка бэкапа не может лежать внутри копируемой папки «\(path)»."
        }
    }
}

/// Обновляемый бэкап: копируются только новые и изменившиеся файлы, каждый сверяется по SHA-256.
/// Из бэкапа ничего не удаляется — удалённые на Mac файлы остаются в копии.
public enum BackupEngine {
    /// Папки, которые восстанавливаются одной командой (npm install, pip install, сборка).
    public static let defaultExcludedNames: Set<String> = [
        "node_modules", ".venv", "venv", "__pycache__", ".next", ".nuxt", "dist", "build", ".build", "target",
        ".turbo", ".cache", ".parcel-cache", "DerivedData", "Pods", ".gradle", ".DS_Store",
    ]

    static let secretExtensions: Set<String> = ["pem", "key", "p12", "pfx", "keystore", "jks", "kdbx", "ppk", "p8", "asc", "gpg", "ovpn"]
    static let secretNames: Set<String> = [
        ".npmrc", ".pypirc", ".netrc", ".git-credentials", ".envrc", ".pgpass", ".my.cnf",
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "id_ed25519_sk", "credentials",
    ]
    /// Каталоги, которые целиком состоят из ключей и учёток. Проверять только имена файлов мало:
    /// в ~/.aws лежит credentials без расширения, в .gnupg — связка ключей.
    static let secretFolders: Set<String> = [".ssh", ".gnupg", ".aws", ".kube", ".azure", ".gcloud"]
    static let templateSuffixes = [".example", ".sample", ".template", ".dist"]

    /// Файлы с ключами и токенами: в открытый бэкап не попадают, только в шифрованный контейнер.
    public static func isSecret(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == ".env" || lower.hasPrefix(".env.") {
            return !templateSuffixes.contains(where: { lower.hasSuffix($0) })
        }
        if secretNames.contains(lower) { return true }
        return secretExtensions.contains((lower as NSString).pathExtension)
    }

    public static func isSecretFolder(_ name: String) -> Bool { secretFolders.contains(name.lowercased()) }

    /// Секрет ли объект по пути относительно корня бэкапа: по каталогу, по имени,
    /// а у файлов без расширения — по первым байтам («-----BEGIN … PRIVATE KEY»).
    /// Ключ с именем вроде `deploy_key` иначе уехал бы в открытый бэкап.
    public static func isSecretPath(_ relative: String, in root: URL) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        if parts.dropLast().contains(where: isSecretFolder) { return true }
        guard let name = parts.last else { return false }
        if isSecret(name) { return true }
        guard (name as NSString).pathExtension.isEmpty, !name.hasPrefix(".") else { return false }
        return looksLikePrivateKey(root.appendingPathComponent(relative))
    }

    static func looksLikePrivateKey(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              ((attributes[.size] as? NSNumber)?.int64Value ?? .max) < 64 * 1024,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = (try? handle.read(upToCount: 128)) ?? nil else { return false }
        return String(decoding: data, as: UTF8.self).contains("PRIVATE KEY")
    }

    public static func run(sources: [URL], destination: URL, excludedNames: Set<String> = defaultExcludedNames,
                           isCancelled: () -> Bool = { false },
                           progress: (String, Int64) -> Void = { _, _ in }) throws -> BackupReport {
        var report = BackupReport()
        let fm = FileManager.default
        let destinationPath = destination.standardizedFileURL.path
        for source in sources {
            let sourcePath = source.standardizedFileURL.path
            if destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/") {
                throw BackupError.destinationInsideSource(source.path)
            }
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let cleanAppleDouble = Volumes.info(for: destination)?.createsAppleDouble ?? false

        for source in sources {
            guard fm.fileExists(atPath: source.path) else {
                report.problems.append("Нет папки: \(source.path)")
                continue
            }
            let rootName = source.lastPathComponent
            let target = destination.appendingPathComponent(rootName, isDirectory: true)
            let walk = try TreeWalker.walk(source, strict: false, exclude: { relative, isDirectory in
                let name = (relative as NSString).lastPathComponent
                if excludedNames.contains(name) { return true }
                if isDirectory {
                    guard isSecretFolder(name) else { return false }
                    report.secretsSkipped.append(rootName + "/" + relative + "/")
                    return true
                }
                if isSecretPath(relative, in: source) {
                    report.secretsSkipped.append(rootName + "/" + relative)
                    return true
                }
                return false
            }, isCancelled: isCancelled)
            report.problems += walk.problems.map { "\(rootName)/\($0): нет доступа" }

            for entry in walk.entries {
                if isCancelled() { throw CancellationError() }
                let from = entry.relativePath.isEmpty ? source : source.appendingPathComponent(entry.relativePath)
                let to = entry.relativePath.isEmpty ? target : target.appendingPathComponent(entry.relativePath)
                let label = entry.relativePath.isEmpty ? rootName : rootName + "/" + entry.relativePath
                do {
                    switch entry.kind {
                    case .directory:
                        try ensureDirectory(to)
                    case .symlink(let linkTarget):
                        if (try? fm.destinationOfSymbolicLink(atPath: to.path)) == linkTarget {
                            report.unchanged += 1
                            continue
                        }
                        if let attributes = try? fm.attributesOfItem(atPath: to.path) {
                            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
                                throw CopyError.destinationExists(to.path)
                            }
                            try fm.removeItem(at: to)
                        }
                        try fm.createSymbolicLink(atPath: to.path, withDestinationPath: linkTarget)
                        report.copied += 1
                    case .file:
                        let copied = try syncFile(from: from, to: to, size: entry.size, modified: entry.modified,
                                                  isCancelled: isCancelled, progress: { progress(label, Int64($0)) })
                        if copied {
                            report.copied += 1
                            report.bytesCopied += entry.size
                        } else {
                            report.unchanged += 1
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    report.problems.append("\(label): \(error.localizedDescription)")
                }
            }
            if cleanAppleDouble { VerifiedCopy.removeAppleDouble(for: walk.entries, at: target) }
        }
        return report
    }

    static func ensureDirectory(_ url: URL) throws {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CopyError.destinationExists(url.path) }
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    /// Копирует файл, если копии нет или она отличается размером или датой.
    /// Новая версия пишется во временный файл, сверяется и только потом заменяет старую.
    @discardableResult
    public static func syncFile(from source: URL, to destination: URL, size: Int64, modified: Date?, permissions: Int? = nil,
                                isCancelled: () -> Bool = { false }, progress: (Int) -> Void = { _ in }) throws -> Bool {
        let fm = FileManager.default
        if let attributes = try? fm.attributesOfItem(atPath: destination.path) {
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CopyError.destinationExists(destination.path) }
            let existingSize = (attributes[.size] as? NSNumber)?.int64Value
            let existingDate = attributes[.modificationDate] as? Date
            // exFAT хранит время с точностью до 10 мс, FAT — до 2 секунд.
            if existingSize == size, let existingDate, let modified, abs(existingDate.timeIntervalSince(modified)) <= 2 {
                return false
            }
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".offload-\(UUID().uuidString).tmp")
        do {
            let hash = try VerifiedCopy.copyFile(from: source, to: temporary, isCancelled: isCancelled, progress: progress)
            guard try FileHasher.sha256(of: temporary, isCancelled: isCancelled) == hash else {
                throw CopyError.verificationFailed(destination.lastPathComponent)
            }
            var attributes: [FileAttributeKey: Any] = [:]
            if let modified { attributes[.modificationDate] = modified }
            if let permissions { attributes[.posixPermissions] = permissions }
            try fm.setAttributes(attributes, ofItemAtPath: temporary.path)
            guard rename(temporary.path, destination.path) == 0 else {
                throw CopyError.writeFailed(destination.path, String(cString: strerror(errno)))
            }
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
        return true
    }
}
