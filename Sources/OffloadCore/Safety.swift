import Darwin
import Foundation

/// Разворачивание символических ссылок в пути, которого ещё может не быть.
///
/// `URL.resolvingSymlinksInPath()` на такой путь отвечает им же: Foundation разворачивает
/// ссылки, только если путь существует целиком. А возврат из журнала пишет ровно туда,
/// где файла ещё нет, — и проверки пути смотрели бы на ссылку, а не на то, куда она ведёт.
public enum Paths {
    public static func resolve(_ url: URL) -> URL {
        var tail: [String] = []
        var current = url.standardizedFileURL
        while true {
            if let real = real(current.path) {
                // realpath и Foundation расходятся на firmlink’ах macOS: для одного и того же
                // места realpath отвечает «/var/…», а resolvingSymlinksInPath — «/private/var/…».
                // Приводим к виду Foundation, иначе путь и домашняя папка перестанут совпадать.
                var result = URL(fileURLWithPath: real).resolvingSymlinksInPath()
                for part in tail.reversed() { result.appendPathComponent(part) }
                return result.standardizedFileURL
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent.path != current.path, current.path != "/" else { return url.standardizedFileURL }
            tail.append(current.lastPathComponent)
            current = parent
        }
    }

    static func real(_ path: String) -> String? {
        guard let buffer = realpath(path, nil) else { return nil }
        defer { free(buffer) }
        return String(cString: buffer)
    }
}

/// Можно ли трогать объект.
public enum Verdict: Hashable, Sendable {
    case safe
    /// Можно, но есть оговорки — нужно явное подтверждение.
    case caution([String])
    case blocked(String)

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    public var notes: [String] {
        switch self {
        case .safe: return []
        case .caution(let notes): return notes
        case .blocked(let reason): return [reason]
        }
    }
}

/// Правила, выученные на практике: что переносить нельзя, даже если данные останутся целы.
public struct SafetyRules: Sendable {
    public let home: URL
    public var activeWithin: TimeInterval

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, activeDays: Double = 7) {
        // Домашняя папка и проверяемый путь разворачиваются одинаково, иначе обычный путь
        // выглядел бы лежащим вне дома.
        self.home = Paths.resolve(home)
        self.activeWithin = activeDays * 86_400
    }

    /// Пакеты, на которые приложения хранят ссылки. После переноса приложение их теряет
    /// (так UTM показал перенесённые виртуалки «Недоступно»).
    public static let registeredBundleExtensions: Set<String> = [
        "utm", "vmwarevm", "pvm", "vbox", "photoslibrary", "musiclibrary", "tvlibrary",
        "fcpbundle", "logicx", "imovielibrary", "aplibrary", "lrcat", "lrdata",
    ]

    static let standardFolders: Set<String> = [
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Library", "Applications", "Public", "Sites",
    ]

    /// Скрытые папки с ключами, настройками и инструментами разработки.
    static let pinnedHiddenFolders: Set<String> = [
        ".ssh", ".gnupg", ".config", ".docker", ".kube", ".aws", ".azure", ".gcloud", ".Trash",
        ".local", ".npm", ".cache", ".cargo", ".rustup", ".gradle", ".m2", ".nvm", ".pyenv",
        ".bun", ".deno", ".zsh_sessions", ".oh-my-zsh", ".vscode", ".cursor", ".claude", ".codex",
    ]

    static func isRegisteredBundle(_ name: String) -> Bool {
        registeredBundleExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Быстрая проверка только по пути, без чтения содержимого.
    public func pathVerdict(for url: URL) -> Verdict {
        let path = Paths.resolve(url).path
        let homePath = home.path
        let parts: [String]
        if path.hasPrefix(homePath + "/") {
            parts = path.dropFirst(homePath.count + 1).split(separator: "/").map(String.init)
        } else if path.hasPrefix("/Users/Shared/") {
            let shared = path.dropFirst("/Users/Shared/".count).split(separator: "/").map(String.init)
            if shared.first == "Library" {
                return .blocked("Данные приложений в /Users/Shared/Library (например, движок BlueStacks): приложение перестанет их находить.")
            }
            if let bundle = shared.first(where: Self.isRegisteredBundle) { return Self.bundleBlocked(bundle) }
            return .safe
        } else if path == homePath {
            return .blocked("Домашнюю папку целиком переносить нельзя.")
        } else {
            return .blocked("Переносить можно только из домашней папки и /Users/Shared.")
        }
        guard let first = parts.first else { return .blocked("Домашнюю папку целиком переносить нельзя.") }

        if parts.count == 1, Self.standardFolders.contains(first) {
            return .blocked("«\(first)» — стандартная папка macOS. Переносите её содержимое, а не саму папку.")
        }
        // У ~/Library свои правила и свой поиск пакетов: здесь папки приложений названы
        // идентификаторами, а «com.utmapp.UTM» оканчивается на «.UTM», как пакет виртуальной машины.
        if first == "Library" { return libraryVerdict(parts) }
        if let bundle = parts.first(where: Self.isRegisteredBundle) { return Self.bundleBlocked(bundle) }
        if first.hasPrefix(".") {
            if Self.pinnedHiddenFolders.contains(first) {
                return .blocked("«~/\(first)» — настройки, ключи или инструменты разработки. Им нужно оставаться на месте.")
            }
            if parts.count == 1 {
                return .blocked("Скрытая папка приложения целиком: приложение перестанет работать. Переносите отдельные данные внутри неё.")
            }
            return .caution(["Приложение, которому принадлежит «~/\(first)», будет искать эти данные по старому пути. Переносите, только если в нём можно указать новую папку (как папку моделей в LM Studio)."])
        }
        return .safe
    }

    /// Папки ~/Library, где приложения называют свои папки идентификаторами.
    static let appFolderParents: Set<String> = ["Containers", "Group Containers", "Caches", "Application Support",
                                                "Application Scripts", "HTTPStorages", "WebKit", "Saved Application State"]

    /// Идентификатор приложения или группы: «com.utmapp.UTM», «WDNLXAD4W8.com.utmapp.UTM».
    static func isIdentifier(_ name: String) -> Bool {
        !name.contains(" ") && name.split(separator: ".", omittingEmptySubsequences: false).count >= 3
    }

    static func bundleBlocked(_ bundle: String) -> Verdict {
        .blocked("«\(bundle)» зарегистрирован в приложении (виртуальная машина, медиатека или проект). После переноса приложение его потеряет, даже если данные целы.")
    }

    func libraryVerdict(_ parts: [String]) -> Verdict {
        func under(_ prefix: [String]) -> Bool {
            parts.count >= prefix.count && Array(parts.prefix(prefix.count)) == prefix
        }
        func inside(_ prefix: [String]) -> Bool { parts.count > prefix.count && under(prefix) }

        // Известные крупные места — с объяснением, как освободить их правильно.
        if under(["Library", "Containers", "com.docker.docker"]) {
            return .blocked("Диск Docker. Место в нём освобождается в разделе «Docker»: очисткой образов и кеша сборки и архивацией неиспользуемых томов.")
        }
        if under(["Library", "Containers", "com.utmapp.UTM"]) {
            return .blocked("Виртуальные машины UTM. Удаляйте и переносите их через сам UTM, иначе он их потеряет.")
        }
        if parts.count >= 3, parts[1] == "Group Containers", parts[2].hasSuffix(".ru.keepcoder.Telegram") {
            return .blocked("База и кеш Telegram. Кеш очищается в самом Telegram: Настройки → Данные и память → Использование памяти.")
        }
        if under(["Library", "Application Support", "Claude", "vm_bundles"]) {
            return .blocked("Виртуальная машина приложения Claude — она нужна ему для работы.")
        }
        // Пакеты в ~/Library запрещены, как и везде. Кроме имени сразу под Containers, Caches
        // и т. п., похожего на идентификатор: это папка приложения, а не пакет. Только там:
        // в Logs и прочих местах, откуда переносить можно, «a.b.utm» — машина, и её не трогаем.
        if let bundle = parts.indices.first(where: { index in
            Self.isRegisteredBundle(parts[index])
                && !(index == 2 && Self.appFolderParents.contains(parts[1]) && Self.isIdentifier(parts[index]))
        }) {
            return Self.bundleBlocked(parts[bundle])
        }

        if inside(["Library", "iTunes", "iPhone Software Updates"]) || inside(["Library", "iTunes", "iPad Software Updates"]) {
            return .safe
        }
        if inside(["Library", "Logs"]) { return .safe }
        if inside(["Library", "Application Support", "MobileSync", "Backup"]) {
            return .caution(["Finder не увидит эту резервную копию iPhone, пока вы не вернёте её на место."])
        }
        if let last = parts.last, (last as NSString).pathExtension.lowercased() == "log" { return .safe }
        return .blocked("Данные приложений в ~/Library: приложение перестанет их находить. Отсюда можно переносить только прошивки iPhone, логи и резервные копии iPhone.")
    }

    /// Итоговое решение с учётом содержимого и открытых файлов.
    public func verdict(for url: URL, content: ContentReport?, openBy: [String] = [], now: Date = Date()) -> Verdict {
        var notes: [String] = []
        switch pathVerdict(for: url) {
        case .blocked(let reason): return .blocked(reason)
        case .caution(let cautions): notes += cautions
        case .safe: break
        }
        if !openBy.isEmpty {
            return .blocked("Файлы сейчас открыты: \(openBy.prefix(3).joined(separator: ", ")). Закройте приложение и повторите.")
        }
        guard let content else { return notes.isEmpty ? .safe : .caution(notes) }
        if let mounted = content.mountedVolume {
            return .blocked("Внутри смонтирован другой диск («\(mounted)»). Отключите его или переносите по частям.")
        }
        if let bundle = content.registeredBundle {
            return .blocked("Внутри лежит «\(bundle)» — пакет, зарегистрированный в приложении (например, виртуальная машина UTM). После переноса приложение его потеряет.")
        }
        if content.unreadable > 0 {
            return .blocked("Нет доступа к \(content.unreadable) объектам внутри. Выдайте Offload полный доступ к диску в Системных настройках.")
        }
        if content.truncated {
            return .blocked("Файлов слишком много, проверка не закончена — переносите по частям.")
        }
        if let date = content.newestModification, now.timeIntervalSince(date) < activeWithin {
            notes.append("Менялось \(Format.relative(date, now: now)) — возможно, ещё используется.")
        }
        if content.containsGitRepo { notes.append("Внутри git-репозиторий — похоже на рабочий проект.") }
        return notes.isEmpty ? .safe : .caution(notes)
    }
}

/// Подходит ли диск назначения для конкретного содержимого.
public struct DestinationCheck: Sendable, Equatable {
    public var blockers: [String] = []
    public var notes: [String] = []
    public var requiredBytes: Int64 = 0
    public var isOK: Bool { blockers.isEmpty }
}

extension SafetyRules {
    public static func checkDestination(_ volume: VolumeInfo, sourceVolume: VolumeInfo?, content: ContentReport) -> DestinationCheck {
        var check = DestinationCheck()
        if volume.isReadOnly {
            check.blockers.append("Диск «\(volume.name)» доступен только для чтения (\(volume.fsDisplayName)).")
        }
        if let sourceVolume, sourceVolume.mountPoint == volume.mountPoint {
            check.blockers.append("Источник и назначение на одном диске — место не освободится.")
        }
        if content.symlinkCount > 0 {
            if !volume.keepsSymlinks {
                check.blockers.append("\(volume.fsDisplayName) не хранит символические ссылки, а внутри их \(content.symlinkCount). Перенос бы их сломал.")
            } else if volume.emulatesSymlinks {
                check.notes.append("Символических ссылок внутри: \(content.symlinkCount). На \(volume.fsDisplayName) macOS хранит их в своём формате: на Mac они работают, а Windows и Linux могут увидеть вместо них обычные файлы.")
            }
        }
        if let limit = volume.maxFileSize, content.largestFile > limit {
            check.blockers.append("\(volume.fsDisplayName) не принимает файлы больше 4 ГБ, а самый большой здесь — \(Format.bytes(content.largestFile)).")
        }
        // Ни одной из двух мер по отдельности верить нельзя, поэтому берём большую.
        // Логический размер мал для дерева из тысяч мелких файлов: каждый занимает на диске
        // целое число блоков, и файл в 100 байт съедает блок целиком — сумма занятого
        // заметно больше суммы весов. Занятое на диске, наоборот, мало для разрежённых
        // файлов: копия пишется обычным чтением и записью, дыры не переносятся, и на
        // приёмнике даже APFS займёт полный логический размер.
        // Недооценка здесь стоит дорого: проверка пропустит перенос, а он упадёт посередине,
        // когда место кончится, — и данные останутся разложенными по двум дискам.
        let overhead = volume.createsAppleDouble ? Int64(content.files + content.directories) * volume.blockSize * 2 : 0
        let margin: Int64 = 512 * 1024 * 1024
        check.requiredBytes = max(content.logicalBytes, content.allocatedBytes) + overhead + margin
        if volume.availableBytes < check.requiredBytes {
            check.blockers.append("На «\(volume.name)» свободно \(Format.bytes(volume.availableBytes)), а нужно около \(Format.bytes(check.requiredBytes)).")
        }
        if content.sparseFiles > 0 {
            check.notes.append("Разрежённые или сжатые файлы (\(content.sparseFiles)) займут на диске полный размер: \(Format.bytes(content.logicalBytes)) вместо \(Format.bytes(content.allocatedBytes)).")
        }
        if content.hardLinkedFiles > 0 {
            check.notes.append("Файлов, на которые ведёт несколько имён (жёсткие ссылки): \(content.hardLinkedFiles). В копии каждое имя станет отдельным файлом: места займёт больше, а правка одного больше не будет видна в остальных.")
        }
        if content.taggedFiles > 0 {
            check.notes.append("У \(content.taggedFiles) объектов есть метки Finder, комментарии или другие расширенные атрибуты. Данные и права копируются, а эти пометки — нет: после возврата их не будет.")
        }
        if volume.createsAppleDouble {
            check.notes.append("macOS создаст рядом служебные файлы ._* — Offload удалит их после сверки.")
        }
        return check
    }
}
