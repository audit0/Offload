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
        // В демонстрации сразу показываем предложения — снимку экрана нечего ждать.
        .task { if Demo.isOn, model.stage == .idle { model.scan(app: app) } }
        .confirmationDialog("Выполнить разбор?", isPresented: $confirming) {
            Button("Выполнить") { model.run(app: app) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(summaryText + " Удалённое лежит в Корзине, пока вы её не очистите; в сейф переносится со сверкой каждого файла.")
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
                        Text("Offload посмотрит, что занимает место, и предложит: что удалить, что убрать в сейф, что добавить в бэкап. Вы поправите, где не согласны, — и только потом что-то произойдёт.")
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
            return "Только то, что пересоздаётся само или скачивается заново: кеши сборки, скачанные пакеты, старые установщики. Всё уходит в Корзину — передумать можно, пока она не очищена."
        case .safe:
            return "Большое и давно не нужное. Переносится со сверкой каждого файла, оригинал удаляется только после неё; вернуть можно в «Перенесённом»."
        case .backup:
            return "Проекты с git — в список папок бэкапа. Сам бэкап запускается в разделе «Бэкап»."
        case .keep:
            return "То, чем вы пользуетесь, и то, что трогать нельзя. Ваши решения запоминаются: в следующий раз Offload предложит то же, что вы выбрали."
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
                    Text(progress.total == 0 ? "Собираю, что посмотреть…" : "Смотрю, что занимает место")
                        .font(.title3.weight(.semibold))
                    Text(progress.current.isEmpty ? " " : progress.current)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                if progress.total > 0 {
                    Text("\(progress.done) из \(progress.total)")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Button("Отменить") { app.cleanup.cancel() }
            }
            ProgressView(value: progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0)
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
            ForEach([CleanupAction.trash, .safe, .backup], id: \.self) { action in
                let group = model.suggestions.filter { $0.action == action }
                if !group.isEmpty {
                    CardSection(title: "\(action.sectionTitle) — \(Format.bytes(group.reduce(0) { $0 + $1.bytes }))") {
                        rows(group)
                    }
                }
            }
            let kept = model.suggestions.filter { $0.action == .keep }
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

    @ViewBuilder
    private func rows(_ group: [CleanupSuggestion]) -> some View {
        ForEach(group) { suggestion in
            CleanupRow(suggestion: suggestion, home: app.rules.home, choice: choiceBinding(suggestion))
            if suggestion.id != group.last?.id { RowDivider(inset: 58) }
        }
    }

    private func choiceBinding(_ suggestion: CleanupSuggestion) -> Binding<CleanupAction> {
        Binding(get: { app.cleanup.choice(for: suggestion) },
                set: { app.cleanup.choices[suggestion.id] = $0 })
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
        for action in [CleanupAction.trash, .safe, .backup] {
            let count = model.items(action).count
            guard count > 0 else { continue }
            parts.append(action == .backup ? "\(action.title): \(count)" : "\(action.title): \(count) (\(Format.bytes(model.bytes(action))))")
        }
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
                         : "Решения запомнены: в следующий раз Offload начнёт с них.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                result("\(Format.bytes(report.trashedBytes))", "в Корзине · \(report.trashed)")
                result("\(Format.bytes(report.movedBytes))", "в сейфе · \(report.moved)")
                result("\(report.addedToBackup)", "добавлено в бэкап")
            }
            if report.trashed > 0 {
                Notice(.info, "Место от удалённого освободится, когда вы очистите Корзину. До этого всё можно вернуть из неё.")
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemImage: suggestion.isDirectory ? "folder.fill" : "doc.fill", tone: choice.tone, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(suggestion.url.lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    if suggestion.learned {
                        StatusPill(title: "как в прошлый раз", systemImage: "clock.arrow.circlepath", tone: .brand)
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
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.bytes(suggestion.bytes)).fontWeight(.semibold).monospacedDigit()
                if let modified = suggestion.modified {
                    Text(Format.relative(modified)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 120, alignment: .trailing)
            Picker("Действие", selection: $choice) {
                ForEach(suggestion.allowed, id: \.self) { action in
                    Label(action.title, systemImage: action.symbol).tag(action)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(suggestion.allowed.count == 1)
            .help(suggestion.allowed.count == 1 ? "Это трогать нельзя" : "Что сделать")
        }
        .rowPadding()
        .contextMenu {
            Button("Показать в Finder") { revealInFinder(suggestion.url) }
        }
    }
}
