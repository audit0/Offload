import AppKit
import OffloadCore
import SwiftUI

extension Importance {
    var groupTitle: String {
        switch self {
        case .junk: return "Мусор"
        case .minor: return "Менее важно"
        case .important: return "Важно"
        }
    }

    var tone: Tone {
        switch self {
        case .important: return .good
        case .minor: return .caution
        case .junk: return .neutral
        }
    }
}

/// Раздел «Помощник»: выбрать папку, спросить — и увидеть, что в ней важно, что менее важно, а что мусор.
/// У каждого совета — кнопка, которая делает то же, что и без помощника: перенос со сверкой или Корзина с возвратом.
struct AssistantView: View {
    @Environment(AppModel.self) private var app
    @State private var question = ""
    @State private var apiKey = ""
    /// Перенос в сейф: тот же лист, что в «Освободить место».
    @State private var moving: Target?
    @State private var moved = false
    @State private var trashing: Target?
    @State private var trashProblem: String?

    struct Target: Identifiable {
        let id: String
        let item: SpaceItem
    }

    var body: some View {
        let model = app.assistant
        PageScroll {
            VStack(alignment: .leading, spacing: 8) {
                Text("Помощник").font(Theme.display(30))
                Text("Смотрит на папку и говорит, что в ней важно, что менее важно, а что мусор. Сам ничего не удаляет и не переносит — только советует, а решаете вы.")
                    .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if !model.consent {
                consentCard
            } else {
                providerCard
                if model.problem == nil || Demo.isOn {
                    askCard
                    if let error = model.error { Notice(.error, error) }
                    if let answer = model.answer { answerSection(answer) }
                }
            }
        }
        .navigationTitle("Помощник")
        .task(id: model.kind) { await model.check(app: app) }
        .task {
            // Снимки для README показывают ответ: в демонстрации он вымышленный и без сети.
            if Demo.isOn, ProcessInfo.processInfo.environment["OFFLOAD_SNAPSHOT_DIR"] != nil, model.answer == nil, !model.isBusy {
                model.run(app.rules.home.appendingPathComponent("Downloads", isDirectory: true), question: "", app: app)
            }
        }
        .sheet(item: $moving, onDismiss: {
            guard moved else { return }
            moved = false
            app.space.invalidateAll()
            app.refreshVolumes()
            app.history.reload(volumes: app.historyVolumes)
        }) { target in
            MoveSheet(source: target.item.url, onMoved: {
                moved = true
                app.assistant.markDone(target.id, "в сейфе")
            })
        }
        .confirmationDialog(trashing.map { "Отправить «\($0.item.url.lastPathComponent)» в Корзину?" } ?? "",
                            isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
                            presenting: trashing) { target in
            Button("В Корзину", role: .destructive) {
                Task { trashProblem = await app.assistant.trash(target.id, app: app) }
            }
            Button("Отмена", role: .cancel) {}
        } message: { target in
            Text("\(Format.bytes(target.item.bytes)). Вернуть можно из Корзины, пока её не очистили.")
        }
        .alert("Не получилось", isPresented: Binding(get: { trashProblem != nil }, set: { if !$0 { trashProblem = nil } })) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(trashProblem ?? "")
        }
    }

    // MARK: - Согласие

    private var consentCard: some View {
        Card(spacing: 12) {
            CardTitle("Что уходит помощнику", systemImage: "hand.raised")
            Text("Имена и пути файлов и папок от домашней папки, их размеры и даты, пометки правил Offload, несколько имён внутри папок и начало небольших текстовых файлов — до 20 строк. Файлы с ключами, токенами и паролями не читаются никогда, а ключи, найденные в других файлах, вырезаются. Файлы, которые лежат только в iCloud, не скачиваются и не читаются. Фото, видео и документы целиком никуда не уходят.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Куда — выбираете вы: Claude от Anthropic через Claude Code на этом Mac или по вашему ключу API, сервер OffLoadAI (он передаёт вопрос Claude и ничего не хранит) — или локальная модель, и тогда сведения не покидают Mac вовсе. Остальной Offload по-прежнему работает без сети; помощник выходит в сеть, только когда вы его спрашиваете.")
                .font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Button("Согласен, включить помощника") { app.assistant.consent = true }
                .prominentButton()
                .padding(.top, 4)
        }
    }

    // MARK: - Где думает

    private var providerCard: some View {
        let model = app.assistant
        @Bindable var bindable = model
        return Card(spacing: 12) {
            CardTitle("Где думает помощник", systemImage: "cpu")
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(AssistantModel.Kind.allCases) { kind in
                    if kind == model.kind {
                        Button(kind.title) { model.kind = kind }.prominentButton()
                    } else {
                        Button(kind.title) { model.kind = kind }
                    }
                }
            }
            .disabled(model.isBusy)
            Text(model.kind.detail)
                .font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if model.kind == .apiKey, !Demo.isOn {
                if model.hasApiKey {
                    HStack(spacing: 10) {
                        Label("Ключ сохранён в связке ключей.", systemImage: "key.fill").font(.callout)
                        Spacer(minLength: 8)
                        Button("Убрать ключ") {
                            model.saveApiKey(nil)
                            Task { await model.check(app: app) }
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        SecureField("sk-ant-…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        Button("Сохранить ключ") {
                            model.saveApiKey(apiKey)
                            apiKey = ""
                            Task { await model.check(app: app) }
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            if model.kind == .local, !model.localModels.isEmpty {
                Picker("Модель", selection: Binding(get: { OllamaAssistant.choose(from: model.localModels, preferred: model.localModel) ?? "" },
                                                    set: { bindable.localModel = $0 })) {
                    ForEach(model.localModels, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 320)
                .disabled(model.isBusy)
            }
            if let problem = model.problem, !Demo.isOn {
                Notice(.warning, problem)
                Button("Проверить снова") { Task { await model.check(app: app) } }
                    .disabled(model.isChecking)
            }
        }
    }

    // MARK: - Вопрос

    private var places: [(title: String, url: URL)] {
        let home = app.rules.home
        return [("Загрузки", "Downloads"), ("Рабочий стол", "Desktop"), ("Документы", "Documents"), ("Фильмы", "Movies")]
            .map { ($0.0, home.appendingPathComponent($0.1, isDirectory: true)) } + [("Домашняя папка", home)]
    }

    private var askCard: some View {
        let model = app.assistant
        return Card(spacing: 12) {
            CardTitle("Какую папку разобрать", systemImage: "folder")
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(places, id: \.title) { place in
                    Button(place.title) { model.run(place.url, question: question, app: app) }
                }
                Button("Другая папка…", action: chooseFolder)
            }
            .disabled(model.isBusy)
            TextField("Вопрос помощнику (необязательно): например, «что из этого можно удалить?»", text: $question)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isBusy)
            if model.isBusy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.status ?? "").font(.callout).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Отменить") { model.cancel() }
                }
            } else if let folder = model.folder, model.answer != nil {
                Button("Спросить ещё раз про «\(title(of: folder))»") { model.run(folder, question: question, app: app) }
            }
        }
    }

    /// «Загрузки», а не «Downloads»: так папка названа и в кнопках выше.
    private func title(of folder: URL) -> String {
        places.first { $0.url.standardizedFileURL.path == folder.standardizedFileURL.path }?.title ?? folder.lastPathComponent
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = app.rules.home
        panel.message = "Какую папку разобрать с помощником"
        panel.prompt = "Разобрать"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.assistant.run(url, question: question, app: app)
    }

    // MARK: - Ответ

    @ViewBuilder
    private func answerSection(_ answer: AssistantAnswer) -> some View {
        let model = app.assistant
        if !answer.summary.isEmpty {
            Card(spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(systemImage: "lightbulb.fill", size: 32)
                    Text(answer.summary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                Text("Ответил: \(answer.provider)\(answer.costUSD.map { String(format: " · $%.2f", $0) } ?? ""). Помощник может ошибаться — решение за вами.")
                    .font(.caption).foregroundStyle(Theme.muted)
                    .padding(.leading, 44)
            }
        }
        ForEach([Importance.junk, .minor, .important], id: \.self) { importance in
            let group = answer.items.filter { $0.importance == importance }
                .sorted { (model.item($0.id)?.bytes ?? 0) > (model.item($1.id)?.bytes ?? 0) }
            if !group.isEmpty {
                let bytes = group.reduce(Int64(0)) { $0 + (model.item($1.id)?.bytes ?? 0) }
                CardSection(title: "\(importance.groupTitle) — \(group.count), \(Format.bytes(bytes))") {
                    ForEach(group) { advice in
                        row(advice)
                        if advice.id != group.last?.id { RowDivider(inset: 54) }
                    }
                }
            }
        }
    }

    private func row(_ advice: Advice) -> some View {
        let model = app.assistant
        let item = model.item(advice.id)
        return HStack(alignment: .top, spacing: 12) {
            IconTile(systemImage: item?.isDirectory == true ? "folder.fill" : "doc.fill", tone: advice.importance.tone)
            VStack(alignment: .leading, spacing: 3) {
                Text(item?.url.lastPathComponent ?? advice.id).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text(advice.reason).font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if let overruled = advice.overruled {
                    Label(overruled, systemImage: "hand.raised")
                        .font(.caption).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if let item {
                Text(Format.bytes(item.bytes)).font(.callout).foregroundStyle(Theme.muted).monospacedDigit()
                    .frame(minWidth: 64, alignment: .trailing)
                    .padding(.top, 2)
            }
            action(advice, item: item)
                .frame(minWidth: 96, alignment: .trailing)
        }
        .rowPadding()
        .contextMenu {
            if let item { Button("Показать в Finder") { revealInFinder(item.url) } }
        }
    }

    @ViewBuilder
    private func action(_ advice: Advice, item: SpaceItem?) -> some View {
        let model = app.assistant
        if let outcome = model.done[advice.id] {
            Label(outcome, systemImage: "checkmark").font(.callout).foregroundStyle(Theme.ok)
        } else if let item, advice.action != .keep {
            if advice.action == .safe {
                Button("В сейф…") {
                    if Demo.isOn { model.markDone(advice.id, "в сейфе") } else { moving = Target(id: advice.id, item: item) }
                }
                .controlSize(.small)
                .help("Перенос со сверкой каждого файла; вернуть можно в «Перенесённом»")
            } else {
                Button("В Корзину") { trashing = Target(id: advice.id, item: item) }
                    .controlSize(.small)
                    .help("Вернуть можно из Корзины, пока её не очистили")
            }
        } else {
            Text("оставить").font(.caption).foregroundStyle(Theme.faint).padding(.top, 3)
        }
    }
}
