import AppKit
import Foundation
import Observation
import OffloadCore

/// AI-помощник по файлам: смотрит на содержимое папки и говорит, что важно, что менее важно, а что мусор.
/// Сам ничего не делает — каждый совет выполняет человек, теми же путями, что и без помощника.
@MainActor
@Observable
final class AssistantModel {
    enum Stage { case idle, scanning, thinking, done, failed }

    /// Где думает помощник — по порядку: Claude Code на Mac, ключ API, локальная модель, сервер OffLoadAI.
    enum Kind: String, CaseIterable, Identifiable {
        case claudeCode, apiKey, local, server

        var id: Self { self }

        var title: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .apiKey: return "Ключ API"
            case .local: return "На этом Mac"
            case .server: return "Сервер OffLoadAI"
            }
        }

        var detail: String {
            switch self {
            case .claudeCode: return "Claude Code, установленный на этом Mac, под вашей учётной записью Claude. Ключ не нужен."
            case .apiKey: return "Ваш ключ Anthropic API: платите по счёту API за каждый вопрос. Ключ хранится в связке ключей macOS."
            case .local: return "Модель в Ollama на этом Mac: сведения о файлах не покидают его. Медленнее и проще, чем Claude."
            case .server: return "Сервер OffLoadAI передаёт вопрос Claude и ничего не хранит. Входит в OffLoadAI Pro — ни Claude Code, ни ключа не нужно."
            }
        }
    }

    private static let consentKey = "assistant.consent"
    private static let kindKey = "assistant.provider"
    private static let localModelKey = "assistant.ollamaModel"
    private static let serverKey = "assistant.server"

    private(set) var stage: Stage = .idle
    var isBusy: Bool { stage == .scanning || stage == .thinking }
    private(set) var status: String?
    private(set) var error: String?
    private(set) var answer: AssistantAnswer?
    /// Папка, которую разбирали последней.
    private(set) var folder: URL?

    /// Готов ли выбранный вариант: nil — готов; иначе что сделать, одной фразой.
    private(set) var problem: String?
    private(set) var isChecking = false
    /// Модели, установленные в Ollama, — для выбора.
    private(set) var localModels: [String] = []
    private(set) var hasApiKey = AssistantKeychain.exists

    var kind: Kind = Kind(rawValue: UserDefaults.standard.string(forKey: kindKey) ?? "") ?? .claudeCode {
        didSet {
            guard kind != oldValue else { return }
            if !Demo.isOn { UserDefaults.standard.set(kind.rawValue, forKey: Self.kindKey) }
            error = nil
        }
    }

    /// Человек согласился, что сведения о файлах уходят модели. Без этого помощник не запускается.
    var consent: Bool = Demo.isOn || UserDefaults.standard.bool(forKey: consentKey) {
        didSet { if !Demo.isOn { UserDefaults.standard.set(consent, forKey: Self.consentKey) } }
    }

    var localModel: String? = UserDefaults.standard.string(forKey: localModelKey) {
        didSet { if !Demo.isOn { UserDefaults.standard.set(localModel, forKey: Self.localModelKey) } }
    }

    /// Объект по номеру из ответа — настоящий путь, а не тот, что видел помощник.
    @ObservationIgnored private var items: [String: SpaceItem] = [:]
    func item(_ id: String) -> SpaceItem? { items[id] }

    /// Что уже сделано по совету: «в Корзине», «в сейфе».
    private(set) var done: [String: String] = [:]
    func markDone(_ id: String, _ outcome: String) { done[id] = outcome }

    @ObservationIgnored private var task: Task<Void, Never>?

    func saveApiKey(_ key: String?) {
        guard !Demo.isOn else { return }
        if !AssistantKeychain.save(key) {
            error = "Не удалось сохранить ключ в связке ключей macOS."
        } else {
            error = nil
        }
        hasApiKey = AssistantKeychain.exists
    }

    /// Вариант, который спросят: с тем ключом, моделью и адресом, что выбраны сейчас.
    func provider(app: AppModel) -> any AssistantProvider {
        switch kind {
        case .claudeCode:
            return ClaudeCodeAssistant()
        case .apiKey:
            return ApiKeyAssistant(key: { AssistantKeychain.read() }, hasKey: { AssistantKeychain.exists })
        case .local:
            let chosen = localModel
            return OllamaAssistant(preferredModel: { chosen })
        case .server:
            let license = app.pro.licenseText
            let endpoint = UserDefaults.standard.string(forKey: Self.serverKey)
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            return BotAssistant(client: "offloadai-mac/\(version)", license: { license }, endpoint: { endpoint })
        }
    }

    /// Проверить, готов ли выбранный вариант: есть ли Claude Code, ключ, Ollama с моделью, адрес сервера.
    func check(app: AppModel) async {
        guard !Demo.isOn else {
            problem = nil
            return
        }
        let checking = kind
        isChecking = true
        let found = await provider(app: app).problem()
        let models = checking == .local ? await OllamaAssistant.installed() ?? [] : localModels
        // Пока проверяли, человек мог выбрать другой вариант — тогда ответ уже не про него.
        guard checking == kind else { return }
        problem = found
        localModels = models
        isChecking = false
    }

    func run(_ target: URL, question: String, app: AppModel) {
        guard !isBusy, consent else { return }
        folder = target
        error = nil
        answer = nil
        done = [:]
        stage = .scanning
        status = "Считаю, что лежит в папке…"
        let rules = app.rules
        let asked = provider(app: app)
        task = Task {
            do {
                let measured: [SpaceItem]
                if Demo.isOn {
                    measured = Self.demoDownloads(home: rules.home)
                } else {
                    let children = await Task.detached(priority: .userInitiated) { SpaceScanner.children(of: target) }.value
                    let found = Collector<SpaceItem>()
                    let total = children.count
                    await SpaceScanner.scan(children, rules: rules, isCancelled: { Task.isCancelled }) { item in
                        found.append(item)
                        let count = found.all.count
                        Task { @MainActor in
                            guard self.stage == .scanning else { return }
                            self.status = "Считаю, что лежит в папке… \(count) из \(total)"
                        }
                    }
                    measured = found.all
                }
                try Task.checkCancellation()
                guard !measured.isEmpty else {
                    fail("Папка пуста — разбирать нечего.")
                    return
                }
                let picked = AssistantFacts.pick(measured)
                items = Dictionary(uniqueKeysWithValues: picked.enumerated().map { (String($0.offset + 1), $0.element) })
                let home = rules.home
                let facts = await Task.detached(priority: .userInitiated) { AssistantFacts.build(picked, home: home) }.value
                try Task.checkCancellation()
                stage = .thinking
                status = "Помощник смотрит \(facts.count) \(pluralRu(facts.count, "объект", "объекта", "объектов"))…"
                let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
                answer = Demo.isOn ? Self.demoAnswer(facts) : try await asked.ask(facts, question: trimmed.isEmpty ? nil : trimmed)
                stage = .done
                status = nil
            } catch is CancellationError {
                stage = .idle
                status = nil
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func fail(_ message: String) {
        error = message
        status = nil
        stage = .failed
    }

    func cancel() { task?.cancel() }

    /// В Корзину — вернуть можно, пока Корзина не очищена. Правила OffLoadAI проверяются ещё раз:
    /// помощник мог ошибиться, а объект — измениться с тех пор. Ответ — что помешало (nil — получилось).
    func trash(_ id: String, app: AppModel) async -> String? {
        guard let item = item(id) else { return "Объект не найден." }
        if Demo.isOn {
            markDone(id, "в Корзине")
            return nil
        }
        let verdict = app.rules.pathVerdict(for: item.url)
        guard verdict == .safe else {
            return "Правила OffLoadAI не дают отправить это в Корзину: " + verdict.notes.joined(separator: " ")
        }
        let url = item.url
        // Как и в «Разобрать»: то, что сейчас открыто в программе, на ходу не удаляем.
        if let holders = await Task.detached(priority: .userInitiated, operation: { SafeMover.openFiles(in: url) }).value,
           !holders.isEmpty {
            return "«\(url.lastPathComponent)» сейчас использует \(holders.prefix(3).joined(separator: ", ")). Закройте программу и повторите."
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }.value
            markDone(id, "в Корзине")
            app.space.invalidateAll()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Демонстрация

    /// Вымышленные «Загрузки» для снимков и демонстрации: что там обычно лежит.
    static func demoDownloads(home: URL) -> [SpaceItem] {
        let folder = home.appendingPathComponent("Downloads", isDirectory: true)
        func item(_ name: String, _ gigabytes: Double, daysAgo: Double, isFolder: Bool = false) -> SpaceItem {
            SpaceItem(url: folder.appendingPathComponent(name, isDirectory: isFolder), bytes: Int64(gigabytes * 1_000_000_000),
                      modified: Date().addingTimeInterval(-daysAgo * 86_400), isDirectory: isFolder, accessDenied: false,
                      verdict: .safe, isMeasured: true)
        }
        return [
            item("Отпуск 2023 (1).mp4", 4.1, daysAgo: 380), item("Фото с дачи.zip", 2.3, daysAgo: 410), item("Xcode_16.4.xip", 5.8, daysAgo: 290),
            item("temp-export", 0.8, daysAgo: 200, isFolder: true), item("node-v22.11.0.pkg", 0.03, daysAgo: 320),
            item("googlechrome.dmg", 0.23, daysAgo: 500), item("Договор аренды 2026.pdf", 0.002, daysAgo: 40),
            item("Выписка ЕГРН.pdf", 0.001, daysAgo: 95),
        ]
    }

    /// Ответ для снимков и демонстрации: без сети, по вымышленным «Загрузкам».
    static func demoAnswer(_ facts: [FileFact]) -> AssistantAnswer {
        let advice = facts.map { fact -> Advice in
            switch (fact.path as NSString).lastPathComponent {
            case "Отпуск 2023 (1).mp4":
                return Advice(id: fact.id, importance: .minor, action: .safe, reason: "Видео из отпуска с «(1)» в имени — похоже на повторную загрузку; сохранить стоит, но не на диске Mac.")
            case "Фото с дачи.zip":
                return Advice(id: fact.id, importance: .minor, action: .safe, reason: "Архив с личными фото: нужен, но редко — место ему в сейфе.")
            case "Xcode_16.4.xip":
                return Advice(id: fact.id, importance: .junk, action: .trash, reason: "Архив установки Xcode: скачивается заново с сайта Apple.")
            case "temp-export":
                return Advice(id: fact.id, importance: .junk, action: .trash, reason: "Временная выгрузка, которую давно не открывали.")
            case "node-v22.11.0.pkg", "googlechrome.dmg":
                return Advice(id: fact.id, importance: .junk, action: .trash, reason: "Установщик уже поставленной программы.")
            default:
                return Advice(id: fact.id, importance: .important, action: .keep, reason: "Личный документ — оставить на месте.")
            }
        }
        return AssistantAnswer(summary: "В «Загрузках» почти 7 ГБ мусора — архив Xcode, установщики и старая выгрузка. Видео и архив с фото лучше убрать в сейф, документы оставить.",
                               items: advice, provider: "Демонстрация")
    }
}
