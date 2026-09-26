import Foundation

/// Чем объект запомнился: признаки, по которым решения человека переносятся на похожее.
/// Считаются из пути, размера и дат — одинаково для прошлых решений и для новых предложений.
public struct DecisionFeatures: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case folder, project, file, copy
    }

    public enum Category: String, Sendable, Hashable, CaseIterable {
        case video, audio, image, archive, installer, document, other
    }

    /// Меньше 100 МБ, до 1 ГБ, до 10 ГБ, больше.
    public enum Size: Int, Sendable, Hashable, CaseIterable {
        case small, medium, large, huge
    }

    /// Когда менялось к моменту решения: за месяц, за три месяца, за год, давнее.
    public enum Age: Int, Sendable, Hashable, CaseIterable {
        case fresh, recent, old, ancient, unknown
    }

    public var kind: Kind
    /// У файла — по расширению. У папки nil: что внутри, без обхода не узнать.
    public var category: Category?
    /// Первая папка под домашней: «Downloads», «Movies», «Projects»…
    public var place: String
    public var size: Size
    public var age: Age

    public init(kind: Kind, category: Category?, place: String, size: Size, age: Age) {
        self.kind = kind
        self.category = category
        self.place = place
        self.size = size
        self.age = age
    }

    public static func of(path: String, home: URL, kind: Kind, bytes: Int64, modified: Date?, at date: Date) -> DecisionFeatures {
        let base = home.standardizedFileURL.path
        let place = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1).prefix { $0 != "/" }) : ""
        let size: Size = bytes < 100_000_000 ? .small : bytes < 1_000_000_000 ? .medium : bytes < 10_000_000_000 ? .large : .huge
        let age: Age
        if let modified {
            let days = date.timeIntervalSince(modified) / 86_400
            age = days < 30 ? .fresh : days < 90 ? .recent : days < 365 ? .old : .ancient
        } else {
            age = .unknown
        }
        let category = kind == .folder || kind == .project ? nil : Self.category(of: (path as NSString).lastPathComponent)
        return DecisionFeatures(kind: kind, category: category, place: place, size: size, age: age)
    }

    static let extensions: [Category: Set<String>] = [
        .video: ["mov", "mp4", "m4v", "mkv", "avi", "wmv", "webm", "mts", "m2ts", "3gp", "flv", "mpg", "mpeg"],
        .audio: ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "wma"],
        .image: ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "psd", "raw", "dng",
                 "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"],
        .archive: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst"],
        .installer: ["dmg", "pkg", "mpkg", "xip", "iso", "img"],
        .document: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf",
                    "md", "epub", "odt", "ods", "csv"],
    ]

    public static func category(of name: String) -> Category {
        let ext = (name as NSString).pathExtension.lowercased()
        return extensions.first { $0.value.contains(ext) }?.key ?? .other
    }
}

/// Привычки человека: что он обычно выбирает для похожего. Учится на решениях из базы,
/// работает только на этом Mac и не гадает на пустом месте: пока похожих решений меньше трёх
/// или они расходятся, решают правила. Разрешено ли действие, решают тоже правила — привычка
/// не предложит удалить то, что удалять нельзя.
///
/// Похожесть — от строгой к широкой: сначала то же место, вид, размер и давность, потом без давности,
/// потом без размера. Берётся самая строгая ступень, где решений хватает; если на ней они расходятся,
/// более широкая не спасает — там к тем же решениям просто подмешаны менее похожие.
public struct HabitModel: Sendable {
    public struct Example: Sendable, Hashable {
        public var features: DecisionFeatures
        public var action: CleanupAction

        public init(features: DecisionFeatures, action: CleanupAction) {
            self.features = features
            self.action = action
        }
    }

    public struct Prediction: Sendable, Hashable {
        public var action: CleanupAction
        /// Сколько похожих решений за это действие и сколько их всего.
        public var agreeing: Int
        public var total: Int
        /// Что сочтено похожим, по-человечески: «видео в «Загрузках» от 1 до 10 ГБ».
        public var scope: String

        /// Причина для строки предложения.
        public var reason: String {
            "Похожее вы обычно \(Self.verb(action)) (\(agreeing) из \(total)): \(scope)."
        }

        /// «Оставляете», «убираете в сейф»…
        public static func verb(_ action: CleanupAction) -> String {
            switch action {
            case .trash: return "удаляете"
            case .safe: return "убираете в сейф"
            case .backup: return "добавляете в бэкап"
            case .keep: return "оставляете"
            }
        }
    }

    /// Ступени похожести, от строгой к широкой.
    enum Level: CaseIterable {
        case exact, sized, placed

        /// Признаки, которые на этой ступени не различаются, заменены одним значением.
        func key(_ features: DecisionFeatures) -> DecisionFeatures {
            var key = features
            if self != .exact { key.age = .unknown }
            if self == .placed { key.size = .small }
            return key
        }
    }

    public var minimumSupport = 3
    public var minimumShare = 0.75
    /// На скольких решениях модель учится.
    public private(set) var count = 0
    private var counts: [Level: [DecisionFeatures: [CleanupAction: Int]]] = [:]

    /// Модель по истории решений: каждый объект — одно последнее решение, и только если это выбор человека.
    public init(history: [DecisionStore.Decision], home: URL) {
        self.init(examples: history.filter(\.isChoice).map { Example(features: $0.features(home: home), action: $0.action) })
    }

    public init(examples: [Example]) {
        count = examples.count
        for level in Level.allCases {
            var table: [DecisionFeatures: [CleanupAction: Int]] = [:]
            for example in examples { table[level.key(example.features), default: [:]][example.action, default: 0] += 1 }
            counts[level] = table
        }
    }

    public var isEmpty: Bool { counts[.exact]?.isEmpty ?? true }

    /// Что человек, судя по похожему, выберет сам. nil — похожих мало, они расходятся или
    /// их действие для этого объекта не разрешено.
    public func predict(_ features: DecisionFeatures, allowed: [CleanupAction]) -> Prediction? {
        for level in Level.allCases {
            let key = level.key(features)
            guard let votes = counts[level]?[key] else { continue }
            let total = votes.values.reduce(0, +)
            guard total >= minimumSupport else { continue }
            return decided(votes, total: total, scope: Self.scope(key, level: level)).flatMap { allowed.contains($0.action) ? $0 : nil }
        }
        return nil
    }

    /// Всё, чему модель научилась, — на широкой ступени, самые подкреплённые сначала.
    public func habits(limit: Int = 6) -> [Prediction] {
        let table = counts[.placed] ?? [:]
        return table.compactMap { key, votes in decided(votes, total: votes.values.reduce(0, +), scope: Self.scope(key, level: .placed)) }
            .filter { $0.total >= minimumSupport }
            .sorted { lhs, rhs in
                (lhs.agreeing, lhs.total) != (rhs.agreeing, rhs.total) ? (lhs.agreeing, lhs.total) > (rhs.agreeing, rhs.total) : lhs.scope < rhs.scope
            }
            .prefix(limit).map { $0 }
    }

    private func decided(_ votes: [CleanupAction: Int], total: Int, scope: String) -> Prediction? {
        guard let top = votes.max(by: { ($0.value, $0.key.rawValue) < ($1.value, $1.key.rawValue) }),
              Double(top.value) / Double(total) >= minimumShare else { return nil }
        return Prediction(action: top.key, agreeing: top.value, total: total, scope: scope)
    }

    // MARK: - Слова

    static func scope(_ key: DecisionFeatures, level: Level) -> String {
        var parts = [noun(key), place(key.place)].filter { !$0.isEmpty }
        if level != .placed { parts.append(size(key.size)) }
        var text = parts.joined(separator: " ")
        if level == .exact, let age = age(key.age) { text += ", \(age)" }
        return text
    }

    static func noun(_ key: DecisionFeatures) -> String {
        switch key.kind {
        case .folder: return "папки"
        case .project: return "проекты с git"
        case .copy:
            // У копий вид файла тоже различается: копии видео и копии документов — разные привычки.
            switch key.category ?? .other {
            case .video: return "копии видео"
            case .audio: return "копии музыки и звука"
            case .image: return "копии фото и картинок"
            case .archive: return "копии архивов"
            case .installer: return "копии образов дисков и установщиков"
            case .document: return "копии документов"
            case .other: return "копии файлов"
            }
        case .file:
            switch key.category ?? .other {
            case .video: return "видео"
            case .audio: return "музыка и звук"
            case .image: return "фото и картинки"
            case .archive: return "архивы"
            case .installer: return "образы дисков и установщики"
            case .document: return "документы"
            case .other: return "файлы"
            }
        }
    }

    static let placeNames = [
        "Downloads": "в «Загрузках»", "Desktop": "на «Рабочем столе»", "Documents": "в «Документах»",
        "Movies": "в «Фильмах»", "Music": "в «Музыке»", "Pictures": "в «Изображениях»", "Library": "в «Библиотеке»",
    ]

    static func place(_ name: String) -> String {
        name.isEmpty ? "" : placeNames[name] ?? "в «~/\(name)»"
    }

    static func size(_ size: DecisionFeatures.Size) -> String {
        switch size {
        case .small: return "меньше 100 МБ"
        case .medium: return "от 100 МБ до 1 ГБ"
        case .large: return "от 1 до 10 ГБ"
        case .huge: return "больше 10 ГБ"
        }
    }

    static func age(_ age: DecisionFeatures.Age) -> String? {
        switch age {
        case .fresh: return "менялись в последний месяц"
        case .recent: return "менялись 1–3 месяца назад"
        case .old: return "не менялись от 3 месяцев до года"
        case .ancient: return "не менялись больше года"
        case .unknown: return nil
        }
    }
}

extension DecisionStore.Decision {
    /// Выбор человека, а не согласие с предложенным по умолчанию. «Оставить» считается, только если
    /// предлагалось другое: оставляемое показывается свёрнутым, и строку человек мог и не видеть.
    /// У решений, записанных до того, как Offload стал запоминать предложенное, «оставить» не считается.
    public var isChoice: Bool {
        action != .keep || (suggested.map { $0 != .keep } ?? false)
    }

    /// Признаки объекта на момент решения. У решений, записанных до того, как Offload стал запоминать
    /// вид объекта, вид угадывается по имени: без расширения — скорее папка.
    public func features(home: URL) -> DecisionFeatures {
        let kind = self.kind ?? ((path as NSString).pathExtension.isEmpty ? .folder : .file)
        return DecisionFeatures.of(path: path, home: home, kind: kind, bytes: bytes, modified: modified, at: decidedAt)
    }
}
