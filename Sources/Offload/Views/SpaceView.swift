import OffloadCore
import SwiftUI

struct SpaceView: View {
    @Environment(AppModel.self) private var app
    @State private var moveItem: SpaceItem?
    @State private var moved = false

    var body: some View {
        let model = app.space
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.goUp(rules: app.rules) } label: { Image(systemName: "chevron.left") }
                    .disabled(model.location == nil)
                    .help("Наверх")
                Text(model.title(home: app.rules.home)).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Text("Считаю…").foregroundStyle(.secondary)
                }
                Button { model.rescan(rules: app.rules) } label: { Label("Пересчитать", systemImage: "arrow.clockwise") }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if !app.hasFullDiskAccess { FullDiskAccessBanner().padding(12) }
            // Не List: AppKit-таблица под ним при быстром обновлении строк во время подсчёта
            // выдаёт «reentrant operation in NSTableView delegate» и ломает раскладку окна.
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.visibleItems) { item in
                        SpaceRow(item: item, largest: model.largest,
                                 onOpen: { model.open(item.url, rules: app.rules) },
                                 onMove: { moveItem = item })
                        Divider().padding(.leading, 48)
                    }
                    if model.hiddenSmallCount > 0, !model.isScanning {
                        Text("И ещё \(model.hiddenSmallCount) объектов меньше 1 МБ")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            }
            .overlay {
                if model.items.isEmpty, model.isScanning { ProgressView("Считаю размеры…") }
            }
        }
        .navigationTitle("Что занимает место")
        .task {
            if model.items.isEmpty, !model.isScanning { model.open(model.location, rules: app.rules) }
        }
        // Пересчитывать список после закрытия окна имеет смысл только если перенос был:
        // иначе «посмотрел размер и закрыл» стирало весь кеш и считало папку заново десятки секунд.
        .sheet(item: $moveItem, onDismiss: {
            guard moved else { return }
            moved = false
            app.space.invalidateAll()
            app.space.rescan(rules: app.rules)
            app.refreshVolumes()
        }) { item in
            MoveSheet(source: item.url, onMoved: { moved = true })
        }
    }
}

struct SpaceRow: View {
    let item: SpaceItem
    let largest: Int64
    let onOpen: () -> Void
    let onMove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.url.lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    if item.accessDenied {
                        Text(item.bytes > 0 ? "не всё доступно" : "нет доступа").font(.caption).foregroundStyle(.orange)
                    }
                }
                SizeBar(fraction: Double(item.bytes) / Double(largest)).frame(maxWidth: 360)
                if let note = item.verdict.notes.first, item.verdict != .safe {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                if item.isMeasured {
                    Text(Format.bytes(item.bytes)).monospacedDigit().fontWeight(.semibold)
                } else {
                    ProgressView().controlSize(.small)
                }
                if let modified = item.modified {
                    Text(Format.relative(modified)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 130, alignment: .trailing)
            VerdictBadge(verdict: item.verdict).frame(width: 130, alignment: .leading)
            HStack(spacing: 6) {
                if item.isDirectory { Button("Открыть", action: onOpen) }
                Button { revealInFinder(item.url) } label: { Image(systemName: "magnifyingglass") }
                    .help("Показать в Finder")
                Button("Перенести…", action: onMove).disabled(item.verdict.isBlocked)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if item.isDirectory { onOpen() } }
    }
}

struct MoveSheet: View {
    let source: URL
    let onMoved: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model = MoveModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.plus").font(.title).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Перенести «\(source.lastPathComponent)»").font(.title3.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text(relativeToHome(source.path, home: app.rules.home)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            if let volume = app.destination {
                content(volume: volume)
            } else {
                Notice(.warning, "Подключите внешний диск и выберите его внизу боковой панели.")
            }
            HStack {
                Spacer()
                switch model.stage {
                case .inspecting, .running:
                    Button("Отменить") { model.cancel() }
                case .ready(let plan):
                    Button("Закрыть") { dismiss() }
                    Button("Перенести") { model.run(plan, app: app) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canRun(plan))
                default:
                    Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 600)
        // Esc запрещаем только во время самого копирования; на этапе проверки закрывать окно можно.
        .interactiveDismissDisabled({ if case .running = model.stage { return true } else { return false } }())
        .onChange(of: model.didMove) { if model.didMove { onMoved() } }
        // Esc на этапе проверки закрывает окно, но обход дерева шёл бы дальше: на большой папке
        // это десятки секунд впустую, и остановить их было бы уже нечем — окна нет.
        .onDisappear { model.cancel() }
        .task(id: app.destinationID) {
            if let volume = app.destination { model.prepare(source: source, volume: volume, rules: app.rules) }
        }
    }

    @ViewBuilder
    private func content(volume: VolumeInfo) -> some View {
        let bindable = Bindable(model)
        switch model.stage {
        case .idle, .inspecting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Проверяю содержимое, открытые файлы и диск «\(volume.name)»…").foregroundStyle(.secondary)
            }
        case .ready(let plan):
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Размер") {
                    Text("\(Format.bytes(plan.content.logicalBytes)) · файлов \(plan.content.files) · папок \(max(0, plan.content.directories - 1))")
                }
                LabeledContent("Куда") {
                    Text(plan.target.path).lineLimit(1).truncationMode(.head).textSelection(.enabled)
                }
                switch plan.verdict {
                case .blocked(let reason):
                    Notice(.error, reason)
                case .caution(let notes):
                    ForEach(notes, id: \.self) { Notice(.warning, $0) }
                    Toggle("Понимаю, переносить всё равно", isOn: bindable.acceptCautions)
                case .safe:
                    EmptyView()
                }
                ForEach(plan.check.blockers, id: \.self) { Notice(.error, $0) }
                ForEach(plan.check.notes, id: \.self) { Notice(.info, $0) }
                Toggle("Удалить оригинал после сверки", isOn: bindable.deleteOriginal)
                Text(model.deleteOriginal
                     ? "Оригинал удаляется только после того, как каждый файл копии перечитан с диска и сверен по SHA-256."
                     : "Останется копия на диске, место на Mac не освободится.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .running(let progress):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress.fraction) { Text(progress.phase.rawValue) }
                Text("\(Format.bytes(progress.bytesDone)) из \(Format.bytes(progress.bytesTotal))").monospacedDigit().font(.caption)
                Text(progress.item).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        case .done(let record):
            VStack(alignment: .leading, spacing: 10) {
                Notice(.success, record.originalRemoved
                       ? "Перенесено и сверено: \(record.files) файлов, \(Format.bytes(record.bytes)). Оригинал удалён, место на Mac освободилось."
                       : "Скопировано и сверено: \(record.files) файлов, \(Format.bytes(record.bytes)). Оригинал на месте.")
                Button("Показать на диске") { revealInFinder(URL(fileURLWithPath: record.archivedPath)) }
                Text("Вернуть обратно можно в разделе «Перенесённое».").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Notice(.error, message)
        }
    }
}
