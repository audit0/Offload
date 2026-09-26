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

    /// Заголовок группы в списке предложений.
    var sectionTitle: String {
        switch self {
        case .trash: return "Можно удалить"
        case .safe: return "Убрать в сейф"
        case .backup: return "Добавить в бэкап"
        case .keep: return "Оставить на месте"
        }
    }
}

struct CleanupView: View {
    @Environment(AppModel.self) private var app
    @State private var confirming = false
    @State private var showKept = false
    @State private var showAllDuplicates = false
    @State private var growingSafe = false
    @State private var forgetting = false

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
            case .running(let progress):
                Card(spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(progress.index) из \(progress.count): «\(progress.item)»").fontWeight(.medium)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(progress.phase).foregroundStyle(.secondary)
                        Button("Отменить") { model.cancel() }
                    }
                    ProgressView(value: progress.fraction)
                    Text("Оригиналы удаляются только после того, как копия в сейфе перечитана и сверена.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .done(let report):
                done(report)
            }
        }
        .navigationTitle("Разобрать")
        .task {
            model.loadHabits(home: app.rules.home)
            // В демонстрации сразу показываем предложения — снимку экрана нечего ждать.
            if Demo.isOn, model.stage == .idle { model.scan(app: app) }
        }
        .sheet(isPresented: $growingSafe) { GrowSafeSheet(needed: model.bytes(.safe)) }
        .confirmationDialog("Выполнить разбор?", isPresented: $confirming) {
            Button("Выполнить") { model.run(app: app) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(summaryText + " Удалённое лежит в Корзине, пока вы её не очистите; в сейф переносится со сверкой каждого файла."
                 + (model.items(.trash).contains { $0.duplicateGroup != nil }
                    ? " Каждая лишняя копия перед удалением ещё раз сверяется с остающейся байт в байт." : ""))
        }
    }

    // MARK: - Начало

    /// Где разбор ищет — чтобы было видно, что личное в ~/Library он не трогает.
    private static let places: [(symbol: String, title: String)] = [
        ("arrow.down.circle", "Загрузки"), ("menubar.dock.rectangle", "Рабочий стол"), ("doc", "Документы"),
        ("film", "Фильмы"), ("music.note", "Музыка"), ("photo", "Изображения"),
        ("folder", "Свои папки в домашней"), ("hammer", "Кеши Xcode и пакетов"),
    ]

    private var start: some View {
        let model = app.cleanup
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius + 4, style: .continuous)
        return VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(LinearGradient(colors: [Theme.brand, Theme.brand.opacity(0.7)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: Theme.brand.opacity(0.35), radius: 10, y: 4)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Разобрать Mac").font(.title.weight(.bold))
                        Text("Offload посмотрит, что занимает место, найдёт одинаковые файлы и предложит: что удалить, что убрать в сейф, что добавить в бэкап, — учитывая, что вы обычно выбираете. Вы поправите, где не согласны, — и только потом что-то произойдёт.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Где посмотрю").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                Button { model.scan(app: app) } label: {
                    Label("Разобрать", systemImage: "wand.and.stars").padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(22)
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
            if model.storeProblem == nil {
                learned
            }
            CardSection(title: "Как раскладывается") {
                ForEach([CleanupAction.trash, .safe, .backup, .keep], id: \.self) { action in
                    HStack(alignment: .top, spacing: 12) {
                        IconTile(systemImage: action.symbol, tone: action.tone)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.title).fontWeight(.medium)
                            Text(Self.explanation(action)).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .rowPadding()
                    if action != .keep { RowDivider(inset: 54) }
                }
            }
        }
    }

    private static func explanation(_ action: CleanupAction) -> String {
        switch action {
        case .trash:
            return "То, что пересоздаётся само или скачивается заново (кеши сборки, скачанные пакеты, старые установщики), и лишние копии одинаковых файлов — одна копия всегда остаётся. Всё уходит в Корзину: передумать можно, пока она не очищена."
        case .safe:
            return "Большое и давно не нужное. Переносится со сверкой каждого файла, оригинал удаляется только после неё; вернуть можно в «Перенесённом»."
        case .backup:
            return "Проекты с git — в список папок бэкапа. Сам бэкап запускается в разделе «Бэкап»."
        case .keep:
            return "То, чем вы пользуетесь, и то, что трогать нельзя. Ваш выбор запоминается: для того же объекта Offload в следующий раз предложит то же, а для похожего — то, что вы обычно выбираете."
        }
    }

    /// Чему Offload научился на решениях человека — и кнопка, чтобы всё это забыть.
    private var learned: some View {
        let model = app.cleanup
        return CardSection(title: "Чему научился",
                           footer: "Учусь только на этом Mac и только на вашем выборе: «оставить» там, где оставить и предлагалось, не считается. Привычка лишь меняет предложение — удалить разрешают только правила, а решаете всё равно вы.") {
            if model.habits.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(systemImage: "sparkles", tone: .neutral)
                    Text("Пока привычек нет. Привычка появляется, когда вы хотя бы трижды одинаково решаете похожее — например, оставляете старые папки в «Документах», хотя Offload предлагал убрать их в сейф.")
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
            Text("Offload забудет, что вы выбирали для каждой папки и файла, и привычки, выученные на этом. Итоги прошлых разборов останутся.")
        }
    }

    // MARK: - Поиск

    private func scanning(_ progress: CleanupModel.ScanProgress) -> some View {
        Card(spacing: 16) {
            HStack(spacing: 16) {
                Image(systemName: "wand.and.stars")
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
            HStack(alignment: .top, spacing: 16) {
                found(.trash, Format.bytes(progress.trashBytes))
                found(.safe, Format.bytes(progress.safeBytes))
                found(.backup, "\(progress.backupCount)")
            }
        }
    }

    /// Сколько уже набралось по действию, пока идёт поиск.
    private func found(_ action: CleanupAction, _ value: String) -> some View {
        HStack(spacing: 10) {
            IconTile(systemImage: action.symbol, tone: action.tone, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(action.title).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: value)
    }

    // MARK: - Предложения

    @ViewBuilder
    private var review: some View {
        let model = app.cleanup
        let needsSafe = !model.items(.safe).isEmpty && app.safeVolume == nil
        if model.suggestions.isEmpty {
            Card(spacing: 12) {
                Label("Разбирать нечего: всё крупное либо используется, либо уже на своём месте.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Button("Готово") { model.reset() }
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                tile(.trash)
                tile(.safe)
                tile(.backup)
            }
            .fixedSize(horizontal: false, vertical: true)
            if needsSafe {
                Card(spacing: 10, tint: .orange) {
                    Text("Чтобы убрать выбранное в сейф, откройте его — или выберите для этих строк другое действие.")
                        .fixedSize(horizontal: false, vertical: true)
                    if app.safe.state?.isEncrypted == true {
                        SafeUnlockRow().frame(maxWidth: 440)
                    } else {
                        TargetSummary(problemTone: .caution)
                    }
                }
            }
            let toSafe = model.bytes(.safe)
            if toSafe > 0, let room = app.safe.roomLeft(host: app.destination, volume: app.safeVolume), toSafe > room {
                Card(spacing: 10, tint: .orange) {
                    Label {
                        Text("В сейф выбрано \(Format.bytes(toSafe)), а поместится около \(Format.bytes(room)). Не поместившееся останется на месте — увеличьте предел сейфа, содержимое при этом не пострадает.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Button { growingSafe = true } label: {
                        Label("Увеличить предел сейфа…", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
            }
            section(.trash)
            duplicates
            section(.safe)
            section(.backup)
            // Правила предложили бы другое, а привычка — оставить: такое видно сразу, не в свёрнутом списке.
            let habitual = model.suggestions.filter { $0.duplicateGroup == nil && $0.action == .keep && $0.habit }
            if !habitual.isEmpty {
                CardSection(title: "Оставить, как вы обычно — \(Format.bytes(habitual.reduce(0) { $0 + $1.bytes }))",
                            footer: "Правила предложили бы другое, но похожее вы обычно оставляете. Не согласны — выберите действие в строке: Offload учтёт и это.") {
                    rows(habitual)
                }
            }
            let kept = model.suggestions.filter { $0.duplicateGroup == nil && $0.action == .keep && !$0.habit }
            if !kept.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showKept.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .rotationEffect(.degrees(showKept ? 90 : 0))
                            Text("\(CleanupAction.keep.sectionTitle) — \(kept.count)").font(.headline)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                    if showKept {
                        Card(padding: 0, spacing: 0) { rows(kept) }
                    }
                }
            }
            HStack {
                Button("Отмена") { model.reset() }
                Spacer()
                if needsSafe {
                    Text("Сейф закрыт").font(.callout).foregroundStyle(.secondary)
                }
                Button { confirming = true } label: { Label("Выполнить", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(needsSafe || app.isBusy)
            }
        }
    }

    /// Предложения одного действия; копии одинаковых файлов показываются своими группами.
    @ViewBuilder
    private func section(_ action: CleanupAction) -> some View {
        let group = app.cleanup.suggestions.filter { $0.duplicateGroup == nil && $0.action == action }
        if !group.isEmpty {
            CardSection(title: "\(action.sectionTitle) — \(Format.bytes(group.reduce(0) { $0 + $1.bytes }))") {
                rows(group)
            }
        }
    }

    @ViewBuilder
    private func rows(_ group: [CleanupSuggestion]) -> some View {
        ForEach(group) { suggestion in
            CleanupRow(suggestion: suggestion, home: app.rules.home, choice: choiceBinding(suggestion))
            if suggestion.id != group.last?.id { RowDivider(inset: 58) }
        }
    }

    private func choiceBinding(_ suggestion: CleanupSuggestion) -> Binding<CleanupAction> {
        Binding(get: { app.cleanup.choice(for: suggestion) },
                set: { app.cleanup.setChoice($0, for: suggestion) })
    }

    // MARK: - Одинаковые файлы

    /// Сколько групп видно сразу: остальные — по кнопке, иначе длинный список тормозил бы.
    private static let visibleGroups = 12

    @ViewBuilder
    private var duplicates: some View {
        let model = app.cleanup
        let groups = model.duplicateGroups
        if !groups.isEmpty {
            let shown = showAllDuplicates ? groups : Array(groups.prefix(Self.visibleGroups))
            let freed = groups.reduce(Int64(0)) { $0 + model.freedBytes(in: $1) }
            CardSection(title: "Одинаковые файлы — освободится \(Format.bytes(freed))",
                        footer: "Одна копия всегда остаётся. Перед удалением каждая лишняя копия ещё раз сверяется с ней байт в байт; копии внутри папки, которая уезжает в сейф, едут вместе с ней.") {
                ForEach(shown, id: \.self) { group in
                    duplicateGroup(group)
                    if group != shown.last || shown.count < groups.count { Divider() }
                }
                if shown.count < groups.count {
                    let hidden = groups.count - shown.count
                    Button("Показать ещё \(hidden) \(pluralRu(hidden, "группу", "группы", "групп"))") {
                        withAnimation(.easeInOut(duration: 0.15)) { showAllDuplicates = true }
                    }
                    .buttonStyle(.link)
                    .rowPadding()
                }
            }
        }
    }

    @ViewBuilder
    private func duplicateGroup(_ group: String) -> some View {
        let model = app.cleanup
        let copies = model.copies(in: group)
        if let first = copies.first {
            let freed = model.freedBytes(in: group)
            HStack(spacing: 12) {
                IconTile(systemImage: "doc.on.doc.fill", tone: freed > 0 ? .danger : .neutral, size: 32)
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
            // Копии — со сдвигом под заголовком группы; разделители начинаются там же, где их текст.
            ForEach(copies) { copy in
                RowDivider(inset: 82)
                CleanupRow(suggestion: copy, home: app.rules.home, choice: choiceBinding(copy),
                           options: model.options(for: copy), note: travelNote(copy))
                    .padding(.leading, 24)
            }
        }
    }

    /// Копия выбрана в Корзину, но лежит в папке, которая уезжает в сейф, — едет вместе с папкой.
    private func travelNote(_ copy: CleanupSuggestion) -> String? {
        let model = app.cleanup
        guard model.choice(for: copy) == .trash, let carrier = model.carrier(of: copy) else { return nil }
        return "Уедет в сейф вместе с папкой «\(carrier.url.lastPathComponent)» — удалять её отдельно не буду."
    }

    private func tile(_ action: CleanupAction) -> some View {
        let model = app.cleanup
        let count = model.items(action).count
        return StatTile(value: action == .backup ? "\(count)" : Format.bytes(model.bytes(action)),
                        title: action.title,
                        detail: action == .backup ? pluralRu(count, "папка", "папки", "папок") : "\(count) \(pluralRu(count, "объект", "объекта", "объектов"))",
                        systemImage: action.symbol, tone: count > 0 ? action.tone : .neutral)
    }

    private var summaryText: String {
        let model = app.cleanup
        var parts: [String] = []
        let trash = model.items(.trash)
        for (title, items) in [("В Корзину", trash.filter { $0.duplicateGroup == nil }),
                               ("лишние копии", trash.filter { $0.duplicateGroup != nil }),
                               (CleanupAction.safe.title, model.items(.safe))] where !items.isEmpty {
            parts.append("\(title): \(items.count) (\(Format.bytes(items.reduce(0) { $0 + $1.bytes })))")
        }
        let backup = model.items(.backup).count
        if backup > 0 { parts.append("\(CleanupAction.backup.title): \(backup)") }
        return parts.isEmpty ? "Ничего не меняется — решения только запомнятся." : parts.joined(separator: " · ") + "."
    }

    // MARK: - Итог

    @ViewBuilder
    private func done(_ report: CleanupModel.Report) -> some View {
        let model = app.cleanup
        Card(spacing: 14) {
            HStack(spacing: 14) {
                IconTile(systemImage: report.cancelled ? "stop.circle.fill" : "checkmark.seal.fill",
                         tone: report.cancelled ? .caution : .good, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.cancelled ? "Разбор остановлен" : "Разбор выполнен").font(.title2.weight(.semibold))
                    Text(report.cancelled
                         ? "Сделанное до остановки сохранено, остальное осталось как было. Незаконченная копия убрана."
                         : "Решения запомнены: в следующий раз Offload начнёт с них и учтёт их для похожего.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                result("\(Format.bytes(report.trashedBytes))", "в Корзине · \(report.trashed)")
                result("\(Format.bytes(report.movedBytes))", "в сейфе · \(report.moved)")
                result("\(report.addedToBackup)", "добавлено в бэкап")
            }
            if report.trashed > 0 {
                Notice(.info, (report.duplicates > 0
                               ? "Из них лишних копий: \(report.duplicates) — каждая перед удалением сверена с остающейся байт в байт. " : "")
                       + "Место от удалённого освободится, когда вы очистите Корзину. До этого всё можно вернуть из неё.")
            }
            if report.addedToBackup > 0 {
                HStack {
                    Text("Новые папки в списке бэкапа. Обновите бэкап, чтобы они в него попали.").font(.callout)
                    Spacer()
                    Button("Открыть «Бэкап»") { app.section = .backup }
                }
            }
            if !report.problems.isEmpty {
                Notice(.warning, "Не всё получилось:", details: report.problems)
            }
            HStack {
                Button("Готово") { model.reset() }
                Button("Разобрать ещё раз") {
                    model.reset()
                    model.scan(app: app)
                }
            }
        }
    }

    private func result(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Строка предложения: что это, почему так предлагается и что выбрано.
struct CleanupRow: View {
    let suggestion: CleanupSuggestion
    let home: URL
    @Binding var choice: CleanupAction
    /// Что можно выбрать сейчас; по умолчанию — всё, что разрешают правила.
    var options: [CleanupAction]?
    /// Пояснение к выбору, например что копия уедет в сейф вместе с папкой.
    var note: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemImage: suggestion.isDirectory ? "folder.fill" : "doc.fill", tone: choice.tone, size: 32)
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
                if choice == .safe {
                    ForEach(suggestion.cautions, id: \.self) { note in
                        Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
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
            .frame(width: 120, alignment: .trailing)
            let choices = options ?? suggestion.allowed
            Picker("Действие", selection: $choice) {
                ForEach(choices, id: \.self) { action in
                    Label(action.title, systemImage: action.symbol).tag(action)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(choices.count == 1)
            .help(choices.count > 1 ? "Что сделать"
                  : suggestion.allowed.count > 1 ? "Это последняя остающаяся копия: чтобы удалить её, оставьте другую" : "Это трогать нельзя")
        }
        .rowPadding()
        .contextMenu {
            Button("Показать в Finder") { revealInFinder(suggestion.url) }
        }
    }
}
