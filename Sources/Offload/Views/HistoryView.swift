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

struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @State private var pendingRestore: MoveRecord?
    @State private var showImport = false

    var body: some View {
        let model = app.history
        VStack(spacing: 0) {
            if let busy = model.busyID, let record = model.records.first(where: { $0.id == busy }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Возвращаю «\(URL(fileURLWithPath: record.originalPath).lastPathComponent)»").font(.headline)
                        Spacer()
                        Button("Отменить") { model.cancel() }
                    }
                    ProgressView(value: model.progress?.fraction ?? 0) { Text(model.progress?.phase.rawValue ?? "Подготовка") }
                }
                .padding(14)
                Divider()
            }
            if let message = model.message {
                Notice(message).padding(12)
            }
            if model.records.isEmpty {
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
                summary(model.records)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(HistoryGroup.make(model.records)) { group in
                            if group.isSingle {
                                // Отступ под шеврон групп: значки всех строк стоят в одну колонку.
                                HistoryRow(record: group.first, home: app.rules.home, available: model.isArchiveAvailable(group.first),
                                           archiveExists: model.archiveExists(group.first),
                                           busy: model.busyID != nil, onRestore: { pendingRestore = group.first })
                                    .padding(.leading, 40)
                                    .padding(.trailing, 16)
                            } else {
                                HistoryGroupRow(group: group, home: app.rules.home, busy: model.busyID != nil,
                                                isAvailable: { model.isArchiveAvailable($0) },
                                                archiveExists: { model.archiveExists($0) }, onRestore: { pendingRestore = $0 })
                            }
                            Divider().padding(.leading, 16)
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
        return HStack(spacing: 32) {
            SummaryStat(value: Format.bytes(onDisks.reduce(0) { $0 + $1.bytes }), title: "лежит на внешних дисках")
            SummaryStat(value: "\(onDisks.count)", title: pluralRu(onDisks.count, "перенесённый объект", "перенесённых объекта", "перенесённых объектов"))
            SummaryStat(value: "\(records.count - onDisks.count)", title: "возвращено на Mac")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct SummaryStat: View {
    let value: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
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
                    Image(systemName: group.first.restored ? "arrow.uturn.backward.circle.fill" : "square.stack.3d.up.fill")
                        .foregroundStyle(group.first.restored ? Color.green : Color.accentColor)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\((group.originalParent as NSString).lastPathComponent) · \(group.records.count) \(pluralRu(group.records.count, "объект", "объекта", "объектов"))")
                            .fontWeight(.medium)
                        Text(relativeToHome(group.originalParent, home: home)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Text("\(group.latest.formatted(date: .abbreviated, time: .shortened)) · \(Format.bytes(group.bytes)) · файлов \(group.files) · "
                             + (group.first.isEncrypted ? "в сейфе «\(group.first.volumeName)»" : "открыто на «\(group.first.volumeName)»"))
                            .font(.caption).foregroundStyle(.secondary)
                        if let note = group.note, !note.isEmpty {
                            Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if group.first.restored {
                        Text("Возвращено").foregroundStyle(.green).font(.callout)
                    } else if !group.records.contains(where: isAvailable) {
                        Text(group.first.isEncrypted ? "Сейф закрыт" : "Диск не подключён").foregroundStyle(.secondary).font(.callout)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(group.records) { record in
                    HistoryRow(record: record, home: home, available: isAvailable(record),
                               archiveExists: archiveExists(record), busy: busy, onRestore: { onRestore(record) })
                        .padding(.leading, 64)
                        .padding(.trailing, 16)
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.restored ? "arrow.uturn.backward.circle.fill" : (record.isEncrypted ? "lock.fill" : "externaldrive.fill"))
                .foregroundStyle(record.restored ? Color.green : Color.accentColor)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: record.originalPath).lastPathComponent).fontWeight(.medium)
                Text(relativeToHome(record.originalPath, home: home)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(record.date.formatted(date: .abbreviated, time: .shortened)) · \(Format.bytes(record.bytes)) · файлов \(record.files) · "
                     + (record.isEncrypted ? "в сейфе «\(record.volumeName)»" : "открыто на «\(record.volumeName)»"))
                    .font(.caption).foregroundStyle(.secondary)
                if let note = record.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if archiveExists {
                Button { revealInFinder(URL(fileURLWithPath: record.archivedPath)) } label: { Image(systemName: "magnifyingglass") }
                    .help("Показать на диске")
            }
            if record.restored {
                Text("Возвращено").foregroundStyle(.green).font(.callout)
            } else if available {
                Button("Вернуть…", action: onRestore).disabled(busy)
            } else {
                Text(record.isEncrypted ? "Сейф закрыт" : "Диск не подключён").foregroundStyle(.secondary).font(.callout)
            }
        }
        .buttonStyle(.bordered)
        .padding(.vertical, 8)
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Добавить перенесённое вручную").font(.title3.weight(.semibold))
            Text("Для папок и файлов, которые вы уже перенесли на внешний диск без Offload. Запись появится в списке, и вернуть их на Mac можно будет как обычно — со сверкой.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LabeledContent("На диске") {
                HStack {
                    Text(archive.map { relativeToVolume($0) } ?? "не выбрано")
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(archive == nil ? .secondary : .primary)
                    Spacer()
                    Button("Выбрать…") { pickArchive() }
                }
            }
            LabeledContent("Было на Mac в папке") {
                HStack {
                    Text(originalParent.map { relativeToHome($0.path, home: app.rules.home) } ?? "не выбрано")
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(originalParent == nil ? .secondary : .primary)
                    Spacer()
                    Button("Выбрать…") { pickParent() }
                }
            }
            LabeledContent("Под именем") {
                TextField("имя папки или файла", text: $originalName).textFieldStyle(.roundedBorder)
            }
            Toggle("Оригинал уже удалён с Mac", isOn: $originalRemoved)
            TextField("Заметка, например «упаковано в tar.gz» (необязательно)", text: $note, axis: .vertical).lineLimit(1...3)
            if let error { Notice(.error, error) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Добавить") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(archive == nil || originalParent == nil || originalName.isEmpty || busy)
            }
        }
        .padding(22)
        .frame(width: 580)
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
