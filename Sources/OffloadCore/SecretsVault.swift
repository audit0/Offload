import Foundation

public enum VaultError: LocalizedError, Equatable {
    case weakPassword
    case alreadyExists
    case notEncrypted
    case wrongPassword
    case mountFailed(String)

    public var errorDescription: String? {
        switch self {
        case .weakPassword: return "Пароль должен быть не короче \(SecretsVault.minimumPasswordLength) символов."
        case .alreadyExists: return "Контейнер уже существует."
        case .notEncrypted: return "Контейнер создан без шифрования — пользоваться им нельзя."
        case .wrongPassword: return "Неверный пароль."
        case .mountFailed(let message): return "Не удалось открыть контейнер: \(message)"
        }
    }
}

public struct SecretsReport: Sendable {
    public var copied = 0
    public var unchanged = 0
    /// Приватные SSH-ключи без парольной фразы.
    public var unprotectedKeys: [String] = []
    public var problems: [String] = []

    public init() {}
}

/// Шифрованный контейнер (AES-256, APFS внутри) для ключей, токенов и .env.
///
/// Пароль задаёт человек; Offload его не хранит и передаёт hdiutil только через stdin,
/// потому что аргументы командной строки видны любому процессу через `ps`.
public struct SecretsVault: Sendable {
    public static let volumeName = "OffloadSecrets"
    public static let minimumPasswordLength = 12
    public static let dotfiles = [".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".gitconfig", ".npmrc", ".pypirc", ".netrc", ".git-credentials"]

    public let imageURL: URL

    public init(imageURL: URL) { self.imageURL = imageURL }

    /// Свой контейнер, а если его нет — любой зашифрованный sparsebundle в корне диска (созданный вручную).
    public init(on volume: VolumeInfo) {
        let own = volume.mountPoint.appendingPathComponent("Offload Secrets.sparsebundle", isDirectory: true)
        if FileManager.default.fileExists(atPath: own.path) {
            imageURL = own
        } else {
            imageURL = Self.existingEncryptedBundle(in: volume.mountPoint) ?? own
        }
    }

    public static func existingEncryptedBundle(in root: URL) -> URL? {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.filter { $0.pathExtension == "sparsebundle" && hasEncryptionHeader($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .first
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: imageURL.path) }
    public var isEncrypted: Bool { Self.hasEncryptionHeader(imageURL) }

    /// У зашифрованного sparsebundle внутри лежит token — заголовок CDSA с ключевым материалом,
    /// он начинается с «encrcdsa». Одного имени файла мало: пустой `token`, подложенный в обычный
    /// образ, раньше выдавал его за зашифрованный, а подходил к такому образу любой пароль —
    /// и ключи легли бы на диск открытым текстом.
    ///
    /// `hdiutil imageinfo` для этой проверки не годится: на зашифрованном образе он спрашивает
    /// пароль прямо у терминала и висит, даже когда stdin закрыт.
    public static func hasEncryptionHeader(_ image: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: image.appendingPathComponent("token")) else { return false }
        defer { try? handle.close() }
        return ((try? handle.read(upToCount: 8)) ?? nil) == Data("encrcdsa".utf8)
    }

    public func create(password: String, sizeGB: Int = 4) throws {
        guard password.count >= Self.minimumPasswordLength else { throw VaultError.weakPassword }
        guard !exists else { throw VaultError.alreadyExists }
        try Runner.check("hdiutil", ["create", "-size", "\(sizeGB)g", "-type", "SPARSEBUNDLE", "-fs", "APFS",
                                     "-encryption", "AES-256", "-volname", Self.volumeName, "-stdinpass", "-quiet",
                                     imageURL.path], stdin: Data(password.utf8), timeout: 300)
        guard isEncrypted else { throw VaultError.notEncrypted }
    }

    public func attach(password: String) throws -> URL {
        // Открывать незашифрованный образ как хранилище ключей нельзя: он примет любой пароль.
        guard isEncrypted else { throw VaultError.notEncrypted }
        let result = try Runner.run("hdiutil", ["attach", "-stdinpass", "-nobrowse", "-owners", "on", "-plist", imageURL.path],
                                    stdin: Data(password.utf8), timeout: 180)
        guard result.succeeded else {
            // hdiutil переводит сообщения на язык системы.
            let message = result.stderr.lowercased()
            if ["authentication", "аутентификац", "authentifi"].contains(where: { message.contains($0) }) {
                throw VaultError.wrongPassword
            }
            throw VaultError.mountFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw VaultError.mountFailed("hdiutil не сообщил точку монтирования")
        }
        return URL(fileURLWithPath: mount, isDirectory: true)
    }

    /// Точка монтирования, если контейнер уже открыт — например, вручную через hdiutil.
    public func currentMountPoint() -> URL? {
        guard let result = try? Runner.run("hdiutil", ["info", "-plist"], timeout: 30), result.succeeded,
              let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }
        let target = imageURL.standardizedFileURL.path
        for image in images {
            guard let path = image["image-path"] as? String,
                  URL(fileURLWithPath: path).standardizedFileURL.path == target,
                  let entities = image["system-entities"] as? [[String: Any]],
                  let mount = entities.compactMap({ $0["mount-point"] as? String }).first else { continue }
            return URL(fileURLWithPath: mount, isDirectory: true)
        }
        return nil
    }

    public static func detach(_ mountPoint: URL) throws {
        try Runner.check("hdiutil", ["detach", mountPoint.path], timeout: 120)
    }

    /// Складывает в открытый контейнер: ~/.ssh с правами, дотфайлы, учётку GitHub CLI
    /// и секреты проектов с сохранением относительных путей.
    public static func fill(_ mountPoint: URL, home: URL, projectRoots: [URL], isCancelled: () -> Bool = { false }) -> SecretsReport {
        var report = SecretsReport()
        let fm = FileManager.default

        func sync(_ entries: [TreeEntry], from source: URL, to target: URL) {
            for entry in entries {
                if isCancelled() { return }
                let from = entry.relativePath.isEmpty ? source : source.appendingPathComponent(entry.relativePath)
                let to = entry.relativePath.isEmpty ? target : target.appendingPathComponent(entry.relativePath)
                do {
                    switch entry.kind {
                    case .directory:
                        try fm.createDirectory(at: to, withIntermediateDirectories: true)
                        if let permissions = entry.permissions {
                            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: to.path)
                        }
                    case .file:
                        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                        let copied = try BackupEngine.syncFile(from: from, to: to, size: entry.size, modified: entry.modified,
                                                               permissions: entry.permissions, isCancelled: isCancelled)
                        if copied { report.copied += 1 } else { report.unchanged += 1 }
                    case .symlink:
                        continue
                    }
                } catch {
                    report.problems.append("\(from.path): \(error.localizedDescription)")
                }
            }
        }

        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        if let walk = try? TreeWalker.walk(ssh, strict: false, isCancelled: isCancelled) {
            sync(walk.entries, from: ssh, to: mountPoint.appendingPathComponent("ssh", isDirectory: true))
            report.problems += walk.problems.map { ".ssh/\($0)" }
            report.unprotectedKeys = unprotectedKeys(walk.entries, root: ssh)
        }

        let dotfilesTarget = mountPoint.appendingPathComponent("dotfiles", isDirectory: true)
        for name in dotfiles {
            let url = home.appendingPathComponent(name)
            guard let walk = try? TreeWalker.walk(url, strict: true), let entry = walk.entries.first, entry.isFile else { continue }
            sync([entry], from: url, to: dotfilesTarget.appendingPathComponent(name))
        }

        let gh = home.appendingPathComponent(".config/gh", isDirectory: true)
        if let walk = try? TreeWalker.walk(gh, strict: false, isCancelled: isCancelled) {
            sync(walk.entries, from: gh, to: mountPoint.appendingPathComponent("config/gh", isDirectory: true))
        }

        // Пути внутри project-secrets — относительно папки с проектами, чтобы вернуть всё одной командой
        // rsync -a project-secrets/ <папка>/. Если две папки дают один и тот же путь, второй файл не пишется.
        let projectTarget = mountPoint.appendingPathComponent("project-secrets", isDirectory: true)
        var claimed: [String: String] = [:]
        for root in projectRoots {
            guard let walk = try? TreeWalker.walk(root, strict: false, exclude: { relative, isDirectory in
                isDirectory && BackupEngine.defaultExcludedNames.contains((relative as NSString).lastPathComponent)
            }, isCancelled: isCancelled) else { continue }
            var secrets: [TreeEntry] = []
            for entry in walk.entries where entry.isFile && BackupEngine.isSecretPath(entry.relativePath, in: root) {
                if let owner = claimed[entry.relativePath], owner != root.path {
                    report.problems.append("\(root.lastPathComponent)/\(entry.relativePath): такой же путь уже есть в «\((owner as NSString).lastPathComponent)» — пропущен, чтобы не затереть")
                    continue
                }
                claimed[entry.relativePath] = root.path
                secrets.append(entry)
            }
            sync(secrets, from: root, to: projectTarget)
        }

        let keepassTarget = mountPoint.appendingPathComponent("keepass", isDirectory: true)
        for folder in ["Downloads", "Documents", "Desktop"] {
            let directory = home.appendingPathComponent(folder, isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names.sorted() where (name as NSString).pathExtension.lowercased() == "kdbx" {
                let url = directory.appendingPathComponent(name)
                guard let walk = try? TreeWalker.walk(url, strict: true), let entry = walk.entries.first, entry.isFile else { continue }
                sync([entry], from: url, to: keepassTarget.appendingPathComponent(name))
            }
        }

        // Свою инструкцию не пишем поверх чужой: в контейнер могли положить заметки вручную.
        let note = mountPoint.appendingPathComponent("КАК-ВОССТАНОВИТЬ.txt")
        if !FileManager.default.fileExists(atPath: note.path) {
            try? restoreNote.write(to: note, atomically: true, encoding: .utf8)
        }
        return report
    }

    static func unprotectedKeys(_ entries: [TreeEntry], root: URL) -> [String] {
        entries.filter { $0.isFile && $0.size < 64 * 1024 }.compactMap { entry in
            let url = root.appendingPathComponent(entry.relativePath)
            guard let head = readHead(url), head.contains("PRIVATE KEY") else { return nil }
            // Ключ без парольной фразы ssh-keygen прочитает с пустым паролем.
            let result = try? Runner.run("ssh-keygen", ["-y", "-P", "", "-f", url.path], timeout: 10)
            return result?.succeeded == true ? entry.relativePath : nil
        }
    }

    static func readHead(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = (try? handle.read(upToCount: 128)) ?? nil else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static let restoreNote = """
    ШИФРОВАННЫЙ КОНТЕЙНЕР OFFLOAD
    =============================
    ssh/              → в ~/.ssh, затем обязательно:
                        chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_*
                        (без этого ssh откажется использовать ключи)
    dotfiles/         → в домашнюю папку (.zshrc, .zprofile, .npmrc, .gitconfig…)
    config/gh/        → в ~/.config/gh (авторизация GitHub CLI)
    keepass/          → базы паролей KeePass (зашифрованы сами по себе)
    project-secrets/  → наложить поверх папки с проектами, пути сохранены:
                        rsync -a project-secrets/ <папка с проектами>/

    Закрывайте контейнер после работы: пока он открыт, файлы не защищены.
    """
}
