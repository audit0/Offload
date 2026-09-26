import Foundation

/// Что сделать с объектом при разборе Mac.
public enum CleanupAction: String, Codable, CaseIterable, Sendable, Hashable {
    /// В Корзину. Только то, что пересоздаётся или скачивается заново: кеши сборки, установщики.
    case trash
    /// В сейф со сверкой, оригинал удаляется после неё — как обычный перенос.
    case safe
    /// Добавить в папки бэкапа.
    case backup
    /// Не трогать.
    case keep
}

/// Что сканер узнал об объекте. Из этого, без обращения к диску, складывается предложение.
public struct CleanupObservation: Sendable, Hashable {
    public var url: URL
    public var bytes: Int64
    public var modified: Date?
    public var isDirectory: Bool
    /// Решение правил по пути: то же, что в «Освободить место».
    public var verdict: Verdict
    /// Внутри git-репозиторий.
    public var isProject: Bool
    /// Уже лежит в одной из папок бэкапа.
    public var inBackup: Bool
    /// Зашифрованный образ диска: такой человек делает сам для своих данных, это не установщик.
    public var isEncryptedImage: Bool

    public init(url: URL, bytes: Int64, modified: Date?, isDirectory: Bool, verdict: Verdict,
                isProject: Bool = false, inBackup: Bool = false, isEncryptedImage: Bool = false) {
        self.url = url
        self.bytes = bytes
        self.modified = modified
        self.isDirectory = isDirectory
        self.verdict = verdict
        self.isProject = isProject
        self.inBackup = inBackup
        self.isEncryptedImage = isEncryptedImage
    }
}

public struct CleanupSuggestion: Sendable, Identifiable, Hashable {
    public var id: String { url.path }
    public var url: URL
    public var bytes: Int64
    public var modified: Date?
    public var isDirectory: Bool
    /// Что предлагается сделать.
    public var action: CleanupAction
    /// Почему — по-человечески, одной фразой.
    public var reason: String
    /// Что вообще можно выбрать для этого объекта; «оставить» есть всегда.
    public var allowed: [CleanupAction]
    /// Предложение взято из прошлого решения человека, а не из правил.
    public var learned: Bool
    /// Оговорки правил, которые человек видит до переноса в сейф.
    public var cautions: [String]

    public init(url: URL, bytes: Int64, modified: Date?, isDirectory: Bool, action: CleanupAction, reason: String,
                allowed: [CleanupAction], learned: Bool, cautions: [String]) {
        self.url = url
        self.bytes = bytes
        self.modified = modified
        self.isDirectory = isDirectory
        self.action = action
        self.reason = reason
        self.allowed = allowed
        self.learned = learned
        self.cautions = cautions
    }
}

/// Раскладывает найденное по действиям. Чистая логика: ни диска, ни времени, кроме переданного.
///
/// Удаление здесь — только в Корзину и только для того, что восстанавливается само
/// (кеши сборки, скачанные пакеты) или скачивается заново (установщики). Личные файлы без
/// копии Offload не удаляет: для них есть сейф, где оригинал исчезает только после сверки.
public struct CleanupPlanner: Sendable {
    public var now: Date
    /// Восстанавливаемые места: путь → почему их можно удалить.
    public var regenerable: [String: String]
    /// Последнее решение человека по каждому пути.
    public var memory: [String: CleanupAction]
    /// От этого размера большое и давно не менявшееся предлагается убрать в сейф.
    public var bigBytes: Int64 = 1_000_000_000
    public var staleDays: Double = 90
    /// Установщик, скачанный меньше недели назад, может быть ещё не поставлен.
    public var installerDays: Double = 7
    /// Меньше этого (кроме удаляемого) в список не попадает.
    public var minimumBytes: Int64 = 100_000_000

    /// Похоже на установщик. `.iso` сюда не входит: к нему часто подключена виртуальная машина.
    /// Образ `.dmg` может оказаться и личным — поэтому установщик в Корзину сам не предлагается,
    /// только разрешается выбрать, а зашифрованный образ не разрешается вовсе.
    public static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip"]

    public init(now: Date = Date(), regenerable: [String: String] = [:], memory: [String: CleanupAction] = [:]) {
        self.now = now
        self.regenerable = regenerable
        self.memory = memory
    }

    public func suggest(_ item: CleanupObservation) -> CleanupSuggestion {
        let path = item.url.path
        let days = item.modified.map { max(0, now.timeIntervalSince($0)) / 86_400 }
        let regenerableReason = regenerable[path]
        let isInstaller = !item.isDirectory && !item.isEncryptedImage
            && Self.installerExtensions.contains(item.url.pathExtension.lowercased())

        var allowed: [CleanupAction] = []
        if regenerableReason != nil || (isInstaller && (days ?? 0) >= installerDays) { allowed.append(.trash) }
        if regenerableReason == nil, !item.verdict.isBlocked { allowed.append(.safe) }
        if regenerableReason == nil, item.isDirectory, !item.verdict.isBlocked, !item.inBackup { allowed.append(.backup) }
        allowed.append(.keep)

        func make(_ action: CleanupAction, _ reason: String, learned: Bool = false) -> CleanupSuggestion {
            CleanupSuggestion(url: item.url, bytes: item.bytes, modified: item.modified, isDirectory: item.isDirectory,
                              action: action, reason: reason, allowed: allowed, learned: learned, cautions: item.verdict.notes)
        }

        if let remembered = memory[path], allowed.contains(remembered) {
            return make(remembered, "В прошлый раз вы выбрали это же.", learned: true)
        }
        if let regenerableReason { return make(.trash, regenerableReason) }
        if case .blocked(let reason) = item.verdict { return make(.keep, reason) }
        if item.isProject, allowed.contains(.backup) {
            return make(.backup, "Похоже на проект (внутри git): его лучше держать в бэкапе, а не переносить.")
        }
        if item.bytes >= bigBytes, let days, days >= staleDays, item.verdict == .safe {
            return make(.safe, "Большое и давно не менялось — в сейфе не мешает, а вернуть можно в любой момент.")
        }
        if allowed.contains(.trash) {
            return make(.keep, "Похоже на установщик. Если программа уже стоит и его можно скачать снова, выберите «В Корзину».")
        }
        if item.isEncryptedImage {
            return make(.keep, "Зашифрованный образ диска — похоже, в нём ваши данные. Удалить его из разбора нельзя.")
        }
        if let days, days < 30 { return make(.keep, "Менялось недавно — похоже, вы этим пользуетесь.") }
        if item.bytes < bigBytes { return make(.keep, "Места занимает немного.") }
        if case .caution = item.verdict { return make(.keep, "Есть оговорки — решите сами.") }
        return make(.keep, "Менялось не так давно — решите сами.")
    }

    /// Предложения по убыванию пользы: сначала то, что освобождает место, внутри — по размеру.
    public func suggestions(_ items: [CleanupObservation]) -> [CleanupSuggestion] {
        items.map(suggest)
            .filter(isWorthShowing)
            .sorted { lhs, rhs in
                let left = Self.order(lhs.action), right = Self.order(rhs.action)
                return left != right ? left < right : (lhs.bytes, rhs.id) > (rhs.bytes, lhs.id)
            }
    }

    /// Показывать ли предложение: мелочь разбирать дольше, чем она стоит. Удаляемое показывается
    /// с 10 МБ, остальное — со 100 МБ; прошлое решение «убрать» — всегда, человек его ждёт.
    public func isWorthShowing(_ suggestion: CleanupSuggestion) -> Bool {
        suggestion.bytes >= (suggestion.action == .trash ? 10_000_000 : minimumBytes)
            || (suggestion.learned && suggestion.action != .keep)
    }

    static func order(_ action: CleanupAction) -> Int {
        switch action {
        case .trash: return 0
        case .safe: return 1
        case .backup: return 2
        case .keep: return 3
        }
    }

    /// Известные места, которые программы пересоздают сами. Относительно домашней папки.
    public static let regenerableLocations: [(path: String, reason: String)] = [
        ("Library/Developer/Xcode/DerivedData", "Промежуточные файлы сборки Xcode — пересоздаются при следующей сборке."),
        ("Library/Developer/Xcode/iOS DeviceSupport", "Файлы для отладки на iPhone — Xcode скачает их снова, когда понадобятся."),
        ("Library/Developer/CoreSimulator/Caches", "Кеш симулятора iOS — пересоздаётся сам."),
        ("Library/Caches/Homebrew", "Скачанные пакеты Homebrew — brew скачает их снова."),
        ("Library/Caches/pip", "Кеш pip — пакеты скачаются снова."),
        ("Library/Caches/Yarn", "Кеш Yarn — пакеты скачаются снова."),
        (".npm/_cacache", "Кеш npm — пакеты скачаются снова."),
        ("Library/iTunes/iPhone Software Updates", "Прошивки iPhone — Finder скачает нужную снова."),
    ]

    /// Восстанавливаемые места, которые действительно есть у этого человека.
    public static func regenerable(home: URL, fileManager: FileManager = .default) -> [String: String] {
        var result: [String: String] = [:]
        for location in regenerableLocations {
            let url = home.appendingPathComponent(location.path, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) { result[url.path] = location.reason }
        }
        return result
    }

    /// Где искать: содержимое стандартных папок и своих папок в домашней (например, ~/Projects).
    /// ~/Library и скрытые папки целиком не разбираются — там только известные восстанавливаемые места.
    public static func roots(home: URL, fileManager: FileManager = .default) -> [URL] {
        let standard = ["Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures"]
        var roots = standard.map { home.appendingPathComponent($0, isDirectory: true) }
        let own = (try? fileManager.contentsOfDirectory(at: home, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for url in own.sorted(by: { $0.path < $1.path }) {
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), !SafetyRules.standardFolders.contains(name),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            roots.append(url)
        }
        return roots.filter { fileManager.fileExists(atPath: $0.path) }
    }
}
