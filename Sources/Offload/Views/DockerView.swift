import OffloadCore
import SwiftUI

struct DockerView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmArchive = false
    @State private var restoreArchive: URL?
    @State private var restoreName = ""

    var body: some View {
        let model = app.docker
        @Bindable var bindable = model
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch model.status {
            case .unknown, .checking:
                ProgressView("Спрашиваю Docker…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notInstalled:
                ContentUnavailableView("Docker не установлен", systemImage: "shippingbox",
                                       description: Text("Этот раздел нужен, только если вы пользуетесь Docker."))
            case .notRunning:
                ContentUnavailableView {
                    Label("Docker не запущен", systemImage: "shippingbox")
                } description: {
                    Text("Откройте Docker Desktop и обновите список.")
                } actions: {
                    Button("Обновить") { model.reload(app: app) }
                }
            case .ready:
                Table(model.volumes, selection: $bindable.selection) {
                    TableColumn("Том") { volume in
                        Text(volume.name).lineLimit(1).truncationMode(.middle)
                    }
                    TableColumn("Размер") { volume in
                        if let bytes = volume.sizeBytes {
                            Text(Format.bytes(bytes)).monospacedDigit()
                        } else if model.sizing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                    .width(90)
                    TableColumn("Создан") { volume in
                        Text(volume.createdAt.map { Format.relative($0) } ?? "—")
                    }
                    .width(140)
                    TableColumn("Последнее изменение") { volume in
                        if let date = model.activity[volume.name] {
                            Text(Format.relative(date))
                        } else if model.checking.contains(volume.name) {
                            ProgressView().controlSize(.mini)
                        } else {
                            Button("Проверить") { model.checkActivity([volume.name]) }.controlSize(.small)
                        }
                    }
                    .width(160)
                    TableColumn("Используется") { volume in
                        if volume.usedBy.isEmpty {
                            Text("—").foregroundStyle(.secondary)
                        } else {
                            Label(volume.usedBy.joined(separator: ", "), systemImage: "cube.fill")
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
                }
                .alternatingRowBackgrounds()
                footer
            }
        }
        .navigationTitle("Docker")
        .task { if model.status == .unknown { model.reload(app: app) } }
        .onChange(of: app.target?.id) { model.reload(app: app) }
        .confirmationDialog("Архивировать выбранные тома?", isPresented: $confirmArchive) {
            Button(app.target?.isEncryptedImage == true
                   ? "Упаковать в сейф и убрать из Docker"
                   : "Упаковать на «\(app.target?.name ?? "")» открыто и убрать из Docker") {
                if let volume = app.target { model.archiveSelected(to: volume, app: app) }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Выбрано \(model.selection.count), около \(Format.bytes(model.selectedBytes)). Каждый том упаковывается в архив, список всех его файлов сверяется с архивом, и только потом том удаляется из Docker. Тома, подключённые к контейнерам, не трогаются.")
        }
        .alert("Вернуть том в Docker",
               isPresented: Binding(get: { restoreArchive != nil }, set: { if !$0 { restoreArchive = nil } })) {
            TextField("Имя тома", text: $restoreName)
            Button("Вернуть") {
                if let archive = restoreArchive { model.restore(archive, name: restoreName, app: app) }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Будет создан новый том и заполнен из архива со сверкой. Существующий том с таким именем не перезаписывается.")
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
                Text("Тома Docker").font(.title3.weight(.semibold))
                if model.sizing {
                    Text("Docker считает размеры томов — это может занять минуту").font(.caption).foregroundStyle(.secondary)
                } else if let raw = model.rawBytes {
                    Text("Диск Docker (Docker.raw) занимает \(Format.bytes(raw))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.callout).lineLimit(1).truncationMode(.middle)
                Button("Отменить") { model.cancel() }
            }
            Button { model.reload(app: app) } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                .disabled(model.busy != nil)
            Button { confirmArchive = true } label: { Label("Архивировать на диск…", systemImage: "archivebox") }
                .buttonStyle(.borderedProminent)
                .disabled(model.selection.isEmpty || model.busy != nil || app.target == nil)
                .help(app.targetProblem ?? "Упаковать выбранные тома и убрать их из Docker")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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
                Text("Архивы томов").font(.headline)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.archives, id: \.self) { archive in
                            let place = location(of: archive)
                            HStack(spacing: 10) {
                                IconTile(systemImage: place.inSafe ? "lock.fill" : "archivebox.fill",
                                         tone: place.inSafe ? .good : .neutral, size: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(place.path).lineLimit(1).truncationMode(.middle).help(archive.path)
                                    Text(place.inSafe ? "в сейфе" : "открыто на диске").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Вернуть в Docker…") {
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
