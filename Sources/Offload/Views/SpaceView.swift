import OffloadCore
import SwiftUI

struct SpaceView: View {
    @Environment(AppModel.self) private var app
    @State private var moveItem: SpaceItem?
    @State private var moved = false
    @State private var utmItem: SpaceItem?

    var body: some View {
        let model = app.space
        VStack(spacing: 0) {
            header(model)
            Divider()
            if !app.hasFullDiskAccess { FullDiskAccessBanner().padding(12) }
            // Не List: AppKit-таблица под ним при быстром обновлении строк во время подсчёта
            // выдаёт «reentrant operation in NSTableView delegate» и ломает раскладку окна.
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.visibleItems) { item in
                        SpaceRow(item: item, largest: model.largest,
                                 appData: AppData.kind(of: item.url, home: app.rules.home),
                                 onOpen: { model.open(item.url, rules: app.rules) },
                                 onMove: { moveItem = item },
                                 onFree: { free(item) })
                    }
                    if model.hiddenSmallCount > 0, !model.isScanning {
                        Text("И ещё \(model.hiddenSmallCount) объектов меньше 1 МБ")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .overlay {
                if model.items.isEmpty, model.isScanning { ProgressView("Считаю размеры…") }
            }
        }
        .navigationTitle("Освободить место")
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
        .sheet(item: $utmItem) { item in UTMSheet(item: item) }
    }

    /// Docker освобождается в своём разделе, машины UTM — в самом UTM: лист объясняет, как.
    private func free(_ item: SpaceItem) {
        switch AppData.kind(of: item.url, home: app.rules.home) {
        case .docker?: app.section = .docker
        case .utm?: utmItem = item
        case nil: break
        }
    }

    /// Где мы, сколько здесь всего и на что это делится по пометкам.
    private func header(_ model: SpaceModel) -> some View {
        let measured = model.items.filter(\.isMeasured)
        let total = measured.reduce(Int64(0)) { $0 + $1.bytes }
        func sum(_ matches: (Verdict) -> Bool) -> Int64 {
            measured.filter { matches($0.verdict) }.reduce(0) { $0 + $1.bytes }
        }
        let movable = sum { $0 == .safe }
        let blocked = sum(\.isBlocked)
        let caution = total - movable - blocked
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button { model.goUp(rules: app.rules) } label: { Image(systemName: "chevron.left") }
                    .disabled(model.location == nil)
                    .help("Наверх")
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title(home: app.rules.home))
                        .font(.title3.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text(!model.isScanning ? "\(Format.bytes(total)) · \(model.items.count) \(pluralRu(model.items.count, "объект", "объекта", "объектов"))"
                         : model.items.isEmpty ? "Считаю…" : "Считаю: \(measured.count) из \(model.items.count)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.small)
                }
                Button { model.rescan(rules: app.rules) } label: { Label("Пересчитать", systemImage: "arrow.clockwise") }
            }
            if total > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    StackedBar(parts: [
                        StackedBar.Part(fraction: Double(movable) / Double(total), color: .green),
                        StackedBar.Part(fraction: Double(caution) / Double(total), color: .orange),
                        StackedBar.Part(fraction: Double(blocked) / Double(total), color: Color.secondary.opacity(0.45)),
                    ])
                    HStack(spacing: 18) {
                        legend("Можно перенести", bytes: movable, color: .green)
                        legend("С оговорками", bytes: caution, color: .orange)
                        legend("Не трогать", bytes: blocked, color: Color.secondary.opacity(0.45))
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func legend(_ title: String, bytes: Int64, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(.secondary)
            Text(Format.bytes(bytes)).fontWeight(.medium).monospacedDigit()
        }
        .font(.caption)
    }
}

struct SpaceRow: View {
    let item: SpaceItem
    let largest: Int64
    /// Данные Docker или UTM: место из-под них освобождается средствами самих приложений.
    var appData: AppData?
    let onOpen: () -> Void
    let onMove: () -> Void
    var onFree: () -> Void = {}
    @State private var hovering = false

    private var icon: String {
        switch appData {
        case .docker?: return "shippingbox.fill"
        case .utm?: return "desktopcomputer"
        case nil: return item.isDirectory ? "folder.fill" : "doc.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: icon, tone: item.isDirectory ? .brand : .neutral, size: 32)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.url.lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    if item.accessDenied {
                        StatusPill(title: item.bytes > 0 ? "не всё доступно" : "нет доступа", tone: .caution)
                    }
                }
                CapacityBar(fraction: Double(item.bytes) / Double(largest), height: 5).frame(maxWidth: 320)
                if let note = item.verdict.notes.first, item.verdict != .safe {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
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
            VerdictBadge(verdict: item.verdict).frame(width: 140, alignment: .leading)
            HStack(spacing: 6) {
                // Лупа видна под мышью: в каждой строке сразу она только шумела бы.
                Button { revealInFinder(item.url) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Показать в Finder")
                    .opacity(hovering ? 1 : 0)
                if let appData {
                    Button("Как освободить…", action: onFree)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(appData == .docker
                              ? "Открыть раздел «Docker»: очистка образов и кеша сборки, архивация томов"
                              : "Сколько занимает каждая машина и как освободить место через UTM")
                } else if !item.verdict.isBlocked {
                    Button("Перенести…", action: onMove)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button(action: onOpen) { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .help("Открыть")
                    .opacity(item.isDirectory ? 1 : 0)
                    .disabled(!item.isDirectory)
            }
            .frame(width: 180, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(hovering ? Color.primary.opacity(0.05) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if item.isDirectory { onOpen() } }
        .contextMenu {
            if item.isDirectory { Button("Открыть", action: onOpen) }
            Button("Показать в Finder") { revealInFinder(item.url) }
            if appData != nil {
                Divider()
                Button("Как освободить…", action: onFree)
            } else if !item.verdict.isBlocked {
                Divider()
                Button("Перенести…", action: onMove)
            }
        }
    }
}

struct MoveSheet: View {
    let source: URL
    let onMoved: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model = MoveModel()

    var body: some View {
        SheetLayout(systemImage: "externaldrive.badge.plus",
                    title: "Перенести «\(source.lastPathComponent)»",
                    subtitle: relativeToHome(source.path, home: app.rules.home),
                    width: 600) {
            // Когда класть некуда, эта же строка и объясняет почему.
            TargetSummary(problemTone: .caution)
            if let volume = app.target {
                content(volume: volume)
            } else if app.destination != nil, app.storeMode == .safe, app.safe.state?.isEncrypted == true {
                // Сейф закрыт — открываем прямо здесь, не уходя из окна переноса.
                SafeUnlockRow()
                Button("Всё-таки положить открыто на диск «\(app.destination?.name ?? "")»") { app.storeMode = .open }
                    .buttonStyle(.link).font(.caption)
            }
        } actions: {
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
        // Esc запрещаем только во время самого копирования; на этапе проверки закрывать окно можно.
        .interactiveDismissDisabled({ if case .running = model.stage { return true } else { return false } }())
        .onChange(of: model.didMove) { if model.didMove { onMoved() } }
        // Esc на этапе проверки закрывает окно, но обход дерева шёл бы дальше: на большой папке
        // это десятки секунд впустую, и остановить их было бы уже нечем — окна нет.
        .onDisappear { model.cancel() }
        // План зависит от того, куда класть: сейф или открытая часть диска, и от свободного места.
        .task(id: app.target?.id) {
            if let volume = app.target { model.prepare(source: source, volume: volume, rules: app.rules) }
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
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 8) {
                    InfoRow("Размер", value: "\(Format.bytes(plan.content.logicalBytes)) · файлов \(plan.content.files) · папок \(max(0, plan.content.directories - 1))")
                    InfoRow(title: "Куда") {
                        Text(plan.target.path).lineLimit(1).truncationMode(.head).textSelection(.enabled)
                    }
                }
                .font(.callout)
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                if !plan.volume.isEncryptedImage {
                    Notice(.warning, "Копия ляжет на диск открыто: кто получит диск, прочтёт её без пароля. Чтобы зашифровать, выберите внизу боковой панели «В сейф».")
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
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Удалить оригинал после сверки", isOn: bindable.deleteOriginal)
                    Text(model.deleteOriginal
                         ? "Оригинал удаляется только после того, как каждый файл копии перечитан с диска и сверен по SHA-256."
                         : "Останется копия на диске, место на Mac не освободится.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
            }
        case .running(let progress):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(progress.phase.rawValue).fontWeight(.medium)
                    Spacer()
                    Text("\(Format.bytes(progress.bytesDone)) из \(Format.bytes(progress.bytesTotal))")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                ProgressView(value: progress.fraction)
                Text(progress.item).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        case .done(let record):
            VStack(alignment: .leading, spacing: 10) {
                Notice(.success, record.originalRemoved
                       ? "Перенесено и сверено: \(record.files) файлов, \(Format.bytes(record.bytes)). Оригинал удалён, место на Mac освободилось."
                       : "Скопировано и сверено: \(record.files) файлов, \(Format.bytes(record.bytes)). Оригинал на месте.")
                if record.isEncrypted {
                    Label("Лежит в сейфе — зашифровано.", systemImage: "lock.fill").foregroundStyle(.green).font(.callout)
                }
                HStack {
                    Button("Показать на диске") { revealInFinder(URL(fileURLWithPath: record.archivedPath)) }
                    Text("Вернуть обратно можно в разделе «Перенесённое».").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Notice(.error, message)
        }
    }
}
