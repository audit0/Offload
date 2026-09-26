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
        case .duplicates: return "Одинаковые файлы"
        case .installers: return "Установщики"
        case .projects: return "Проекты без бэкапа"
        }
    }

    /// Одна строка под названием: что это и что с ним будет.
    var subtitle: String {
        switch self {
        case .junk: return "Кеши и скачанные пакеты — программы создадут их заново. В Корзину."
        case .safe: return "Не менялось больше трёх месяцев — в сейф, со сверкой каждого файла."
        case .duplicates: return "Лишние копии — в Корзину. Одна копия остаётся всегда."
        case .installers: return "Старые .dmg, .pkg и .xip — если программа уже стоит. В Корзину."
        case .projects: return "Проекты с git — в список папок бэкапа. Ничего не удаляется."
        }
    }

    /// Подробнее — в шапке раздела.
    var explanation: String {
        switch self {
        case .junk:
            return "Только места из списка Offload, которые программы пересоздают сами: кеши сборки Xcode, пакеты Homebrew, npm, pip, кеши браузера и сред разработки. Кеш открытой программы сам не отмечается — закройте её, и его можно будет удалить."
        case .safe:
            return "Большое и давно не менявшееся. Личное Offload сам не отмечает — решаете вы, а в следующий раз он отметит так же. Переносится со сверкой каждого файла, оригинал удаляется только после неё; вернуть можно в «Перенесённом»."
        case .duplicates:
            return "Файлы с одинаковым содержимым (сверено по SHA-256). Отмечайте лишние копии: копия, которая остаётся, всегда есть, и перед удалением каждая лишняя ещё раз сверяется с ней байт в байт."
        case .installers:
            return "Образы и пакеты установки старше недели. Если программа уже стоит, их можно скачать снова. Сам Offload их не отмечает: .dmg бывает и личным. Зашифрованные образы и .iso сюда не попадают."
        case .projects:
            return "Папки с git, которых ещё нет в бэкапе. Они добавятся в список папок бэкапа, а сам бэкап запускается в разделе «Бэкап»."
        }
    }

    var symbol: String {
        switch self {
        case .junk: return "trash.fill"
        case .safe: return "lock.shield.fill"
        case .duplicates: return "doc.on.doc.fill"
        case .installers: return "shippingbox.fill"
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

    /// Куда уходит отмеченное — для итогов.
    var destination: String {
        switch action {
        case .trash: return "в Корзину"
        case .safe: return "в сейф"
        case .backup: return "в бэкап"
        case .keep: return ""
        }
    }
}

/// Разбор Mac — как Smart Care в CleanMyMac: одна кнопка «Начать», плитки с найденным
/// и одна кнопка «Выполнить». Подробности каждой плитки — по «Подробнее».
struct CleanupView: View {
    @Environment(AppModel.self) private var app
    /// Открытая плитка: вместо итогов показан её список.
    @State private var openModule: CleanupModule?
    @State private var askingSafe = false
    @State private var growingSafe = false
    @State private var forgetting = false
    @State private var erasing = false
    @State private var showAllDuplicates = false

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
                if let module = openModule {
                    detail(module)
                } else {
                    results
                }
            case .running(let progress):
                running(progress)
            case .done(let report):
                done(report)
            }
        }
        .navigationTitle("Разобрать")
        .task {
            model.loadHabits(home: app.rules.home)
            // В демонстрации сразу показываем итоги — снимку экрана нечего ждать.
            if Demo.isOn, model.stage == .idle { model.scan(app: app) }
        }
        .sheet(isPresented: $growingSafe) { GrowSafeSheet(needed: model.bytes(model.selected(.safe))) }
        .sheet(isPresented: $askingSafe) {
            SafeBeforeRunSheet(bytes: model.bytes(model.selected(.safe))) { skipping in
                model.run(app: app, skippingSafe: skipping)
            }
        }
    }

    private func beginScan() {
        openModule = nil
        showAllDuplicates = false
        app.cleanup.scan(app: app)
    }

    /// «Выполнить»: если отмечено что-то для сейфа, а он закрыт, — сначала спросить пароль.
    private func execute() {
        let model = app.cleanup
        openModule = nil
        if !model.selected(.safe).isEmpty, app.safeVolume == nil {
            askingSafe = true
        } else {
            model.run(app: app)
        }
    }

    // MARK: - Начало

    /// Где разбор ищет — чтобы было видно, что личное в ~/Library он не трогает.
    private static let places: [(symbol: String, title: String)] = [
        ("arrow.down.circle", "Загрузки"), ("menubar.dock.rectangle", "Рабочий стол"), ("doc", "Документы"),
        ("film", "Фильмы"), ("music.note", "Музыка"), ("photo", "Изображения"),
        ("folder", "Свои папки в домашней"), ("hammer", "Кеши программ"),
    ]

    private var start: some View {
        let model = app.cleanup
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius + 4, style: .continuous)
        return VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Разобрать Mac").font(.largeTitle.weight(.bold))
                    Text("Найду мусор, крупное и старое, одинаковые файлы и проекты без бэкапа. Сразу отмечу только то, что программы создадут заново, — личное решаете вы. Ничего не произойдёт, пока вы не нажмёте «Выполнить».")
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
                        result(Format.bytes(run.trashedBytes), "ушло в Корзину")
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

    /// Что найдётся и что Offload отметит сам, а что — только вы.
    private var legend: some View {
        CardSection(title: "Что найду",
                    footer: "Удалённое уходит в Корзину, и после разбора его можно вернуть на место одной кнопкой. В сейф — со сверкой каждого файла; вернуть можно в «Перенесённом».") {
            ForEach(CleanupModule.allCases, id: \.self) { module in
                HStack(spacing: 12) {
                    IconTile(systemImage: module.symbol, tone: module.tone)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.title).fontWeight(.medium)
                        Text(module.subtitle).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if module.isAutomatic {
                        StatusPill(title: "отмечаю сам", systemImage: "checkmark", tone: .good)
                    } else {
                        StatusPill(title: "решаете вы", systemImage: "hand.point.up.left", tone: .neutral)
                    }
                }
                .rowPadding()
                if module != CleanupModule.allCases.last { RowDivider(inset: 54) }
            }
        }
    }

    /// Чему Offload научился на решениях человека — и кнопка, чтобы всё это забыть.
    private var learned: some View {
        let model = app.cleanup
        return CardSection(title: "Чему научился",
                           footer: "Учусь только на этом Mac и только на вашем выборе: то, чего вы не трогали, не считается. Привычка может отметить похожее для сейфа или бэкапа, но никогда не отмечает удаление — и любую отметку можно снять.") {
            if model.habits.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(systemImage: "sparkles", tone: .neutral)
                    Text("Пока привычек нет. Привычка появляется, когда вы хотя бы трижды одинаково решаете похожее — например, убираете в сейф старые съёмки из «Фильмов». Тогда такие папки будут отмечены сразу.")
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
                    Text("Помню ваш выбор для \(model.remembered) \(pluralRu(model.remembered, "объекта", "объектов", "объектов"))")
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
            Text("Offload забудет, что вы выбирали для каждой папки и файла, и привычки, выученные на этом. Итоги прошлых разборов и то, что вы просили не предлагать, останутся.")
        }
    }

    /// То, что человек просил больше не предлагать, — с возможностью вернуть.
    private var ignoredSection: some View {
        let model = app.cleanup
        return CardSection(title: "Не предлагаю — \(model.ignored.count)",
                           footer: "Сюда попадает то, что вы попросили больше не предлагать (правый щелчок по строке → «Не предлагать больше»). Папка — вместе со всем, что внутри.") {
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
                            .font(.title3.weight(.semibold))
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
            tileRows { module in
                scanTile(module, progress)
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
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(module.title).font(.callout).foregroundStyle(.secondary)
            }
        }
        .animation(.snappy, value: value)
    }

    /// Плитки в два ряда: главные — мусор и сейф — крупнее, остальные три под ними.
    private func tileRows<Tile: View>(@ViewBuilder _ tile: @escaping (CleanupModule) -> Tile) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                tile(.junk)
                tile(.safe)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                tile(.duplicates)
                tile(.installers)
                tile(.projects)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Итоги

    @ViewBuilder
    private var results: some View {
        let model = app.cleanup
        if model.suggestions.isEmpty {
            Card(spacing: 12) {
                Label("Разбирать нечего: мусора нет, а всё крупное либо используется, либо уже на своём месте.",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Button("Готово") { model.reset() }
            }
        } else {
            summary
            tileRows { module in
                moduleTile(module)
            }
        }
    }

    /// Сколько освободится и одна кнопка «Выполнить».
    private var summary: some View {
        let model = app.cleanup
        let freed = model.selectedBytes
        let trash = [CleanupModule.junk, .duplicates, .installers].reduce(Int64(0)) { $0 + model.bytes(model.selected($1)) }
        let safe = model.bytes(model.selected(.safe))
        let projects = model.selected(.projects).count
        var parts: [String] = []
        if trash > 0 { parts.append("в Корзину \(Format.bytes(trash))") }
        if safe > 0 { parts.append("в сейф \(Format.bytes(safe))") }
        if projects > 0 { parts.append("в бэкап \(projects) \(pluralRu(projects, "папка", "папки", "папок"))") }
        return Card(spacing: 12) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(freed > 0 ? "Освободится на Mac" : model.hasSelection ? "Отмечено" : "Ничего не отмечено")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(freed > 0 ? Format.bytes(freed) : model.hasSelection ? parts.joined(separator: ", ") : "—")
                        .font(.system(size: freed > 0 ? 40 : 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(parts.isEmpty ? "Откройте плитку и отметьте, что сделать." : parts.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .animation(.snappy, value: freed)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 8) {
                    Button(action: execute) {
                        Label("Выполнить", systemImage: "sparkles").frame(minWidth: 130)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasSelection || app.isBusy)
                    Button("Отмена") { model.reset() }
                        .buttonStyle(.link)
                }
            }
            Text("Удаляемое уходит в Корзину: после выполнения всё можно вернуть на место одной кнопкой. Лишние копии перед удалением сверяются с остающейся байт в байт.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private enum Marks { case none, some, all }

    private func marks(_ module: CleanupModule) -> Marks {
        let model = app.cleanup
        let checkable = model.items(module).filter { model.canCheck($0) || model.isChecked($0) }
        let checked = checkable.filter { model.isChecked($0) }
        if checked.isEmpty { return .none }
        return checked.count == checkable.count ? .all : .some
    }

    /// Можно ли отмечать в плитке: для сейфа нужен сейф на подключённом диске.
    private func canSelect(_ module: CleanupModule) -> Bool {
        module != .safe || (app.destination != nil && app.safe.exists && app.safe.state?.isEncrypted == true)
    }

    private func moduleTile(_ module: CleanupModule) -> some View {
        let model = app.cleanup
        let items = model.items(module)
        let chosen = model.selected(module)
        let state = marks(module)
        let empty = items.isEmpty
        return Card(spacing: 10, fillsHeight: true) {
            HStack(alignment: .top) {
                IconTile(systemImage: module.symbol, tone: empty ? .neutral : module.tone, size: 34)
                Spacer(minLength: 8)
                if !empty {
                    Button {
                        model.setChecked(state != .all, module: module)
                    } label: {
                        Image(systemName: state == .all ? "checkmark.square.fill" : state == .some ? "minus.square.fill" : "square")
                            .font(.title2)
                            .foregroundStyle(state == .none ? Color.secondary : Theme.brand)
                    }
                    .buttonStyle(.plain)
                    .help(state == .all ? "Снять всё в плитке" : "Отметить всё в плитке")
                    .disabled(!canSelect(module) && state == .none)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title).font(.headline)
                Text(tileValue(module, items: items))
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                Text(tileStatus(module, items: items, chosen: chosen))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if module == .safe, !empty {
                safeLine
            }
            Spacer(minLength: 0)
            if !empty {
                Button("Подробнее") { openModule = module }
                    .buttonStyle(.link)
            }
        }
        .opacity(empty ? 0.6 : 1)
    }

    private func tileValue(_ module: CleanupModule, items: [CleanupSuggestion]) -> String {
        let model = app.cleanup
        switch module {
        case .projects:
            return "\(items.count) \(pluralRu(items.count, "папка", "папки", "папок"))"
        case .duplicates:
            // Сколько можно освободить: всё, кроме копий, которые остаются.
            return Format.bytes(model.bytes(items.filter { $0.action == .trash }))
        default:
            return Format.bytes(model.bytes(items))
        }
    }

    private func tileStatus(_ module: CleanupModule, items: [CleanupSuggestion], chosen: [CleanupSuggestion]) -> String {
        let model = app.cleanup
        if items.isEmpty { return "не найдено" }
        if module == .duplicates {
            let groups = Set(items.compactMap(\.duplicateGroup)).count
            let lead = "\(groups) \(pluralRu(groups, "группа", "группы", "групп"))"
            return chosen.isEmpty ? "\(lead) · решаете вы, какие копии лишние"
                : "\(lead) · отмечено \(chosen.count) \(pluralRu(chosen.count, "копия", "копии", "копий")), \(Format.bytes(model.bytes(chosen)))"
        }
        if chosen.isEmpty {
            return module.isAutomatic ? "ничего не отмечено"
                : "\(items.count) \(pluralRu(items.count, "предложение", "предложения", "предложений")) · решаете вы"
        }
        if chosen.count == items.count { return "всё отмечено · \(module.destination)" }
        let detail = module == .projects ? "" : ", \(Format.bytes(model.bytes(chosen)))"
        return "отмечено \(chosen.count) из \(items.count)\(detail)"
    }

    /// Состояние сейфа в его плитке: куда поедет отмеченное и поместится ли.
    @ViewBuilder
    private var safeLine: some View {
        let model = app.cleanup
        let safe = app.safe
        let chosen = model.bytes(model.selected(.safe))
        if app.destination == nil {
            Label("Подключите внешний диск с сейфом", systemImage: "externaldrive.badge.xmark")
                .font(.caption).foregroundStyle(.orange)
        } else if !safe.exists {
            HStack(spacing: 6) {
                Label("Сейфа на диске нет", systemImage: "lock.slash").font(.caption).foregroundStyle(.orange)
                Button("Создать…") { app.section = .safe }.buttonStyle(.link).font(.caption)
            }
        } else if safe.state?.isEncrypted != true {
            Label("Шифрование образа не подтверждается", systemImage: "exclamationmark.octagon")
                .font(.caption).foregroundStyle(.red)
        } else if let room = safe.roomLeft(host: app.destination, volume: app.safeVolume), chosen > room {
            HStack(spacing: 6) {
                Label("Поместится около \(Format.bytes(room))", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                Button("Увеличить…") { growingSafe = true }.buttonStyle(.link).font(.caption)
            }
        } else if let volume = app.safeVolume {
            Label("Сейф открыт · свободно \(Format.bytes(volume.availableBytes))", systemImage: "lock.open.fill")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Label("Сейф закрыт — пароль спрошу перед выполнением", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Плитка подробно

    private func detail(_ module: CleanupModule) -> some View {
        let model = app.cleanup
        let items = model.items(module)
        let chosen = model.selected(module)
        return VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            Button {
                openModule = nil
            } label: {
                Label("Все итоги", systemImage: "chevron.left")
            }
            .buttonStyle(.link)
            Card(spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    IconTile(systemImage: module.symbol, tone: module.tone, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(module.title).font(.title2.weight(.semibold))
                        Text(module.explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(module == .projects ? "\(chosen.count)" : Format.bytes(model.bytes(chosen)))
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                        Text("отмечено \(chosen.count) из \(items.count)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if module == .safe { safeLine }
                HStack {
                    Button(module == .duplicates ? "Отметить все лишние копии" : "Отметить всё") {
                        model.setChecked(true, module: module)
                    }
                    .disabled(!canSelect(module))
                    Button("Снять всё") { model.setChecked(false, module: module) }
                    Spacer()
                    Button("Готово") { openModule = nil }
                        .buttonStyle(.borderedProminent)
                }
            }
            if module == .duplicates {
                duplicates
            } else {
                Card(padding: 0, spacing: 0) {
                    ForEach(items) { suggestion in
                        row(suggestion, enabled: canSelect(module))
                        if suggestion.id != items.last?.id { RowDivider(inset: 90) }
                    }
                }
            }
            if let problem = model.ignoreProblem {
                Notice(.warning, "Не получилось запомнить «не предлагать»: \(problem)")
            }
        }
    }

    /// Снять отметку можно всегда; отметить — если действие разрешено и, для сейфа, сейф есть.
    private func row(_ suggestion: CleanupSuggestion, enabled: Bool = true, note: String? = nil) -> some View {
        let model = app.cleanup
        let checked = model.isChecked(suggestion)
        return CleanupRow(suggestion: suggestion, home: app.rules.home, checked: checked,
                          enabled: checked || (enabled && model.canCheck(suggestion)), note: note,
                          toggle: { model.setChecked($0, for: suggestion) },
                          ignore: { model.ignore(suggestion) })
    }

    /// Сколько групп видно сразу: остальные — по кнопке, иначе длинный список тормозил бы.
    private static let visibleGroups = 12

    @ViewBuilder
    private var duplicates: some View {
        let model = app.cleanup
        let groups = model.duplicateGroups
        let shown = showAllDuplicates ? groups : Array(groups.prefix(Self.visibleGroups))
        ForEach(shown, id: \.self) { group in
            duplicateGroup(group)
        }
        if shown.count < groups.count {
            let hidden = groups.count - shown.count
            Button("Показать ещё \(hidden) \(pluralRu(hidden, "группу", "группы", "групп"))") {
                withAnimation(.easeInOut(duration: 0.15)) { showAllDuplicates = true }
            }
            .buttonStyle(.link)
        }
    }

    @ViewBuilder
    private func duplicateGroup(_ group: String) -> some View {
        let model = app.cleanup
        let copies = model.copies(in: group)
        if let first = copies.first {
            let freed = model.freedBytes(in: group)
            Card(padding: 0, spacing: 0) {
                HStack(spacing: 12) {
                    IconTile(systemImage: "doc.on.doc.fill", tone: freed > 0 ? .caution : .neutral, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(first.url.lastPathComponent).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                        Text("\(copies.count) \(pluralRu(copies.count, "одинаковая копия", "одинаковые копии", "одинаковых копий")) по \(Format.bytes(first.bytes))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Text(freed > 0 ? "освободится \(Format.bytes(freed))" : "все копии остаются")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                .rowPadding()
                ForEach(copies) { copy in
                    RowDivider(inset: 14)
                    row(copy, note: travelNote(copy))
                }
            }
        }
    }

    /// Копия отмечена, но лежит в папке, которая уезжает в сейф, — едет вместе с папкой.
    private func travelNote(_ copy: CleanupSuggestion) -> String? {
        let model = app.cleanup
        guard model.choice(for: copy) == .trash, let carrier = model.carrier(of: copy) else { return nil }
        return "Уедет в сейф вместе с папкой «\(carrier.url.lastPathComponent)» — удалять её отдельно не буду."
    }

    // MARK: - Выполнение

    private func running(_ progress: CleanupModel.Progress) -> some View {
        Card(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Выполняю: \(progress.index) из \(progress.count)").font(.title3.weight(.semibold))
                Spacer()
                Button("Остановить") { app.cleanup.cancel() }
            }
            HStack(spacing: 10) {
                if let module = progress.module {
                    IconTile(systemImage: module.symbol, tone: module.tone, size: 28)
                }
                Text("«\(progress.item)»").lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                Text(progress.phase).foregroundStyle(.secondary)
            }
            ProgressView(value: min(Double(progress.count), Double(progress.index - 1) + progress.fraction),
                         total: Double(max(progress.count, 1)))
            Text("Оригиналы удаляются только после того, как копия в сейфе перечитана и сверена. Удаляемое уходит в Корзину.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Итог

    @ViewBuilder
    private func done(_ report: CleanupModel.Report) -> some View {
        let model = app.cleanup
        let inTrash = report.trashedItems.reduce(Int64(0)) { $0 + $1.bytes }
        Card(spacing: 14) {
            HStack(spacing: 14) {
                IconTile(systemImage: report.cancelled ? "stop.circle.fill" : "checkmark.seal.fill",
                         tone: report.cancelled ? .caution : .good, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.cancelled ? "Разбор остановлен" : "Готово").font(.title2.weight(.semibold))
                    Text(freedLine(report))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                result(Format.bytes(report.trashedBytes), "в Корзину · \(report.trashed)")
                result(Format.bytes(report.movedBytes), "в сейф · \(report.moved)")
                result("\(report.addedToBackup)", "добавлено в бэкап")
            }
            if report.duplicates > 0 {
                Text("Из ушедшего в Корзину лишних копий — \(report.duplicates) (\(Format.bytes(report.duplicateBytes))): каждая перед удалением сверена с остающейся байт в байт.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if report.cancelled {
                Text("Сделанное до остановки сохранено, остальное осталось как было. Незаконченная копия убрана.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if !report.trashedItems.isEmpty {
            Card(spacing: 10) {
                CardTitle("В Корзине — \(Format.bytes(inTrash)) из этого разбора", systemImage: "trash")
                Text("Место от них освободится, когда Корзину очистят. Можно вернуть всё на прежние места — или удалить насовсем прямо сейчас. Остальное в Корзине не трогается.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { model.restoreTrashed(app: app) } label: { Label("Вернуть на место", systemImage: "arrow.uturn.backward") }
                    Button(role: .destructive) { erasing = true } label: { Label("Удалить насовсем…", systemImage: "xmark.bin") }
                    if let finishing = model.finishing {
                        ProgressView().controlSize(.small)
                        Text(finishing).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .disabled(model.finishing != nil)
            }
            .confirmationDialog("Удалить насовсем?", isPresented: $erasing) {
                Button("Удалить \(Format.bytes(inTrash))", role: .destructive) { model.eraseTrashed(app: app) }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Из Корзины удалится только то, что туда отправил этот разбор. Вернуть это будет нельзя.")
            }
        }
        if report.restored > 0 {
            Notice(.success, "Возвращено на прежние места: \(report.restored). В следующий раз это не будет отмечено.")
        }
        if report.erased > 0 {
            Notice(.success, "Удалено насовсем: \(report.erased), \(Format.bytes(report.erasedBytes)).")
        }
        if report.addedToBackup > 0 {
            Card {
                HStack {
                    Text("Новые папки в списке бэкапа. Обновите бэкап, чтобы они в него попали.").font(.callout)
                    Spacer()
                    Button("Открыть «Бэкап»") { app.section = .backup }
                }
            }
        }
        if !report.problems.isEmpty {
            Notice(.warning, "Не всё получилось:", details: report.problems)
        }
        HStack {
            Button("Готово") { model.reset() }
            Button("Разобрать ещё раз") {
                model.reset()
                beginScan()
            }
        }
        .disabled(model.finishing != nil)
    }

    /// Сколько освободилось — по замеру свободного места, а не по сумме размеров.
    private func freedLine(_ report: CleanupModel.Report) -> String {
        guard let freed = report.freed, let now = report.freeNow else {
            return "Решения запомнены: в следующий раз Offload отметит так же, а похожее — как вы обычно решаете."
        }
        if freed >= 100_000_000 {
            return "На Mac освободилось \(Format.bytes(freed)), свободно \(Format.bytes(now))."
        }
        return report.trashedItems.isEmpty
            ? "Свободно на Mac \(Format.bytes(now)). Если места прибавилось меньше, чем ожидалось, часть его держат локальные снимки Time Machine — macOS освободит их сама."
            : "Свободно на Mac \(Format.bytes(now)): ушедшее в Корзину занимает место, пока она не очищена."
    }

    private func result(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Text(title).font(.title3.weight(.semibold))
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

/// Строка предложения: флажок, что это, почему так, размер и давность.
struct CleanupRow: View {
    let suggestion: CleanupSuggestion
    let home: URL
    let checked: Bool
    let enabled: Bool
    /// Пояснение к выбору, например что копия уедет в сейф вместе с папкой.
    var note: String?
    let toggle: (Bool) -> Void
    let ignore: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Отметить", isOn: Binding(get: { checked }, set: toggle))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!enabled)
                .help(enabled ? (checked ? "Не трогать" : "Отметить") : "Это трогать нельзя")
                .padding(.top, 7)
            IconTile(systemImage: suggestion.isDirectory ? "folder.fill" : "doc.fill",
                     tone: checked ? (suggestion.module?.tone ?? .brand) : .neutral, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(suggestion.url.lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    if suggestion.learned {
                        StatusPill(title: "как в прошлый раз", systemImage: "clock.arrow.circlepath", tone: .brand)
                    } else if suggestion.habit {
                        StatusPill(title: "как вы обычно", systemImage: "sparkles", tone: .brand)
                    }
                }
                Text(relativeToHome(suggestion.url.path, home: home)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if checked, suggestion.module == .safe {
                    ForEach(suggestion.cautions, id: \.self) { caution in
                        Text(caution).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let note {
                    Text(note).font(.caption).foregroundStyle(Theme.brand).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.bytes(suggestion.bytes)).fontWeight(.semibold).monospacedDigit()
                if let modified = suggestion.modified {
                    Text(Format.relative(modified)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 110, alignment: .trailing)
        }
        .rowPadding()
        .contextMenu {
            Button("Показать в Finder") { revealInFinder(suggestion.url) }
            Button("Не предлагать больше") { ignore() }
        }
    }
}

/// Перед выполнением: для сейфа что-то отмечено, а он закрыт. Открыть — и выполнение начнётся
/// само; не хочется — выполнить остальное, а отмеченное для сейфа оставить на месте.
struct SafeBeforeRunSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let bytes: Int64
    let run: (_ skippingSafe: Bool) -> Void

    var body: some View {
        let safe = app.safe
        SheetLayout(systemImage: "lock.fill", tone: .good, title: "Откройте сейф",
                    subtitle: "Для сейфа отмечено \(Format.bytes(bytes))") {
            if app.destination == nil {
                Text("Подключите внешний диск, на котором лежит сейф, — или выполните остальное без него: отмеченное для сейфа останется на месте.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !safe.exists {
                Text("На диске «\(app.destination?.name ?? "")» сейфа нет. Создайте его в разделе «Сейф» — или выполните остальное без него: отмеченное для сейфа останется на месте.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if safe.state?.isEncrypted != true {
                Text("Шифрование образа на диске не подтверждается — класть в него нельзя. Выполните остальное без сейфа или разберитесь в разделе «Сейф».")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Пароль нужен, чтобы убрать отмеченное в сейф. Он уходит в macOS и нигде не сохраняется. Как только сейф откроется, выполнение начнётся.")
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
            Button("Выполнить без сейфа") {
                dismiss()
                run(true)
            }
        }
        .onChange(of: safe.isOpen) {
            guard safe.isOpen else { return }
            dismiss()
            run(false)
        }
    }
}
