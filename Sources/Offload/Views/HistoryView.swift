import OffloadCore
import SwiftUI

/// Несколько записей из одной папки (например, старые версии прошивки) показываются одной раскрываемой строкой.
struct HistoryGroup: Identifiable {
    let id: String
    let records: [MoveRecord]

    static let minimumSize = 3

    var isSingle: Bool { records.count == 1 }
    var first: MoveRecord { records[0] }
    var bytes: Int64 { records.reduce(0) { $0 + $1.bytes } }
    var files: Int { records.reduce(0) { $0 + $1.files } }
    var latest: Date { records.map(\.date).max() ?? first.date }
    var originalParent: String { (first.originalPath as NSString).deletingLastPathComponent }
    /// Заметка, если она у всех записей одинаковая.
    var note: String? { Set(records.map { $0.note ?? "" }).count == 1 ? first.note : nil }

    static func make(_ records: [MoveRecord]) -> [HistoryGroup] {
        var buckets: [String: [MoveRecord]] = [:]
        for record in records {
            let key = [(record.originalPath as NSString).deletingLastPathComponent,
                       (record.archivedPath as NSString).deletingLastPathComponent,
                       record.restored ? "restored" : "moved"].joined(separator: "\u{1}")
            buckets[key, default: []].append(record)
        }
        var groups: [HistoryGroup] = []
        for (key, items) in buckets {
            if items.count >= minimumSize {
                let sorted = items.sorted { $0.originalPath.localizedStandardCompare($1.originalPath) == .orderedAscending }
                groups.append(HistoryGroup(id: key, records: sorted))
            } else {
                groups += items.map { HistoryGroup(id: $0.id.uuidString, records: [$0]) }
            }
        }
        return groups.sorted { ($0.latest, $0.id) > ($1.latest, $1.id) }
    }
}

/// Как выглядит запись: в сейфе — зелёный замок, открыто на диске — оранжевый диск, возвращённая — серая стрелка.
extension MoveRecord {
    var symbol: String { restored ? "arrow.uturn.backward" : (isEncrypted ? "lock.fill" : "externaldrive.fill") }
    var tone: Tone { restored ? .neutral : (isEncrypted ? .good : .caution) }
    var location: String { isEncrypted ? "в сейфе «\(volumeName)»" : "открыто на «\(volumeName)»" }
    /// Почему вернуть сейчас нельзя.
    var unavailableReason: String { isEncrypted ? "Сейф закрыт" : "Диск не подключён" }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @State private var pendingRestore: MoveRecord?
    @State private var showImport = false

    var body: some View {
        let model = app.history
        VStack(spacing: 0) {
            if let busy = model.busyID, let record = model.records.first(where: { $0.id == busy }) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Возвращаю «\(URL(fileURLWithPath: record.originalPath).lastPathComponent)»").font(.headline)
                        Spacer()
                        Text(model.progress?.phase.rawValue ?? "Подготовка").foregroundStyle(.secondary)
                        Button("Отменить") { model.cancel() }
                    }
                    ProgressView(value: model.progress?.fraction ?? 0)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                Divider()
            }
            if model.records.isEmpty {
                if let message = model.message {
                    Notice(message).padding(16)
                }
                ContentUnavailableView {
                    Label("Пока ничего не перенесено", systemImage: "tray")
                } description: {
                    Text(app.destination == nil
                         ? "Перенесённые на внешний диск папки и файлы появятся здесь. Подключите диск и выберите его внизу боковой панели — тогда можно будет добавить в журнал и то, что вы перенесли раньше без Offload."
                         : "Перенесённые на внешний диск папки и файлы появятся здесь. Вернуть их можно, пока диск подключён. То, что вы перенесли раньше без Offload, можно добавить вручную.")
                } actions: {
                    Button("Добавить вручную…") { showImport = true }
                        .disabled(app.destination == nil)
                        .help(app.destination == nil ? "Нужен подключённый внешний диск" : "")
                }
            } else {
                PageScroll {
                    if let message = model.message { Notice(message) }
                    summary(model.records)
                    Card(padding: 0, spacing: 0) {
                        let groups = HistoryGroup.make(model.records)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(groups) { group in
                                if group.isSingle {
                                    // Отступ под шеврон групп: значки всех строк стоят в одну колонку.
                                    HistoryRow(record: group.first, home: app.rules.home, available: model.isArchiveAvailable(group.first),
                                               archiveExists: model.archiveExists(group.first),
                                               busy: model.busyID != nil, onRestore: { pendingRestore = group.first })
                                        .padding(.leading, 38)
                                        .padding(.trailing, 14)
                                } else {
                                    HistoryGroupRow(group: group, home: app.rules.home, busy: model.busyID != nil,
                                                    isAvailable: { model.isArchiveAvailable($0) },
                                                    archiveExists: { model.archiveExists($0) }, onRestore: { pendingRestore = $0 })
                                }
                                if group.id != groups.last?.id { RowDivider() }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Перенесённое")
        .toolbar {
            Button { showImport = true } label: { Label("Добавить вручную…", systemImage: "plus") }
                .disabled(app.destination == nil)
                .help(app.destination == nil
                      ? "Нужен подключённый внешний диск: выберите его внизу боковой панели"
                      : "Зарегистрировать папку или файл, уже перенесённые на внешний диск без Offload")
        }
        .sheet(isPresented: $showImport) { ImportSheet() }
        .task(id: app.historyVolumes.map(\.id)) { model.reload(volumes: app.historyVolumes) }
        .confirmationDialog("Вернуть на Mac?",
                            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
                            presenting: pendingRestore) { record in
            Button("Вернуть и оставить копию на диске") { model.restore(record, deleteArchive: false, app: app) }
            Button("Вернуть и удалить с диска", role: .destructive) { model.restore(record, deleteArchive: true, app: app) }
            Button("Отмена", role: .cancel) {}
        } message: { record in
            Text("«\(relativeToHome(record.originalPath, home: app.rules.home))» будет скопирован обратно: каждый файл перечитывается с диска и сверяется по SHA-256 со списком, записанным при переносе. На Mac понадобится \(Format.bytes(record.bytes)).")
        }
    }

    private func summary(_ records: [MoveRecord]) -> some View {
        let onDisks = records.filter { !$0.restored }
        let open = onDisks.filter { !$0.isEncrypted }.count
        return HStack(alignment: .top, spacing: 16) {
            StatTile(value: Format.bytes(onDisks.reduce(0) { $0 + $1.bytes }), title: "лежит на внешних дисках",
                     systemImage: "externaldrive.fill")
            StatTile(value: "\(onDisks.count)",
                     title: pluralRu(onDisks.count, "перенесённый объект", "перенесённых объекта", "перенесённых объектов"),
                     detail: "в сейфе \(onDisks.count - open) · открыто \(open)",
                     systemImage: open > 0 ? "lock.open.fill" : "lock.fill", tone: open > 0 ? .caution : .good)
            StatTile(value: "\(records.count - onDisks.count)", title: "возвращено на Mac",
                     systemImage: "arrow.uturn.backward", tone: .neutral)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct HistoryGroupRow: View {
    let group: HistoryGroup
    let home: URL
    let busy: Bool
    let isAvailable: (MoveRecord) -> Bool
    let archiveExists: (MoveRecord) -> Bool
    let onRestore: (MoveRecord) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                    IconTile(systemImage: group.first.restored ? "arrow.uturn.backward" : "square.stack.3d.up.fill",
                             tone: group.first.restored ? .neutral : .brand, size: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\((group.originalParent as NSString).lastPathComponent) · \(group.records.count) \(pluralRu(group.records.count, "объект", "объекта", "объектов"))")
                            .fontWeight(.medium)
                        Text(relativeToHome(group.originalParent, home: home)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Text("\(group.latest.formatted(date: .abbreviated, time: .shortened)) · \(Format.bytes(group.bytes)) · файлов \(group.files) · \(group.first.location)")
                            .font(.caption).foregroundStyle(.secondary)
                        if let note = group.note, !note.isEmpty {
                            Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if group.first.restored {
                        StatusPill(title: "Возвращено", systemImage: "checkmark", tone: .good)
                    } else if !group.records.contains(where: isAvailable) {
                        StatusPill(title: group.first.unavailableReason, tone: .neutral)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(group.records) { record in
                    RowDivider(inset: 82)
                    HistoryRow(record: record, home: home, available: isAvailable(record),
                               archiveExists: archiveExists(record), busy: busy, onRestore: { onRestore(record) })
                        .padding(.leading, 82)
                        .padding(.trailing, 14)
                }
            }
        }
    }
}

struct HistoryRow: View {
    let record: MoveRecord
    let home: URL
    let available: Bool
    /// Считается один раз при перечитывании списка: опрос внешнего диска из тела строки
    /// будил бы уснувший диск при каждой перерисовке.
    let archiveExists: Bool
    let busy: Bool
    let onRestore: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: record.symbol, tone: record.tone, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: record.originalPath).lastPathComponent).fontWeight(.medium)
                Text(relativeToHome(record.originalPath, home: home)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(record.date.formatted(date: .abbreviated, time: .shortened)) · \(Format.bytes(record.bytes)) · файлов \(record.files) · \(record.location)")
                    .font(.caption).foregroundStyle(.secondary)
                if let note = record.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if archiveExists {
                // Лупа видна под мышью: в каждой строке сразу она только шумела бы.
                Button { revealInFinder(URL(fileURLWithPath: record.archivedPath)) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Показать на диске")
                    .opacity(hovering ? 1 : 0)
            }
            if record.restored {
                StatusPill(title: "Возвращено", systemImage: "checkmark", tone: .good)
            } else if available {
                Button("Вернуть…", action: onRestore)
                    .buttonStyle(.bordered)
                    .disabled(busy)
            } else {
                StatusPill(title: record.unavailableReason, tone: .neutral)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if archiveExists {
                Button("Показать на диске") { revealInFinder(URL(fileURLWithPath: record.archivedPath)) }
            }
            if available, !record.restored {
                Button("Вернуть…", action: onRestore).disabled(busy)
            }
        }
    }
}

/// Регистрация переноса, сделанного без Offload.
struct ImportSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var archive: URL?
    @State private var originalParent: URL?
    @State private var originalName = ""
    @State private var originalRemoved = true
    @State private var note = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        SheetLayout(systemImage: "plus.rectangle.on.folder", title: "Добавить перенесённое вручную",
                    subtitle: "Для папок и файлов, которые вы уже перенесли на внешний диск без Offload. Запись появится в списке, и вернуть их на Mac можно будет как обычно — со сверкой.",
                    width: 580) {
            VStack(spacing: 0) {
                pickRow("На диске", value: archive.map { relativeToVolume($0) }, action: pickArchive)
                RowDivider()
                pickRow("Было на Mac в папке", value: originalParent.map { relativeToHome($0.path, home: app.rules.home) }, action: pickParent)
                RowDivider()
                FormRow(title: "Под именем") {
                    TextField("имя папки или файла", text: $originalName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Toggle("Оригинал уже удалён с Mac", isOn: $originalRemoved)
            TextField("Заметка, например «упаковано в tar.gz» (необязательно)", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            if let error { Notice(.error, error) }
        } actions: {
            Button("Отмена") { dismiss() }
            Button("Добавить") { add() }
                .keyboardShortcut(.defaultAction)
                .disabled(archive == nil || originalParent == nil || originalName.isEmpty || busy)
        }
    }

    private func pickRow(_ title: String, value: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Text(value ?? "не выбрано")
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(value == nil ? .secondary : .primary)
            Button("Выбрать…", action: action)
        }
        .rowPadding()
    }

    private func relativeToVolume(_ url: URL) -> String {
        guard let root = app.destination?.mountPoint.path, url.path.hasPrefix(root + "/") else { return url.path }
        return "«\(app.destination?.name ?? "")» / " + url.path.dropFirst(root.count + 1)
    }

    private func pickArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = app.destination?.mountPoint
        panel.prompt = "Выбрать"
        panel.message = "Что лежит на внешнем диске"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        archive = url
        if originalName.isEmpty { originalName = url.lastPathComponent }
    }

    private func pickParent() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = app.rules.home
        panel.prompt = "Выбрать"
        panel.message = "Папка на Mac, где это лежало"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        originalParent = url
    }

    private func add() {
        guard let archive, let originalParent else { return }
        busy = true
        error = nil
        let original = originalParent.appendingPathComponent(originalName)
        let rules = app.rules
        let removed = originalRemoved
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try SafeMover(rules: rules).importRecord(archived: archive, original: original, originalRemoved: removed,
                                                             note: text.isEmpty ? nil : text)
                }.value
                app.history.reload(volumes: app.historyVolumes)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
