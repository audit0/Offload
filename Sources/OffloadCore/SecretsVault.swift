import Foundation

public enum VaultError: LocalizedError, Equatable {
    case weakPassword
    case alreadyExists
    case notEncrypted
    case wrongPassword
    case mountFailed(String)
    /// В сейфе открыты файлы — закрыть его сейчас значило бы оборвать чужую работу.
    case busy
    /// Резервная копия заголовка не от этого сейфа или не открывается паролем.
    case headerRejected(String)

    public var errorDescription: String? {
        switch self {
        case .weakPassword:
            return "Пароль слишком слабый: нужно не меньше \(SecretsVault.minimumPasswordLength) символов и стойкость от \(Int(PasswordStrength.acceptableBits)) бит."
        case .alreadyExists: return "Контейнер уже существует."
        // Говорим именно «не подтверждено»: снаружи случай «образ без шифрования» и случай
        // «подделанный заголовок, подсистема образов шифрования не видит» выглядят одинаково.
        case .notEncrypted: return "Шифрование образа не подтверждено — складывать в него ключи нельзя."
        case .wrongPassword: return "Неверный пароль."
        case .mountFailed(let message): return "Не удалось открыть сейф: \(message)"
        case .busy: return "В сейфе открыты файлы. Закройте их в других программах и повторите."
        case .headerRejected(let reason): return "Заголовок не восстановлен: \(reason)"
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

    /// Имя, под которым Offload создаёт сейф, и имя тома внутри него.
    public static let safeImageName = "Offload Safe.sparsebundle"
    public static let safeVolumeName = "Offload Safe"
    /// Так назывался контейнер для ключей в первых версиях — его тоже узнаём.
    static let legacyImageName = "Offload Secrets.sparsebundle"

    /// Где на диске лежит сейф: выбранный человеком образ, затем свой, затем прежний контейнер
    /// для ключей, затем любой зашифрованный образ в корне. Если нет ни одного — путь,
    /// по которому сейф будет создан.
    public init(on volume: VolumeInfo, preferred: URL? = nil) {
        let fm = FileManager.default
        let own = volume.mountPoint.appendingPathComponent(Self.safeImageName, isDirectory: true)
        let legacy = volume.mountPoint.appendingPathComponent(Self.legacyImageName, isDirectory: true)
        if let preferred, preferred.deletingLastPathComponent().standardizedFileURL == volume.mountPoint.standardizedFileURL,
           fm.fileExists(atPath: preferred.path) {
            imageURL = preferred
        } else if fm.fileExists(atPath: own.path) {
            imageURL = own
        } else if fm.fileExists(atPath: legacy.path) {
            imageURL = legacy
        } else {
            imageURL = Self.existingEncryptedBundle(in: volume.mountPoint) ?? own
        }
    }

    /// Все зашифрованные образы в корне диска — чтобы человек сам выбрал, какой из них его сейф,
    /// если их несколько. Порядок: свой, прежний, остальные по весу заголовка и имени.
    public static func candidates(in root: URL) -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        func rank(_ url: URL) -> Int {
            switch url.lastPathComponent {
            case safeImageName: return 0
            case legacyImageName: return 1
            default: return 2
            }
        }
        return items.filter { $0.pathExtension == "sparsebundle" && SecretsVault(imageURL: $0).isEncrypted }
            .sorted {
                if rank($0) != rank($1) { return rank($0) < rank($1) }
                let (left, right) = (tokenSize($0), tokenSize($1))
                if left != right { return left > right }
                return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }

    /// Первый из зашифрованных образов в корне диска (см. `candidates`).
    public static func existingEncryptedBundle(in root: URL) -> URL? { candidates(in: root).first }

    public var exists: Bool { FileManager.default.fileExists(atPath: imageURL.path) }

    /// Зашифрован ли образ — ответ подсистемы образов, а не догадка по файлам.
    ///
    /// `hdiutil isencrypted` читает заголовок и отвечает сразу, без пароля и без системных
    /// окон (в отличие от `imageinfo`, проверено). Подделки он различает: образ с восемью
    /// байтами «encrcdsa» в token называет незашифрованным, а набитый нулями заголовок —
    /// зашифрованным, но без единого пароля. Поэтому требуем оба признака: шифрование
    /// и хотя бы один пароль, которым его можно открыть.
    public var isEncrypted: Bool {
        guard Self.hasEncryptionHeader(imageURL) else { return false }
        return Self.encryptionInfo(of: imageURL)?.opensWithPassword ?? false
    }

    /// Что подсистема образов знает о шифровании образа, не открывая его.
    public struct EncryptionInfo: Sendable, Equatable {
        public var encrypted: Bool
        public var passphraseCount: Int
        public var version: Int?
        public var uuid: String?

        public var opensWithPassword: Bool { encrypted && passphraseCount > 0 }
    }

    public static func encryptionInfo(of image: URL) -> EncryptionInfo? {
        guard let result = try? Runner.run("hdiutil", ["isencrypted", "-plist", image.path], timeout: 20), result.succeeded,
              let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any],
              let encrypted = plist["encrypted"] as? Bool else { return nil }
        return EncryptionInfo(encrypted: encrypted,
                              passphraseCount: (plist["passphrase-count"] as? NSNumber)?.intValue ?? 0,
                              version: (plist["version"] as? NSNumber)?.intValue,
                              uuid: plist["uuid"] as? String)
    }

    /// Предел роста образа — читается из Info.plist внутри sparsebundle, пароль не нужен.
    public var sizeLimit: Int64? {
        let url = imageURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return (plist["size"] as? NSNumber)?.int64Value
    }

    /// Сколько образ занимает на внешнем диске сейчас.
    public var allocatedBytes: Int64 { Inspector.inspect(imageURL).allocatedBytes }

    /// Первый, самый дешёвый отсев: у зашифрованного sparsebundle внутри лежит token —
    /// заголовок CDSA с ключевым материалом, он начинается с «encrcdsa». Обычный образ
    /// hdiutil создаёт с файлом token РАЗМЕРОМ 0 байт, так что бытовой случай («это просто
    /// не тот образ») ловится чтением восьми байт, без запуска внешних программ.
    ///
    /// Но доказательством шифрования это не является, и одного такого отсева мало.
    /// token — обычный файл внутри папки .sparsebundle, и любой, у кого есть запись в корень
    /// внешнего диска, может положить туда незашифрованный образ, вписав в token «encrcdsa».
    /// К такому образу `hdiutil attach -stdinpass` подходит с ЛЮБЫМ паролем и возвращает 0 —
    /// то есть проверка «пароль принят» ничего не подтверждает, и ключи, ssh и токены легли бы
    /// на диск открытым текстом. Поэтому решение принимает не этот метод, а подсистема образов:
    /// см. `attachedImageIsEncrypted`.
    ///
    /// Спросить про ещё не подключённый образ нельзя вообще ничем: и `hdiutil imageinfo`,
    /// и `diskutil image info` на зашифрованном образе идут за паролем, а в графическом
    /// сеансе macOS показывает на каждый такой запрос своё системное окно «Enter password
    /// to access…». Раздел «Бэкап» перечитывает состояние после каждой операции, и это
    /// засыпало бы человека ворохом окон — такое уже случилось на проверках.
    ///
    /// Поэтому второй признак тоже читается из самого файла: у настоящего контейнера token —
    /// это заголовок CDSA с ключевым материалом, он в сотню килобайт, а подделка обычно
    /// ограничивается восемью байтами сигнатуры. Это по-прежнему не доказательство, а способ
    /// не выбрать заведомую пустышку, когда рядом лежит настоящий контейнер человека.
    static func tokenSize(_ image: URL) -> Int {
        let token = image.appendingPathComponent("token")
        return ((try? FileManager.default.attributesOfItem(atPath: token.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    static let minimumTokenBytes = 1024

    public static func hasEncryptionHeader(_ image: URL) -> Bool {
        let token = image.appendingPathComponent("token")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: token.path))?[.size] as? NSNumber,
              size.intValue >= minimumTokenBytes,
              let handle = try? FileHandle(forReadingFrom: token) else { return false }
        defer { try? handle.close() }
        return ((try? handle.read(upToCount: 8)) ?? nil) == Data("encrcdsa".utf8)
    }

    /// Зашифрован ли образ за УЖЕ подключённым томом.
    ///
    /// Единственная проверка, которую нельзя обойти подложенным файлом: `hdiutil info -plist`
    /// отвечает про то, что подсистема образов уже открыла, поэтому ключ `image-encrypted`
    /// приходит от неё самой, а не из файла на диске. Пароля она при этом не просит и не виснет.
    ///
    /// Нет ответа — считаем «не подтверждено»: том, про который мы не можем доказать шифрование,
    /// не должен получить ключи, ssh и токены. Данные при этом не теряются — образ остаётся
    /// на месте и открывается вручную, — а вот выложенные открытым текстом ключи не отозвать.
    static func attachedImageIsEncrypted(mountPoint: URL, image: URL) -> Bool {
        guard let result = try? Runner.run("hdiutil", ["info", "-plist"], timeout: 30), result.succeeded,
              let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return false }
        let mount = mountPoint.standardizedFileURL.path
        // Путь образа hdiutil отдаёт уже развёрнутым (/tmp → /private/tmp), поэтому
        // обе стороны сравнения разворачиваем одинаково, иначе свой же образ не найдётся.
        let target = Paths.resolve(image).path
        func encrypted(_ entry: [String: Any]) -> Bool {
            (entry["image-encrypted"] as? NSNumber)?.boolValue == true
        }
        // Сначала ищем строго по точке монтирования: это тот самый том, который мы
        // только что получили от attach, и подменить его в ответе нечем. Путь образа —
        // только запасной признак: записей с одним и тем же путём может оказаться
        // несколько (образ подключали раньше, а содержимое папки-образа с тех пор
        // подменили), и чужая запись ответила бы за наш том.
        for entry in images {
            let entities = (entry["system-entities"] as? [[String: Any]]) ?? []
            guard entities.compactMap({ $0["mount-point"] as? String }).contains(mount) else { continue }
            return encrypted(entry)
        }
        for entry in images {
            guard let path = entry["image-path"] as? String, Paths.resolve(URL(fileURLWithPath: path)).path == target else { continue }
            return encrypted(entry)
        }
        return false
    }

    public func create(password: String, sizeGB: Int = 4) throws {
        try create(password: password, maxBytes: Int64(sizeGB) << 30, volumeName: Self.volumeName)
    }

    /// Разрежённый образ: предел можно ставить во весь диск — места он занимает ровно
    /// столько, сколько в нём лежит. Внутренний APFS после создания не растягивается
    /// (hdiutil resize умеет только HFS+), поэтому предел выбирается сразу с запасом.
    public func create(password: String, maxBytes: Int64, volumeName: String) throws {
        guard PasswordStrength.evaluate(password).isAcceptable else { throw VaultError.weakPassword }
        guard !exists else { throw VaultError.alreadyExists }
        let megabytes = max(64, maxBytes >> 20)
        try Runner.check("hdiutil", ["create", "-size", "\(megabytes)m", "-type", "SPARSEBUNDLE", "-fs", "APFS",
                                     "-encryption", "AES-256", "-volname", volumeName, "-stdinpass", "-quiet",
                                     imageURL.path], stdin: Data(password.utf8), timeout: 600)
        guard isEncrypted else { throw VaultError.notEncrypted }
    }

    /// Смена пароля. Ключ шифрования данных при этом не меняется — перешифровывается только
    /// заголовок, поэтому это быстро. Та же оговорка, что у VeraCrypt: копия заголовка,
    /// снятая раньше, по-прежнему открывается СТАРЫМ паролем.
    public func changePassword(old: String, new: String) throws {
        guard PasswordStrength.evaluate(new).isAcceptable else { throw VaultError.weakPassword }
        // Сначала — открыт ли: у подключённого образа isencrypted не отвечает, и открытый
        // сейф иначе выглядел бы незашифрованным.
        guard currentMountPoint() == nil else { throw VaultError.busy }
        guard isEncrypted else { throw VaultError.notEncrypted }
        // Оба пароля — через stdin, каждый с нулём в конце, в порядке «старый, новый».
        var input = Data(old.utf8); input.append(0); input.append(contentsOf: Data(new.utf8)); input.append(0)
        let result = try Runner.run("hdiutil", ["chpass", "-oldstdinpass", "-newstdinpass", imageURL.path],
                                    stdin: input, timeout: 180)
        guard result.succeeded else { throw Self.passwordError(result.stderr) }
    }

    /// Возвращает внешнему диску место, освободившееся внутри сейфа. Само оно не возвращается:
    /// удалённые внутри файлы продолжают занимать полосы образа (проверено: 30 МБ после
    /// удаления так и лежат, пока не сжать). Нужны пароль и закрытый сейф.
    @discardableResult
    public func compact(password: String) throws -> String {
        guard currentMountPoint() == nil else { throw VaultError.busy }
        guard isEncrypted else { throw VaultError.notEncrypted }
        let result = try Runner.run("hdiutil", ["compact", "-stdinpass", imageURL.path], stdin: Data(password.utf8), timeout: 3600)
        guard result.succeeded else { throw Self.passwordError(result.stderr) }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func passwordError(_ stderr: String) -> VaultError {
        // hdiutil переводит сообщения на язык системы.
        let message = stderr.lowercased()
        if ["authentication", "аутентификац", "authentifi"].contains(where: { message.contains($0) }) {
            return .wrongPassword
        }
        if ["busy", "занят", "occup"].contains(where: { message.contains($0) }) { return .busy }
        return .mountFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Резервная копия заголовка

    /// Резервная копия заголовка, как в VeraCrypt: в заголовке (файл token) лежит ключ данных,
    /// зашифрованный паролем. Испортится он — пропадёт всё содержимое, даже при верном пароле.
    /// Копия так же защищена паролем, как сам заголовок, и хранить её можно где угодно
    /// (но лучше не на том же диске). Оговорка: после смены пароля старая копия открывается
    /// старым паролем — её надо снять заново, а прежнюю удалить.
    public struct HeaderBackup: Codable, Sendable {
        public var format = 1
        public var imageName: String
        public var uuid: String?
        public var created: Date
        public var token: Data
    }

    public func backupHeader(to directory: URL) throws -> URL {
        guard isEncrypted else { throw VaultError.notEncrypted }
        let token = try Data(contentsOf: imageURL.appendingPathComponent("token"))
        let backup = HeaderBackup(imageName: imageURL.lastPathComponent, uuid: Self.encryptionInfo(of: imageURL)?.uuid,
                                  created: Date(), token: token)
        let stamp = ISO8601DateFormatter().string(from: backup.created).prefix(10)
        let base = (imageURL.lastPathComponent as NSString).deletingPathExtension
        let url = directory.appendingPathComponent("\(base) — заголовок \(stamp).offload-header")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // O_EXCL: копия заголовка не должна молча затереть другую.
        guard !FileManager.default.fileExists(atPath: url.path) else { throw VaultError.alreadyExists }
        try encoder.encode(backup).write(to: url, options: .withoutOverwriting)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    /// Возвращает заголовок из копии. Прежний откладывается, копия ставится на место, и сейф
    /// пробуется открыть паролем; не открылся — прежний заголовок возвращается как был.
    public func restoreHeader(from file: URL, password: String) throws {
        guard currentMountPoint() == nil else { throw VaultError.busy }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file), data.count < 4 << 20,
              let backup = try? decoder.decode(HeaderBackup.self, from: data),
              backup.token.prefix(8) == Data("encrcdsa".utf8) else {
            throw VaultError.headerRejected("файл не похож на копию заголовка Offload")
        }
        if let expected = backup.uuid, let current = Self.encryptionInfo(of: imageURL)?.uuid, expected != current {
            throw VaultError.headerRejected("копия снята с другого сейфа")
        }
        let token = imageURL.appendingPathComponent("token")
        let aside = imageURL.appendingPathComponent("token.offload-previous")
        let fm = FileManager.default
        try? fm.removeItem(at: aside)
        if fm.fileExists(atPath: token.path) { try fm.moveItem(at: token, to: aside) }
        do {
            try backup.token.write(to: token, options: .withoutOverwriting)
            let mount = try attach(password: password)
            try? Self.detach(mount)
        } catch {
            try? fm.removeItem(at: token)
            if fm.fileExists(atPath: aside.path) { try? fm.moveItem(at: aside, to: token) }
            if case VaultError.wrongPassword = error { throw VaultError.headerRejected("пароль к этой копии не подходит") }
            throw error
        }
        // Старый заголовок внутри образа не оставляем: он открылся бы старым паролем.
        try? fm.removeItem(at: aside)
    }

    public func attach(password: String) throws -> URL {
        // Дешёвый отсев до запуска hdiutil: обычный образ примет любой пароль.
        guard isEncrypted else { throw VaultError.notEncrypted }
        let result = try Runner.run("hdiutil", ["attach", "-stdinpass", "-nobrowse", "-owners", "on", "-plist", imageURL.path],
                                    stdin: Data(password.utf8), timeout: 180)
        guard result.succeeded else { throw Self.passwordError(result.stderr) }
        guard let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw VaultError.mountFailed("hdiutil не сообщил точку монтирования")
        }
        let mountPoint = URL(fileURLWithPath: mount, isDirectory: true)
        // Код возврата hdiutil здесь ничего не доказывает: к подделанному образу (token
        // с «encrcdsa», а шифрования нет) он подходит с любым паролем и отвечает 0.
        // Спрашиваем подсистему образов про уже подключённый том — и если она говорит, что
        // шифрования нет, отсоединяем немедленно, не записав внутрь ни байта.
        guard Self.attachedImageIsEncrypted(mountPoint: mountPoint, image: imageURL) else {
            Self.detachIgnoringErrors(mountPoint)
            throw VaultError.notEncrypted
        }
        return mountPoint
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

    /// Закрыть сейф. Без force: если в нём открыты файлы, закрытие откажет с `.busy`, и чужая
    /// работа не оборвётся. С force — как «Dismount all» в VeraCrypt с принудительным режимом.
    public static func detach(_ mountPoint: URL, force: Bool = false) throws {
        let result = try Runner.run("hdiutil", ["detach"] + (force ? ["-force"] : []) + [mountPoint.path], timeout: 120)
        guard result.succeeded else { throw passwordError(result.stderr) }
    }

    /// Закрыть том во что бы то ни стало и молча. Нужно там, где мы сами его только что
    /// открыли и уже решили, что пользоваться им нельзя: оставить чужой образ подключённым
    /// хуже, чем не суметь красиво сообщить об ошибке отсоединения.
    public static func detachIgnoringErrors(_ mountPoint: URL) {
        if (try? detach(mountPoint)) != nil { return }
        _ = try? Runner.run("hdiutil", ["detach", "-force", mountPoint.path], timeout: 120)
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
