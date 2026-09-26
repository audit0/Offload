import Foundation

/// Что сделать с объектом при разборе Mac.
public enum CleanupAction: String, Codable, CaseIterable, Sendable, Hashable {
    /// В Корзину. Только то, что пересоздаётся или скачивается заново (кеши сборки, установщики),
    /// и лишние копии одинаковых файлов — одна копия при этом всегда остаётся.
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
    /// Одна из одинаковых копий: SHA-256 содержимого, общий для всей группы.
    public var duplicateGroup: String?

    public init(url: URL, bytes: Int64, modified: Date?, isDirectory: Bool, action: CleanupAction, reason: String,
                allowed: [CleanupAction], learned: Bool, cautions: [String], duplicateGroup: String? = nil) {
        self.url = url
        self.bytes = bytes
        self.modified = modified
        self.isDirectory = isDirectory
        self.action = action
        self.reason = reason
        self.allowed = allowed
        self.learned = learned
        self.cautions = cautions
        self.duplicateGroup = duplicateGroup
    }
}

/// Раскладывает найденное по действиям. Чистая логика: ни диска, ни времени, кроме переданного.
///
/// Удаление здесь — только в Корзину и только для того, что восстанавливается само
/// (кеши сборки, скачанные пакеты) или скачивается заново (установщики). Личные файлы без
/// копии Offload не удаляет: для них есть сейф, где оригинал исчезает только после сверки.
/// Лишняя копия одинакового файла — не исключение из этого правила: копия, которая остаётся,
/// и есть сверенная копия, а перед удалением они ещё раз сравниваются байт в байт.
public struct CleanupPlanner: Sendable {
    public var now: Date
    /// Домашняя папка: от неё считаются Загрузки, Рабочий стол и папки медиатек.
    public var home: URL
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

    public init(now: Date = Date(), home: URL = FileManager.default.homeDirectoryForCurrentUser,
                regenerable: [String: String] = [:], memory: [String: CleanupAction] = [:]) {
        self.now = now
        self.home = home
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
    /// Копии одинаковых файлов идут в конце, группами, в каждой первой — та, что остаётся.
    public func suggestions(_ items: [CleanupObservation], duplicates: [DuplicateGroup] = []) -> [CleanupSuggestion] {
        let top = items.map(suggest)
        var byPath: [String: CleanupSuggestion] = [:]
        for suggestion in top where byPath[suggestion.id] == nil { byPath[suggestion.id] = suggestion }
        var copies: [CleanupSuggestion] = []
        for group in duplicates {
            // Установщик и кеш удаляются по своим правилам (установщик — если так решите вы), и в группе
            // им делать нечего: там последнюю копию удалить было бы нельзя.
            let rest = group.copies.filter { byPath[$0.url.path]?.allowed.contains(.trash) != true }
            guard rest.count > 1 else { continue }
            copies += duplicateSuggestions(DuplicateGroup(id: group.id, bytes: group.bytes, copies: rest), topLevel: byPath)
        }
        // Файл, который оказался одной из копий, показывается в своей группе, а не отдельной строкой.
        let taken = Set(copies.map(\.id))
        return top.filter { !taken.contains($0.id) }
            .filter(isWorthShowing)
            .sorted { lhs, rhs in
                let left = Self.order(lhs.action), right = Self.order(rhs.action)
                return left != right ? left < right : (lhs.bytes, rhs.id) > (rhs.bytes, lhs.id)
            } + copies
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

// MARK: - Одинаковые файлы

extension CleanupPlanner {
    /// Папки, где файлы лежат по путям, записанным в медиатеке приложения. Копию отсюда
    /// не удаляем, даже если такая же есть в Загрузках: «Музыка» или «TV» потеряют трек или фильм.
    public static let managedFolders = ["Music/Music", "Music/iTunes", "Music/GarageBand", "Music/Audio Music Apps", "Movies/TV"]
    /// Куда файлы попадают мимоходом: скачали, сохранили на минутку. Лишняя копия — скорее отсюда.
    public static let transientFolders: Set<String> = ["Downloads", "Desktop"]

    /// Похоже ли имя на копию: «Отчёт (1).pdf», «Отчёт копия.pdf», «Отчёт 2.pdf», «Отчёт-1.pdf».
    public static func looksLikeCopy(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        return [#"\s?\(\d+\)$"#, #"\s(copy|копия)(\s\d+)?$"#, #"\s\d{1,2}$"#, #"-\d{1,2}$"#].contains {
            stem.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Почему эту копию удалять нельзя; nil — можно.
    func keepReason(_ copy: DuplicateCopy) -> String? {
        switch copy.verdict {
        case .blocked(let reason): return reason
        case .caution(let notes): return notes.first
        case .safe: break
        }
        if copy.sharesData { return "Клон другой копии: данные у них общие, и удаление места не освободит." }
        if let folder = managedFolder(copy.url) {
            return "Файл медиатеки в ~/\(folder): приложение найдёт его только на этом месте."
        }
        // Как и сами образы в разборе: зашифрованный .dmg — личные данные, к .iso бывает подключена виртуальная машина.
        if copy.isEncryptedImage {
            return "Зашифрованный образ диска — похоже, в нём ваши данные. Удалить его из разбора нельзя."
        }
        if copy.url.pathExtension.lowercased() == "iso" {
            return "Образ .iso: к нему бывает подключена виртуальная машина. Удалить его из разбора нельзя."
        }
        return nil
    }

    func homeRelative(_ url: URL) -> String? {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(home.path + "/") ? String(path.dropFirst(home.path.count + 1)) : nil
    }

    func managedFolder(_ url: URL) -> String? {
        guard let relative = homeRelative(url) else { return nil }
        return Self.managedFolders.first { relative.hasPrefix($0 + "/") }
    }

    func isTransient(_ url: URL) -> Bool {
        guard let first = homeRelative(url)?.split(separator: "/").first else { return false }
        return Self.transientFolders.contains(String(first))
    }

    /// Кому остаться: сначала копиям, которые удалять нельзя, потом лежащим на своём месте
    /// (не в Загрузках и не на Рабочем столе), с именем без «(1)» и появившимся раньше.
    func keeperOrder(_ copies: [DuplicateCopy]) -> [DuplicateCopy] {
        func rank(_ copy: DuplicateCopy) -> (Int, Int, Int, Double, String) {
            (keepReason(copy) == nil ? 1 : 0,
             isTransient(copy.url) ? 1 : 0,
             Self.looksLikeCopy(copy.url.lastPathComponent) ? 1 : 0,
             (copy.created ?? copy.modified)?.timeIntervalSince1970 ?? .greatestFiniteMagnitude,
             copy.url.path)
        }
        return copies.sorted { rank($0) < rank($1) }
    }

    func keeperReason(_ keeper: DuplicateCopy, others: [DuplicateCopy]) -> String {
        if let reason = keepReason(keeper) { return reason }
        if !isTransient(keeper.url), others.contains(where: { isTransient($0.url) }) {
            return "Лежит на своём месте, а не в Загрузках или на Рабочем столе, — эта копия остаётся."
        }
        if !Self.looksLikeCopy(keeper.url.lastPathComponent), others.contains(where: { Self.looksLikeCopy($0.url.lastPathComponent) }) {
            return "Имя без «(1)» и «копия» — похоже на оригинал, он остаётся."
        }
        if let date = keeper.created ?? keeper.modified,
           others.allSatisfy({ ($0.created ?? $0.modified).map { $0 > date } ?? true }) {
            return "Появилась раньше остальных — похоже на оригинал, он остаётся."
        }
        return "Одна копия остаётся — эта."
    }

    /// Строки одной группы: первая — копия, которая остаётся, остальные — лишние.
    /// Если удалить нельзя ни одну (медиатека, клоны), группа не показывается вовсе.
    func duplicateSuggestions(_ group: DuplicateGroup, topLevel: [String: CleanupSuggestion]) -> [CleanupSuggestion] {
        let ordered = keeperOrder(group.copies)
        guard ordered.contains(where: { keepReason($0) == nil }) else { return [] }
        var result = ordered.enumerated().map { index, copy -> CleanupSuggestion in
            let top = topLevel[copy.url.path]
            let reasonToKeep = keepReason(copy)
            var allowed: [CleanupAction] = reasonToKeep == nil ? [.trash] : []
            // Большой старый файл правила предлагают убрать в сейф — это можно и копии из группы.
            if top?.allowed.contains(.safe) == true { allowed.append(.safe) }
            allowed.append(.keep)
            var action: CleanupAction
            var reason: String
            if index == 0 {
                action = top?.action == .safe ? .safe : .keep
                reason = keeperReason(copy, others: Array(ordered.dropFirst()))
            } else if let reasonToKeep {
                action = .keep
                reason = reasonToKeep
            } else {
                action = .trash
                reason = "Лишняя копия: содержимое то же, что у копии, которая остаётся."
            }
            var learned = false
            if let remembered = memory[copy.url.path], allowed.contains(remembered) {
                action = remembered
                reason = "В прошлый раз вы выбрали это же."
                learned = true
            }
            return CleanupSuggestion(url: copy.url, bytes: copy.allocated, modified: copy.modified, isDirectory: false,
                                     action: action, reason: reason, allowed: allowed, learned: learned,
                                     cautions: top?.cautions ?? copy.verdict.notes, duplicateGroup: group.id)
        }
        // Прошлые решения не должны отправить в Корзину все копии разом.
        if result.allSatisfy({ $0.action == .trash }) {
            result[0].action = .keep
            result[0].reason = keeperReason(ordered[0], others: Array(ordered.dropFirst()))
            result[0].learned = false
        }
        return result
    }

    /// Папка из списка, внутри которой лежит объект: копия внутри папки, уезжающей в сейф, едет вместе с ней.
    public static func container(of suggestion: CleanupSuggestion, in suggestions: [CleanupSuggestion]) -> CleanupSuggestion? {
        suggestions.first { $0.isDirectory && $0.duplicateGroup == nil && suggestion.id.hasPrefix($0.id + "/") }
    }

    /// Что можно выбрать для копии: последнюю остающуюся копию группы убрать в Корзину нельзя.
    /// `effective` — что станет с копией при выполнении.
    public static func options(for copy: CleanupSuggestion, in group: [CleanupSuggestion],
                               effective: (CleanupSuggestion) -> CleanupAction) -> [CleanupAction] {
        let othersStay = group.contains { $0.id != copy.id && effective($0) != .trash }
        return othersStay ? copy.allowed : copy.allowed.filter { $0 != .trash }
    }

    /// С чем сверить копию перед удалением: другая копия той же группы, которая остаётся, —
    /// лучше та, что остаётся на месте.
    public static func reference(for copy: CleanupSuggestion, in group: [CleanupSuggestion],
                                 effective: (CleanupSuggestion) -> CleanupAction) -> CleanupSuggestion? {
        let staying = group.filter { $0.id != copy.id && effective($0) != .trash }
        return staying.first { effective($0) == .keep } ?? staying.first
    }
}
