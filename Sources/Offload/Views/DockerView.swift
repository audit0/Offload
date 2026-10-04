import OffloadCore
import SwiftUI

struct DockerView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmArchive = false
    @State private var restoreArchive: URL?
    @State private var restoreName = ""
    @State private var showPrune = false

    var body: some View {
        let model = app.docker
        @Bindable var bindable = model
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch model.status {
            case .unknown, .checking:
                ProgressView(tr("Спрашиваю Docker…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notInstalled:
                ContentUnavailableView(tr("Docker не установлен"), systemImage: "shippingbox",
                                       description: Text(tr("Этот раздел нужен, только если вы пользуетесь Docker.")))
            case .notRunning:
                ContentUnavailableView {
                    Label(tr("Docker не запущен"), systemImage: "shippingbox")
                } description: {
                    Text(tr("Откройте Docker Desktop и обновите список."))
                } actions: {
                    Button(tr("Обновить")) { model.reload(app: app) }
                }
            case .ready:
                usageBand
                Divider()
                Table(model.volumes, selection: $bindable.selection) {
                    TableColumn(tr("Том")) { volume in
                        Text(volume.name).lineLimit(1).truncationMode(.middle)
                    }
                    TableColumn(tr("Размер")) { volume in
                        if let bytes = volume.sizeBytes {
                            Text(Format.bytes(bytes)).monospacedDigit()
                        } else if model.sizing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("—").foregroundStyle(Theme.muted)
                        }
                    }
                    .width(90)
                    TableColumn(tr("Создан")) { volume in
                        Text(volume.createdAt.map { Format.relative($0) } ?? "—")
                    }
                    .width(140)
                    TableColumn(tr("Последнее изменение")) { volume in
                        if let date = model.activity[volume.name] {
                            Text(Format.relative(date))
                        } else if model.checking.contains(volume.name) {
                            ProgressView().controlSize(.mini)
                        } else {
                            Button(tr("Проверить")) { model.checkActivity([volume.name]) }.controlSize(.small)
                        }
                    }
                    .width(160)
                    TableColumn(tr("Используется")) { volume in
                        if volume.usedBy.isEmpty {
                            Text("—").foregroundStyle(Theme.muted)
                        } else {
                            Label(volume.usedBy.joined(separator: ", "), systemImage: "cube.fill")
                                .foregroundStyle(Theme.warn)
                                .lineLimit(1)
                        }
                    }
                }
                .alternatingRowBackgrounds()
                footer
            }
        }
        .navigationTitle("Docker")
        .sheet(isPresented: $showPrune) { DockerPruneSheet() }
        .task { if model.status == .unknown { model.reload(app: app) } }
        .onChange(of: app.target?.id) { model.reload(app: app) }
        .confirmationDialog(tr("Архивировать выбранные тома?"), isPresented: $confirmArchive) {
            Button(app.target?.isEncryptedImage == true
                   ? tr("Упаковать в сейф и убрать из Docker")
                   : tr("Упаковать на «\(app.target?.name ?? "")» открыто и убрать из Docker")) {
                if let volume = app.target { model.archiveSelected(to: volume, app: app) }
            }
            Button(tr("Отмена"), role: .cancel) {}
        } message: {
            Text(tr("Выбрано \(model.selection.count), около \(Format.bytes(model.selectedBytes)). Каждый том упаковывается в архив, список всех его файлов сверяется с архивом, и только потом том удаляется из Docker. Тома, подключённые к контейнерам, не трогаются."))
        }
        .alert(tr("Вернуть том в Docker"),
               isPresented: Binding(get: { restoreArchive != nil }, set: { if !$0 { restoreArchive = nil } })) {
            TextField(tr("Имя тома"), text: $restoreName)
            Button(tr("Вернуть")) {
                if let archive = restoreArchive { model.restore(archive, name: restoreName, app: app) }
            }
            Button(tr("Отмена"), role: .cancel) {}
        } message: {
            Text(tr("Будет создан новый том и заполнен из архива со сверкой. Существующий том с таким именем не перезаписывается."))
        }
    }

    /// Архив лежит в сейфе или открыто на диске — и путь к нему, понятный человеку.
    private func location(of url: URL) -> (inSafe: Bool, path: String) {
        if let safe = app.safeVolume, url.path.hasPrefix(safe.mountPoint.path + "/") { return (true, url.lastPathComponent) }
        guard let root = app.destination?.mountPoint.path, url.path.hasPrefix(root + "/") else { return (false, url.lastPathComponent) }
        return (false, String(url.path.dropFirst(root.count + 1)))
    }

    private var header: some View {
        let model = app.docker
        return HStack(spacing: 12) {
            IconTile(systemImage: "shippingbox.fill", size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Docker").font(Theme.display(19))
                if model.sizing {
                    Text(tr("Docker считает размеры томов — это может занять минуту")).font(.caption).foregroundStyle(Theme.muted)
                } else if let raw = model.rawBytes {
                    Text(tr("Диск Docker (Docker.raw) занимает \(Format.bytes(raw))")).font(.caption).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.callout).lineLimit(1).truncationMode(.middle)
                if !model.pruning { Button(tr("Отменить")) { model.cancel() } }
            }
            Button { model.reload(app: app) } label: { Label(tr("Обновить"), systemImage: "arrow.clockwise") }
                .disabled(model.busy != nil)
            Button {
                if app.pro.allows(.dockerVolumes) { confirmArchive = true } else { app.pro.offer(.dockerVolumes) }
            } label: {
                HStack(spacing: 6) {
                    Label(tr("Архивировать на диск…"), systemImage: "archivebox")
                    if !app.pro.allows(.dockerVolumes) { ProTag() }
                }
            }
                .prominentButton()
                .disabled(model.selection.isEmpty || model.busy != nil || app.target == nil)
                .help(app.targetProblem ?? tr("Упаковать выбранные тома и убрать их из Docker"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Что занимает место внутри Docker — и сколько из этого Docker пересоздаст сам.
    private var usageBand: some View {
        let model = app.docker
        return HStack(spacing: 24) {
            if let usage = model.usage {
                figure(tr("Образы"), usage.images, note: tr("можно убрать"))
                figure(tr("Кеш сборки"), usage.buildCache, note: tr("можно убрать"))
                figure(tr("Контейнеры"), usage.containers, note: tr("можно убрать"))
                // Тома очистка не трогает: неподключённые можно только упаковать на диск.
                figure(tr("Тома"), usage.volumes, note: tr("не подключены"), tone: .neutral)
            } else if model.measuringUsage {
                ProgressView().controlSize(.small)
                Text(tr("Docker считает, что занимает место внутри него…")).font(.callout).foregroundStyle(Theme.muted)
            } else {
                Text(tr("Docker не сказал, сколько места занято внутри.")).font(.callout).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 12)
            if model.usage != nil, model.measuringUsage { ProgressView().controlSize(.small) }
            Button { showPrune = true } label: { Label(tr("Освободить место…"), systemImage: "sparkles") }
                .disabled(model.usage == nil || model.busy != nil)
                .help(tr("Удалить кеш сборки, неиспользуемые образы и остановленные контейнеры. Тома не трогаются."))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func figure(_ title: String, _ part: DockerUsage.Part?, note: String, tone: Tone = .good) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(Theme.muted)
            Text(part.map { Format.bytes($0.bytes) } ?? "—").font(.callout.weight(.semibold)).monospacedDigit()
            if let part, part.reclaimable > 0 {
                Text("\(note) \(Format.bytes(part.reclaimable))").font(.caption).foregroundStyle(tone.color).monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        let model = app.docker
        if !model.messages.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.messages, id: \.self) { message in
                    Notice(Self.notice(for: message))
                }
            }
            .padding(12)
        }
        if !model.archives.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Архивы томов")).font(.headline)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.archives, id: \.self) { archive in
                            let place = location(of: archive)
                            HStack(spacing: 10) {
                                IconTile(systemImage: place.inSafe ? "lock.fill" : "archivebox.fill",
                                         tone: place.inSafe ? .good : .neutral, size: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(place.path).lineLimit(1).truncationMode(.middle).help(archive.path)
                                    Text(place.inSafe ? tr("в сейфе") : tr("открыто на диске")).font(.caption).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Button(tr("Вернуть в Docker…")) {
                                    restoreName = DockerService.volumeName(fromArchive: archive) ?? ""
                                    restoreArchive = archive
                                }
                                .disabled(model.busy != nil)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    /// Итоги упаковки приходят строками с отметкой в начале: «✓» — удалось, «✗» — нет.
    /// Отметка становится цветом плашки, а из текста уходит.
    private static func notice(for message: String) -> Notice.Message {
        if message.hasPrefix("✓ ") { return Notice.Message(.success, String(message.dropFirst(2))) }
        if message.hasPrefix("✗ ") { return Notice.Message(.error, String(message.dropFirst(2))) }
        return Notice.Message(.info, message)
    }
}

extension DockerPruneTarget {
    var title: String {
        switch self {
        case .buildCache: return tr("Кеш сборки")
        case .danglingImages: return tr("Образы без имени")
        case .images: return tr("Все неиспользуемые образы")
        case .containers: return tr("Остановленные контейнеры")
        }
    }

    var detail: String {
        switch self {
        case .buildCache:
            return tr("Промежуточные слои от docker build. Следующая сборка пойдёт дольше, пока кеш не наберётся заново.")
        case .danglingImages:
            return tr("Остатки пересборок с именем <none>: запустить их не по чему, ни один контейнер их не использует.")
        case .images:
            return tr("Образы, которые не нужны ни одному контейнеру. Docker скачает их заново, когда понадобятся; собранные вами и никуда не отправленные придётся собрать снова. Отмечайте сами.")
        case .containers:
            return tr("Всё, что записано внутри контейнера, а не в томе, пропадёт вместе с ним. Образы удалённых контейнеров тоже освободятся.")
        }
    }
}

/// Очистка того, что Docker пересоздаст сам. Тома сюда не входят: в них данные.
struct DockerPruneSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// Сразу отмечено только то, что точно не нужно: кеш сборки и образы без имени. Все неиспользуемые
    /// образы — нет: собранный вами и никуда не отправленный образ не скачать. Остановленные
    /// контейнеры — тоже нет: в них могут быть данные без тома.
    @State private var targets: Set<DockerPruneTarget> = [.buildCache, .danglingImages]

    private static let order: [DockerPruneTarget] = [.buildCache, .danglingImages, .images, .containers]

    var body: some View {
        let model = app.docker
        let usage = model.usage ?? DockerUsage()
        SheetLayout(systemImage: "shippingbox.fill", title: tr("Освободить место в Docker"),
                    subtitle: model.rawBytes.map { tr("Диск Docker (Docker.raw) занимает на Mac \(Format.bytes($0))") },
                    width: 580) {
            Card(padding: 0, spacing: 0) {
                ForEach(Self.order, id: \.self) { target in
                    if target != Self.order.first { RowDivider(inset: 44) }
                    row(target, part: usage.part(target))
                }
            }
            if targets.contains(.containers) {
                Notice(.warning, tr("Отмечайте остановленные контейнеры, только если они точно не нужны: удалённый контейнер не вернуть."))
            }
            Notice(.info, tr("Тома не трогаются: в них данные баз и проектов. Ненужные тома можно упаковать на диск кнопкой «Архивировать на диск…»."))
        } actions: {
            Button(tr("Отмена")) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(targets.isEmpty ? tr("Освободить") : tr("Освободить около \(Format.bytes(usage.reclaimable(targets)))")) {
                model.prune(targets, app: app)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(targets.isEmpty || model.busy != nil)
        }
    }

    private func row(_ target: DockerPruneTarget, part: DockerUsage.Part?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Toggle(target.title, isOn: Binding(
                get: { targets.contains(target) },
                set: { if $0 { targets.insert(target) } else { targets.remove(target) } }))
                .labelsHidden()
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(target == .containers ? "\(target.title) (\(max(0, (part?.count ?? 0) - (part?.active ?? 0))))" : target.title)
                Text(target.detail).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(part.map { Format.bytes($0.reclaimable) } ?? "—").fontWeight(.medium).monospacedDigit()
        }
        .rowPadding()
    }
}
