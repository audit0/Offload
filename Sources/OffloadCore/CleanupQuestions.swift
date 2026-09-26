import Foundation

/// Вопрос после разбора: одно «да» или «нет» на целую группу найденного. Человек не выбирает
/// по файлам и не ходит по папкам — Offload сам собирает, что можно убрать, и спрашивает разрешения.
public struct CleanupQuestion: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Найденное разбором: мусор, лишние копии, установщики, крупное и старое, проекты.
        case module(CleanupModule)
        /// Кеш сборки и образы Docker без имени (остатки пересборок).
        case docker
    }

    public var kind: Kind
    public var id: Kind { kind }
    /// С чем что-то произойдёт при «да». У Docker пусто.
    public var items: [CleanupSuggestion]
    /// Копии, которые остаются: с ними лишние сверяются перед удалением.
    public var keepers: [CleanupSuggestion]
    /// Сколько освободится на Mac. Бэкап места на Mac не освобождает — у проектов ноль.
    public var bytes: Int64
    /// Что уберёт Docker и сколько каждого (0 — Docker не сообщает размер, как у образов без имени).
    public var docker: [DockerPruneTarget: Int64]
    /// Найдено, но в вопрос не вошло, — и почему (кеш открытой программы).
    public var notes: [String]

    public init(kind: Kind, items: [CleanupSuggestion] = [], keepers: [CleanupSuggestion] = [], bytes: Int64,
                docker: [DockerPruneTarget: Int64] = [:], notes: [String] = []) {
        self.kind = kind
        self.items = items
        self.keepers = keepers
        self.bytes = bytes
        self.docker = docker
        self.notes = notes
    }

    /// Что будет сделано при «да».
    public var action: CleanupAction {
        switch kind {
        case .module(let module): return module.action
        case .docker: return .trash
        }
    }

    /// Отвечается вместе со всеми по «Разрешить всё». Установщики — нет: удалить их решает человек,
    /// глядя на список (правило владельца), поэтому только отдельным «да» на их вопрос.
    public var answeredTogether: Bool {
        kind != .module(.installers)
    }

    /// Короткие названия того, что в вопросе, для одной строки: «Кеш npm», «Отпуск 2023.mov».
    public var labels: [String] {
        switch kind {
        case .module(.junk):
            return items.map { item in
                let known = CleanupPlanner.regenerableLocations.first { item.url.path.hasSuffix("/" + $0.path) }
                return known?.reason.components(separatedBy: " — ").first ?? item.url.lastPathComponent
            }
        case .module:
            return items.map(\.url.lastPathComponent)
        case .docker:
            return []
        }
    }
}

public enum CleanupQuestions {
    /// О Docker спрашиваем, если он отдаст хотя бы столько.
    public static let dockerMinimumBytes: Int64 = 100_000_000
    /// Что убирает Docker по «да»: только то, что точно не нужно. Все неиспользуемые образы — нет:
    /// собранный человеком и никуда не отправленный образ не скачать заново. Остановленных
    /// контейнеров тоже нет: в них бывают данные без тома.
    public static let dockerTargets: [DockerPruneTarget] = [.buildCache, .danglingImages]

    /// Вопросы в том порядке, в котором их задавать: сначала то, что пересоздаётся само, потом личное.
    /// Виртуальные машины UTM здесь не удаляются: удалять и переносить их нужно в самом UTM,
    /// иначе он их потеряет (см. «Освободить место» → «Как освободить…»).
    public static func build(_ suggestions: [CleanupSuggestion], docker: DockerUsage? = nil) -> [CleanupQuestion] {
        func found(_ module: CleanupModule) -> [CleanupSuggestion] { suggestions.filter { $0.module == module } }
        func total(_ items: [CleanupSuggestion]) -> Int64 { items.reduce(0) { $0 + $1.bytes } }
        var questions: [CleanupQuestion] = []

        // Мусор. Кеш открытой программы в вопрос не входит — о нём заметка, чтобы было понятно почему.
        let junk = found(.junk)
        let removable = junk.filter { $0.action == .trash }
        if !removable.isEmpty {
            questions.append(CleanupQuestion(kind: .module(.junk), items: removable, bytes: total(removable),
                                             notes: junk.filter { $0.action == .keep && !$0.learned && !$0.habit }.map(\.reason)))
        }

        if let docker {
            var parts: [DockerPruneTarget: Int64] = [:]
            for target in dockerTargets {
                // Образы без имени: сколько они занимают, docker system df не сообщает, а чистить их надо всё равно.
                if target == .danglingImages { parts[target] = 0; continue }
                if let bytes = docker.part(target)?.reclaimable, bytes > 0 { parts[target] = bytes }
            }
            let bytes = parts.values.reduce(0, +)
            if bytes >= dockerMinimumBytes { questions.append(CleanupQuestion(kind: .docker, bytes: bytes, docker: parts)) }
        }

        // Лишние копии. Копия внутри папки, которую можно убрать в сейф, едет вместе с папкой:
        // удалить её отдельно значило бы поменять папку перед самым переносом.
        let safe = found(.safe).filter { $0.action == .safe }
        let copies = suggestions.filter { $0.duplicateGroup != nil }
        let redundant = copies.filter { $0.action == .trash && CleanupPlanner.container(of: $0, in: safe) == nil }
        if !redundant.isEmpty {
            let groups = Set(redundant.compactMap(\.duplicateGroup))
            questions.append(CleanupQuestion(kind: .module(.duplicates), items: redundant,
                                             keepers: copies.filter { $0.action != .trash && groups.contains($0.duplicateGroup ?? "") },
                                             bytes: total(redundant)))
        }

        // Установщики — все старые, кроме тех, что вы уже возвращали из Корзины.
        let installers = found(.installers).filter { $0.allowed.contains(.trash) && !($0.action == .keep && ($0.learned || $0.habit)) }
        if !installers.isEmpty {
            questions.append(CleanupQuestion(kind: .module(.installers), items: installers, bytes: total(installers)))
        }

        if !safe.isEmpty { questions.append(CleanupQuestion(kind: .module(.safe), items: safe, bytes: total(safe))) }

        let projects = found(.projects).filter { $0.action == .backup }
        if !projects.isEmpty { questions.append(CleanupQuestion(kind: .module(.projects), items: projects, bytes: 0)) }
        return questions
    }
}
