import AppKit
import OffloadCore
import SwiftUI

extension CleanupAction {
    var title: String {
        switch self {
        case .trash: return "В Корзину"
        case .safe: return "В сейф"
        case .backup: return "В бэкап"
        case .keep: return "Оставить"
        }
    }

    var symbol: String {
        switch self {
        case .trash: return "trash.fill"
        case .safe: return "lock.fill"
        case .backup: return "externaldrive.badge.checkmark"
        case .keep: return "pin.fill"
        }
    }

    var tone: Tone {
        switch self {
        case .trash: return .danger
        case .safe: return .good
        case .backup: return .brand
        case .keep: return .neutral
        }
    }
}

extension CleanupModule {
    var title: String {
        switch self {
        case .junk: return "Мусор"
        case .safe: return "Крупное и старое"
        case .duplicates: return "Лишние копии"
        case .installers: return "Установщики"
        case .projects: return "Проекты без бэкапа"
        }
    }

    var symbol: String {
        switch self {
        case .junk: return "trash.fill"
        case .safe: return "lock.shield.fill"
        case .duplicates: return "doc.on.doc.fill"
        case .installers: return "arrow.down.app.fill"
        case .projects: return "externaldrive.badge.checkmark"
        }
    }

    var tone: Tone {
        switch self {
        case .junk: return .brand
        case .safe: return .good
        case .duplicates: return .caution
        case .installers: return .info
        case .projects: return .brand
        }
    }
}

/// Как вопрос звучит и что показывает.
extension CleanupQuestion {
    var symbol: String {
        switch kind {
        case .module(let module): return module.symbol
        case .docker: return "shippingbox.fill"
        }
    }

    var tone: Tone {
        switch kind {
        case .module(let module): return module.tone
        case .docker: return .info
        }
    }

    var title: String {
        switch kind {
        case .module(.junk): return "Удалить мусор?"
        case .module(.duplicates): return "Удалить лишние копии?"
        case .module(.installers): return "Удалить старые установщики?"
        case .module(.safe): return "Убрать в сейф крупное и старое?"
        case .module(.projects): return "Добавить проекты в бэкап?"
        case .docker: return "Очистить Docker?"
        }
    }

    /// Что именно и что будет по «да» — одним абзацем.
    var text: String {
        switch kind {
        case .module(.junk):
            return "\(Self.list(labels, quoted: false)) — программы создадут это заново."
        case .module(.duplicates):
            let groups = Set(items.compactMap(\.duplicateGroup)).count
            return "\(items.count) \(pluralRu(items.count, "лишняя копия", "лишние копии", "лишних копий")) одинаковых файлов (\(groups) \(pluralRu(groups, "группа", "группы", "групп"))): \(Self.list(labels, quoted: true)). У каждого файла останется одна копия — та, что лежит на своём месте, — и каждая лишняя перед удалением сверяется с ней байт в байт."
        case .module(.installers):
            return "\(Self.list(labels, quoted: true)) — .dmg, .pkg и .xip старше недели. Если программа понадобится снова, установщик можно скачать. Посмотрите список ниже: «Разрешить всё» установщики не удаляет, только ответ здесь."
        case .module(.safe):
            return "\(Self.list(labels, quoted: true)) — не менялось больше трёх месяцев. Перенесу в сейф со сверкой каждого файла и уберу с Mac; вернуть можно в «Перенесённом»."
        case .module(.projects):
            return "\(Self.list(labels, quoted: true)) — папки с git, которых нет в бэкапе. Ничего не удаляется: они только добавятся в список папок бэкапа."
        case .docker:
            var parts: [String] = []
            if let cache = docker[.buildCache] { parts.append("кеш сборки (\(Format.bytes(cache)))") }
            if docker[.danglingImages] != nil { parts.append("образы без имени — остатки пересборок") }
            let what = parts.joined(separator: " и ")
            return "\(what.prefix(1).uppercased() + what.dropFirst()). Кеш наберётся при следующей сборке. Образы с именем, тома с данными и контейнеры не трогаю; все неиспользуемые образы можно убрать в разделе «Docker»."
        }
    }

    var yesTitle: String {
        switch kind {
        case .module(.duplicates): return "Удалить копии"
        case .module(.safe): return "Убрать в сейф"
        case .module(.projects): return "Добавить"
        case .docker: return "Очистить"
        case .module: return "Удалить"
        }
    }

    var noTitle: String { "Не сейчас" }

    /// Размер справа: сколько освободится, у проектов — сколько папок.
    var amount: String {
        if kind == .module(.projects) { return "\(items.count) \(pluralRu(items.count, "папка", "папки", "папок"))" }
        return Format.bytes(bytes)
    }

    /// «Кеш npm, кеш Chrome и ещё 3» или «Датасеты», «Съёмки 2023» и ещё 2».
    static func list(_ labels: [String], quoted: Bool) -> String {
        let shown = labels.prefix(3).enumerated().map { index, label -> String in
            if quoted { return "«\(label)»" }
            return index == 0 ? label : label.prefix(1).lowercased() + label.dropFirst()
        }
        let rest = labels.count - shown.count
        let head = shown.joined(separator: ", ")
        return rest > 0 ? "\(head) и ещё \(rest)" : head
    }
}

/// Разбор Mac: «Начать» → вопросы → ответы. Никаких флажков и папок: на каждый вопрос —
/// «да» или «не сейчас», и сделанное видно сразу у вопроса.
struct CleanupView: View {
    @Environment(AppModel.self) private var app
    @State private var unlockingSafe = false
    @State private var forgetting = false
    @State private var erasing = false

    var body: some View {
        let model = app.cleanup
        PageScroll {
            if let problem = model.storeProblem {
                Notice(.warning, "Решения не запоминаются: \(problem)")
            }
            switch model.stage {
            case .idle:
                start
            case .scanning(let progress):
                scanning(progress)
            case .review:
                review
            }
        }
        .navigationTitle("Разобрать")
        .task {
            model.loadHabits(home: app.rules.home)
            // В демонстрации сразу показываем вопросы — снимку экрана нечего ждать.
            if Demo.isOn, model.stage == .idle { model.scan(app: app) }
        }
        .sheet(isPresented: $unlockingSafe) {
            SafeBeforeRunSheet(bytes: model.question(.module(.safe))?.bytes ?? 0) {
                model.answer(.module(.safe), yes: true, app: app)
            }
        }
    }

    private func beginScan() {
        app.cleanup.scan(app: app)
    }

    /// «Да». Для сейфа, если он закрыт, сначала пароль — и выполнение начнётся, как только сейф откроется.
    private func yes(_ kind: CleanupQuestion.Kind) {
        let model = app.cleanup
        if model.needsSafe(kind, app: app) {
            unlockingSafe = true
        } else {
            model.answer(kind, yes: true, app: app)
        }
    }

    /// «Разрешить всё». Если сейф на подключённом диске закрыт — спросить пароль для вопроса о сейфе;
    /// сейфа нет или диск не подключён — вопрос о сейфе просто остаётся ждать, с объяснением.
    private func allowAll() {
        if app.cleanup.answerAll(app: app), app.destination != nil, app.safe.exists { unlockingSafe = true }
    }

    // MARK: - Начало

    /// Где разбор ищет — чтобы было видно, что личное в ~/Library он не трогает.
    private static let places: [(symbol: String, title: String)] = [
        ("arrow.down.circle", "Загрузки"), ("menubar.dock.rectangle", "Рабочий стол"), ("doc", "Документы"),
        ("film", "Фильмы"), ("music.note", "Музыка"), ("photo", "Изображения"),
        ("folder", "Свои папки в домашней"), ("hammer", "Кеши программ"), ("shippingbox", "Docker"),
    ]

    /// О чём спрошу и что будет по «да».
    private static let kinds: [(symbol: String, tone: Tone, title: String, detail: String, outcome: String)] = [
        ("trash.fill", .brand, "Мусор", "Кеши и скачанные пакеты — программы создадут их заново.", "в Корзину"),
        ("shippingbox.fill", .info, "Docker", "Кеш сборки и образы без имени. Образы с именем и тома с данными не трогаю.", "удалит Docker"),
        ("doc.on.doc.fill", .caution, "Лишние копии", "Одинаковые файлы — одна копия каждого остаётся всегда.", "в Корзину"),
        ("arrow.down.app.fill", .info, "Установщики", ".dmg, .pkg и .xip старше недели — только отдельным «да».", "в Корзину"),
        ("lock.shield.fill", .good, "Крупное и старое", "Не менялось больше трёх месяцев — со сверкой каждого файла.", "в сейф"),
        ("externaldrive.badge.checkmark", .brand, "Проекты без бэкапа", "Папки с git — ничего не удаляется.", "в бэкап"),
    ]

    private var start: some View {
        let model = app.cleanup
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius + 4, style: .continuous)
        return VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Разобрать Mac").font(Theme.display(30))
                    Text("Найду, что занимает место зря, и спрошу про каждое: удалить или нет. Выбирать файлы и ходить по папкам не нужно — только отвечать «да» или «не сейчас». Без вашего «да» ничего не трогаю.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    FlowLayout(spacing: 6) {
                        ForEach(Self.places, id: \.title) { place in
                            Label(place.title, systemImage: place.symbol)
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }
                }
                Spacer(minLength: 0)
                ScanButton(title: "Начать", action: beginScan)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Theme.brand.opacity(0.20), Theme.brand.opacity(0.04)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: shape)
            .overlay { shape.strokeBorder(Theme.brand.opacity(0.25)) }

            if let run = model.lastRun {
                CardSection(title: "Прошлый разбор — \(run.date.formatted(date: .abbreviated, time: .shortened))") {
                    HStack(alignment: .top, spacing: 16) {
                        result(Format.bytes(run.trashedBytes), "удалено")
                        result(Format.bytes(run.movedBytes), "убрано в сейф")
                        result("\(run.addedToBackup)", "добавлено в бэкап")
                    }
                    .padding(Theme.cardPadding)
                }
            }
            legend
            if model.storeProblem == nil {
                learned
            }
            if !model.ignored.isEmpty {
                ignoredSection
            }
        }
    }

    private var legend: some View {
        CardSection(title: "О чём спрошу",
                    footer: "Удаляемое уходит в Корзину — вернуть можно одной кнопкой у своего вопроса, а в конце можно удалить это из Корзины насовсем. Образы Docker удаляет сам Docker, он скачает их снова. В сейф — со сверкой каждого файла; вернуть можно в «Перенесённом».") {
            ForEach(Self.kinds, id: \.title) { kind in
                HStack(spacing: 12) {
                    IconTile(systemImage: kind.symbol, tone: kind.tone)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title).fontWeight(.medium)
                        Text(kind.detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    StatusPill(title: kind.outcome, tone: .neutral)
                }
                .rowPadding()
                if kind.title != Self.kinds.last?.title { RowDivider(inset: 54) }
            }
        }
    }

    /// Чему Offload научился на решениях человека — и кнопка, чтобы всё это забыть.
    private var learned: some View {
        let model = app.cleanup
        return CardSection(title: "Чему научился",
                           footer: "Учусь только на этом Mac и только на ваших ответах. Что вы вернули из Корзины, больше не предлагаю; похожее на то, что вы обычно убираете в сейф, добавляю в вопрос о сейфе. Сам ничего не делаю — только спрашиваю.") {
            if model.habits.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(systemImage: "sparkles", tone: .neutral)
                    Text("Пока привычек нет. Привычка появляется, когда вы хотя бы трижды одинаково решаете похожее — например, убираете в сейф старые съёмки из «Фильмов». Тогда похожие папки сами попадут в вопрос о сейфе.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .rowPadding()
            }
            ForEach(model.habits, id: \.self) { habit in
                HStack(spacing: 12) {
                    IconTile(systemImage: habit.action.symbol, tone: habit.action.tone)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(habit.scope.prefix(1).uppercased() + habit.scope.dropFirst()).fontWeight(.medium)
                        Text("обычно \(HabitModel.Prediction.verb(habit.action))").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Text("\(habit.agreeing) из \(habit.total)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        .help("Столько похожих решений за это действие из всех похожих")
                }
                .rowPadding()
                if habit != model.habits.last || model.remembered > 0 { RowDivider(inset: 54) }
            }
            if model.remembered > 0 {
                if model.habits.isEmpty { RowDivider(inset: 54) }
                HStack(spacing: 12) {
                    Text("Помню ваши ответы для \(model.remembered) \(pluralRu(model.remembered, "объекта", "объектов", "объектов"))")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Button("Забыть мои решения…") { forgetting = true }
                }
                .rowPadding()
            }
            if let problem = model.forgetProblem {
                Notice(.warning, "Забыть не получилось: \(problem)").padding(Theme.cardPadding)
            }
        }
        .confirmationDialog("Забыть ваши решения?", isPresented: $forgetting) {
            Button("Забыть", role: .destructive) { model.forgetDecisions(home: app.rules.home) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Offload забудет ваши ответы по каждой папке и файлу и привычки, выученные на них. Итоги прошлых разборов и то, что вы просили не предлагать, останутся.")
        }
    }

    /// То, что человек просил больше не предлагать, — с возможностью вернуть.
    private var ignoredSection: some View {
        let model = app.cleanup
        return CardSection(title: "Не предлагаю — \(model.ignored.count)",
                           footer: "Сюда попадает то, что вы попросили больше не предлагать: «Что именно» у вопроса → правый щелчок по строке → «Не предлагать больше». Папка — вместе со всем, что внутри.") {
            ForEach(model.ignored, id: \.self) { path in
                HStack(spacing: 12) {
                    IconTile(systemImage: "eye.slash", tone: .neutral)
                    Text(relativeToHome(path, home: app.rules.home)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    Button("Снова предлагать") { model.unignore(path) }
                }
                .rowPadding()
                if path != model.ignored.last { RowDivider(inset: 54) }
            }
            if let problem = model.ignoreProblem {
                Notice(.warning, "Не получилось: \(problem)").padding(Theme.cardPadding)
            }
        }
    }

    // MARK: - Поиск

    private func scanning(_ progress: CleanupModel.ScanProgress) -> some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            Card(spacing: 16) {
                HStack(spacing: 16) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                        .symbolEffect(.pulse)
                        .frame(width: 56, height: 56)
                        .background(Theme.brand.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(progress.duplicates ? "Ищу одинаковые файлы"
                             : progress.total == 0 ? "Собираю, что посмотреть…" : "Смотрю, что занимает место")
                            .font(Theme.display(19))
                        Text(progress.current.isEmpty ? " " : progress.current)
                            .font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 12)
                    if progress.duplicates {
                        Text("\(progress.files) \(pluralRu(progress.files, "файл", "файла", "файлов"))")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    } else if progress.total > 0 {
                        Text("\(progress.done) из \(progress.total)")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Button("Отменить") { app.cleanup.cancel() }
                }
                if progress.duplicates {
                    // Сколько файлов впереди, заранее неизвестно — полоса без конца.
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0)
                }
            }
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    scanTile(.junk, progress)
                    scanTile(.safe, progress)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 12) {
                    scanTile(.duplicates, progress)
                    scanTile(.installers, progress)
                    scanTile(.projects, progress)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Плитка во время поиска: сколько уже нашлось.
    private func scanTile(_ module: CleanupModule, _ progress: CleanupModel.ScanProgress) -> some View {
        let found = progress.found[module] ?? 0
        let value: String
        if module == .duplicates {
            value = progress.duplicates ? "ищу…" : "после замера"
        } else if module == .projects {
            value = "\(found)"
        } else {
            value = Format.bytes(found)
        }
        let active = found > 0 || (module == .duplicates && progress.duplicates)
        return Card(spacing: 10, fillsHeight: true) {
            IconTile(systemImage: module.symbol, tone: active ? module.tone : .neutral, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(Theme.display(24))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(module.title).font(.callout).foregroundStyle(.secondary)
            }
        }
        .animation(.snappy, value: value)
    }

    // MARK: - Вопросы

    @ViewBuilder
    private var review: some View {
        let model = app.cleanup
        if model.questions.isEmpty {
            Card(spacing: 12) {
                Label("Спрашивать не о чем: мусора и лишнего нет, а всё крупное либо используется, либо уже на своём месте.",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.ok)
                Button("Готово") { model.reset(app: app) }
            }
            dockerIdleCard
        } else {
            summary
            dockerIdleCard
            ForEach(model.questions) { question in
                QuestionCard(question: question, answer: model.answer(for: question.kind), hint: model.hints[question.kind],
                             yes: { yes(question.kind) },
                             no: { model.answer(question.kind, yes: false, app: app) },
                             reconsider: { model.reconsider(question.kind) },
                             restore: { model.restore(question.kind, app: app) },
                             stop: { model.stop() },
                             ignore: { model.ignore($0) })
            }
            if let problem = model.ignoreProblem {
                Notice(.warning, "Не получилось запомнить «не предлагать»: \(problem)")
            }
            trashCard
            if model.isSettled {
                HStack {
                    Button("Готово") { model.reset(app: app) }
                    Button("Разобрать ещё раз") {
                        model.reset(app: app)
                        beginScan()
                    }
                }
                .disabled(model.isBusy)
            }
        }
    }

    /// Сколько можно освободить и «Разрешить всё» — или, когда ответили на всё, сколько освободилось.
    private var summary: some View {
        let model = app.cleanup
        let open = model.asking
        let together = open.filter(\.answeredTogether)
        let togetherBytes = together.reduce(Int64(0)) { $0 + $1.bytes }
        let freed = max(0, model.freed ?? 0)
        return Card(spacing: 12) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    if !open.isEmpty {
                        Text("Можно освободить").font(.callout).foregroundStyle(.secondary)
                        Text(Format.bytes(model.pendingBytes))
                            .font(Theme.display(44)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text("\(open.count) \(pluralRu(open.count, "вопрос", "вопроса", "вопросов")) — на каждый ответьте «да» или «не сейчас». Удаляемое сначала уходит в Корзину.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(model.isSettled ? "Готово" : "Делаю…").font(.callout).foregroundStyle(.secondary)
                        Text(freed >= 100_000_000 ? "Освободилось \(Format.bytes(freed))" : "Ответили на всё")
                            .font(Theme.display(34)).monospacedDigit()
                        Text(settledLine)
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .animation(.snappy, value: model.pendingBytes)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 8) {
                    if !together.isEmpty {
                        Button(action: allowAll) {
                            Label(togetherBytes > 0 ? "Разрешить всё · \(Format.bytes(togetherBytes))" : "Разрешить всё",
                                  systemImage: "checkmark.circle.fill")
                                .frame(minWidth: 150)
                        }
                        .prominentButton()
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .help(open.count > together.count
                              ? "Ответить «да» на все вопросы, кроме установщиков: их удаляю только по отдельному ответу"
                              : "Ответить «да» на все вопросы")
                    }
                    if !model.isSettled {
                        Button("Отмена") { model.reset(app: app) }
                            .buttonStyle(InkLinkStyle())
                            .disabled(model.isBusy)
                    }
                }
            }
        }
    }

    private var settledLine: String {
        let model = app.cleanup
        if !model.trashedItems.isEmpty {
            return "Удалённое лежит в Корзине и занимает место, пока её не очистят, — ниже можно удалить это насовсем."
        }
        if let now = model.freeNow { return "Свободно на Mac \(Format.bytes(now))." }
        return "Ответы запомнены: что вы вернули из Корзины, больше не предложу."
    }

    /// Docker стоит, но не запущен: что в нём можно убрать, узнать нельзя — сказать, как это исправить.
    @ViewBuilder
    private var dockerIdleCard: some View {
        if let idle = app.cleanup.dockerIdle, idle >= 1_000_000_000 {
            Card(spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    IconTile(systemImage: "shippingbox.fill", tone: .neutral, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Docker не запущен").font(.headline)
                        Text("Его диск занимает \(Format.bytes(idle)). Запустите Docker Desktop и разберите ещё раз — спрошу, что из него можно удалить.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if let docker = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.docker.docker") {
                        Button("Запустить Docker") { NSWorkspace.shared.open(docker) }
                    }
                }
            }
        }
    }

    /// Удалённое этим разбором лежит в Корзине: удалить насовсем, чтобы место освободилось сейчас?
    @ViewBuilder
    private var trashCard: some View {
        let model = app.cleanup
        let items = model.trashedItems
        let inTrash = items.reduce(Int64(0)) { $0 + $1.bytes }
        if !items.isEmpty {
            Card(spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    IconTile(systemImage: "xmark.bin.fill", tone: .danger, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Удалить из Корзины насовсем?").font(.headline)
                        Text("В Корзине \(Format.bytes(inTrash)) из этого разбора: место на Mac освободится, только когда их удалят оттуда. Остальное в Корзине не трогаю. Вернуть удалённое насовсем будет нельзя.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Text(Format.bytes(inTrash)).font(Theme.display(20)).monospacedDigit()
                }
                HStack(spacing: 10) {
                    if let finishing = model.finishing {
                        ProgressView().controlSize(.small)
                        Text(finishing).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { erasing = true } label: { Label("Удалить насовсем…", systemImage: "xmark.bin") }
                        .disabled(model.isBusy)
                }
            }
            .confirmationDialog("Удалить насовсем \(Format.bytes(inTrash))?", isPresented: $erasing) {
                Button("Удалить насовсем", role: .destructive) { model.eraseTrashed(app: app) }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Из Корзины удалится только то, что туда отправил этот разбор. Вернуть это будет нельзя.")
            }
        }
        if model.erased > 0 {
            Notice(.success, "Удалено из Корзины насовсем: \(model.erased), \(Format.bytes(model.erasedBytes)).")
        }
        if !model.trashProblems.isEmpty {
            Notice(.warning, "Не всё получилось:", details: model.trashProblems)
        }
    }

    private func result(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.display(20)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Один вопрос: что найдено, что будет по «да», и две кнопки. После ответа — что сделано.
struct QuestionCard: View {
    @Environment(AppModel.self) private var app
    let question: CleanupQuestion
    let answer: CleanupModel.Answer
    let hint: String?
    let yes: () -> Void
    let no: () -> Void
    let reconsider: () -> Void
    let restore: () -> Void
    let stop: () -> Void
    let ignore: (CleanupSuggestion) -> Void

    /// Сколько строк «Что именно» видно: список в сотни строк ничего не добавит к ответу.
    private static let visibleItems = 40

    var body: some View {
        Card(spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                IconTile(systemImage: question.symbol, tone: answer == .declined ? .neutral : question.tone, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(question.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(question.amount)
                            .font(Theme.display(20))
                            .monospacedDigit()
                    }
                    Text(question.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(question.notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if question.kind == .module(.safe), answer == .asking {
                        SafeStatusLine(needed: question.bytes)
                    }
                }
            }
            state
            if !question.items.isEmpty {
                details
            }
        }
        .opacity(answer == .declined ? 0.7 : 1)
    }

    @ViewBuilder
    private var state: some View {
        switch answer {
        case .asking:
            HStack(spacing: 10) {
                if let hint {
                    Label(hint, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(question.noTitle, action: no)
                    .controlSize(.large)
                Button(question.yesTitle, action: yes)
                    .prominentButton()
                    .controlSize(.large)
            }
        case .queued:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("В очереди — начну, как только закончу предыдущее").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Отменить", action: reconsider)
            }
        case .running(let progress):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if progress.count > 1 {
                        Text("\(max(progress.index, 1)) из \(progress.count)").monospacedDigit()
                    }
                    Text(progress.item.isEmpty ? " " : "«\(progress.item)»").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(progress.phase).foregroundStyle(.secondary)
                    Button("Остановить", action: stop)
                }
                .font(.callout)
                ProgressView(value: min(Double(progress.count), Double(max(progress.index, 1) - 1) + progress.fraction),
                             total: Double(max(progress.count, 1)))
            }
        case .done(let outcome):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Label(doneLine(outcome), systemImage: outcome.done > 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(outcome.done > 0 ? Theme.ok : Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    if !outcome.trashedItems.isEmpty {
                        Button { restore() } label: { Label("Вернуть", systemImage: "arrow.uturn.backward") }
                            .disabled(app.cleanup.finishing != nil)
                            .help("Вернуть из Корзины на прежние места — и больше не предлагать")
                    }
                    if question.kind == .module(.projects), outcome.done > 0 {
                        Button("Открыть «Бэкап»") { app.section = .backup }
                    }
                }
                if !outcome.problems.isEmpty {
                    Notice(.warning, "Не всё получилось:", details: outcome.problems)
                }
            }
        case .declined:
            HStack(spacing: 10) {
                Text("Не трогаю. Спрошу в следующий раз.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Передумал", action: reconsider).buttonStyle(InkLinkStyle())
            }
        }
    }

    private func doneLine(_ outcome: CleanupModel.Outcome) -> String {
        var parts: [String] = []
        if outcome.done == 0 {
            parts.append(outcome.cancelled ? "Остановлено, ничего не сделано" : "Не получилось")
        } else {
            switch question.kind {
            case .module(.projects):
                parts.append("Добавлено в бэкап: \(outcome.done). Обновите бэкап, чтобы они в него попали")
            case .module(.safe):
                parts.append("Убрано в сейф: \(Format.bytes(outcome.bytes)), \(outcome.done) из \(question.items.count)")
            case .docker:
                parts.append(outcome.bytes > 0 ? "Docker удалил \(Format.bytes(outcome.bytes))" : "Docker очищен")
            case .module:
                parts.append("В Корзине: \(Format.bytes(outcome.bytes)), \(outcome.done) из \(question.items.count)")
            }
            if outcome.cancelled { parts.append("остальное остановлено") }
        }
        if outcome.restored > 0 { parts.append("возвращено на место: \(outcome.restored)") }
        return parts.joined(separator: " · ")
    }

    /// «Что именно» — по желанию, свёрнуто: для ответа хватает строки выше.
    private var details: some View {
        let items = question.items
        let shown = Array(items.prefix(Self.visibleItems))
        return DisclosureGroup("Что именно — \(items.count)") {
            VStack(spacing: 0) {
                ForEach(shown) { item in
                    FoundRow(item: item, home: app.rules.home,
                             keeper: question.keepers.first { $0.duplicateGroup != nil && $0.duplicateGroup == item.duplicateGroup },
                             ignore: answer == .asking ? { ignore(item) } : nil)
                    if item.id != shown.last?.id { RowDivider(inset: 44) }
                }
                if items.count > shown.count {
                    Text("и ещё \(items.count - shown.count)").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
            }
            .padding(.top, 6)
        }
        .font(.callout)
    }
}


/// Строка «Что именно»: что это, где лежит и почему попало в вопрос. Без флажков — решение одно на весь вопрос.
struct FoundRow: View {
    let item: CleanupSuggestion
    let home: URL
    /// Для лишней копии — копия, которая остаётся.
    var keeper: CleanupSuggestion?
    /// nil — просить не предлагать уже поздно (на вопрос ответили).
    var ignore: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemImage: item.isDirectory ? "folder.fill" : "doc.fill", tone: .neutral, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.url.lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    if item.learned {
                        StatusPill(title: "как в прошлый раз", systemImage: "clock.arrow.circlepath", tone: .brand)
                    } else if item.habit {
                        StatusPill(title: "как вы обычно", systemImage: "sparkles", tone: .brand)
                    }
                }
                Text(relativeToHome(item.url.path, home: home)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let keeper {
                    Text("Такая же остаётся: \(relativeToHome(keeper.url.path, home: home))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else {
                    Text(item.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(item.cautions, id: \.self) { caution in
                    Text(caution).font(.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.bytes(item.bytes)).fontWeight(.semibold).monospacedDigit()
                if let modified = item.modified {
                    Text(Format.relative(modified)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Показать в Finder") { revealInFinder(item.url) }
            if let ignore { Button("Не предлагать больше", action: ignore) }
        }
    }
}

/// Сейф для вопроса «в сейф»: есть ли он, открыт ли и поместится ли.
struct SafeStatusLine: View {
    @Environment(AppModel.self) private var app
    let needed: Int64
    @State private var growing = false

    var body: some View {
        let safe = app.safe
        Group {
            if Demo.isOn {
                Label("Сейф открыт", systemImage: "lock.open.fill").foregroundStyle(.secondary)
            } else if app.destination == nil {
                Label("Подключите внешний диск с сейфом", systemImage: "externaldrive.badge.xmark").foregroundStyle(Theme.warn)
            } else if !safe.exists {
                HStack(spacing: 6) {
                    Label("Сейфа на диске нет", systemImage: "lock.slash").foregroundStyle(Theme.warn)
                    Button("Создать…") { app.section = .safe }.buttonStyle(InkLinkStyle())
                }
            } else if safe.state?.isEncrypted != true {
                Label("Шифрование образа не подтверждается", systemImage: "exclamationmark.octagon").foregroundStyle(Theme.bad)
            } else if let room = safe.roomLeft(host: app.destination, volume: app.safeVolume), needed > room {
                HStack(spacing: 6) {
                    Label("Поместится около \(Format.bytes(room))", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                    Button("Увеличить…") { growing = true }.buttonStyle(InkLinkStyle())
                }
            } else if let volume = app.safeVolume {
                Label("Сейф открыт · свободно \(Format.bytes(volume.availableBytes))", systemImage: "lock.open.fill")
                    .foregroundStyle(.secondary)
            } else {
                Label("Сейф закрыт — пароль спрошу, когда ответите «да»", systemImage: "lock.fill").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .sheet(isPresented: $growing) { GrowSafeSheet(needed: needed) }
    }
}

/// Большая круглая кнопка, с которой начинается разбор, — как «Сканировать» в CleanMyMac.
struct ScanButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 30, weight: .semibold))
                Text(title).font(Theme.display(19))
            }
            .foregroundStyle(.white)
            .frame(width: 128, height: 128)
            .background(Circle().fill(LinearGradient(colors: [Theme.brand, Theme.brand.opacity(0.72)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay { Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1) }
            .shadow(color: Theme.brand.opacity(hovering ? 0.55 : 0.35), radius: hovering ? 18 : 12, y: 6)
            .scaleEffect(hovering ? 1.03 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy, value: hovering)
        .keyboardShortcut(.defaultAction)
    }
}

/// «Да» на вопрос о сейфе, а он закрыт: пароль — и перенос начнётся, как только сейф откроется.
struct SafeBeforeRunSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let bytes: Int64
    let onOpen: () -> Void

    var body: some View {
        let safe = app.safe
        SheetLayout(systemImage: "lock.fill", tone: .good, title: "Откройте сейф",
                    subtitle: "Убрать в сейф \(Format.bytes(bytes))") {
            if app.destination == nil {
                Text("Подключите внешний диск, на котором лежит сейф, и ответьте ещё раз. Остальные вопросы от этого не зависят.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !safe.exists {
                Text("На диске «\(app.destination?.name ?? "")» сейфа нет. Создайте его в разделе «Сейф» и ответьте ещё раз.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if safe.state?.isEncrypted != true {
                Text("Шифрование образа на диске не подтверждается — класть в него нельзя. Разберитесь в разделе «Сейф».")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Пароль нужен, чтобы убрать это в сейф. Он уходит в macOS и нигде не сохраняется. Как только сейф откроется, начну.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SafeUnlockRow()
            }
        } actions: {
            Button("Отмена") { dismiss() }
            if app.destination != nil, !safe.exists {
                Button("Открыть «Сейф»") {
                    dismiss()
                    app.section = .safe
                }
            }
        }
        .onChange(of: safe.isOpen) {
            guard safe.isOpen else { return }
            dismiss()
            onOpen()
        }
    }
}
