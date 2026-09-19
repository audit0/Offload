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
                    Button("Обновить") { model.reload(destination: app.destination) }
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
                            Text("—")
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
                        Text(volume.usedBy.isEmpty ? "—" : volume.usedBy.joined(separator: ", "))
                            .foregroundStyle(volume.usedBy.isEmpty ? Color.secondary : Color.orange)
                            .lineLimit(1)
                    }
                }
                footer
            }
        }
        .navigationTitle("Docker")
        .task { if model.status == .unknown { model.reload(destination: app.destination) } }
        .onChange(of: app.destinationID) { model.reload(destination: app.destination) }
        .confirmationDialog("Архивировать выбранные тома?", isPresented: $confirmArchive) {
            Button("Упаковать на «\(app.destination?.name ?? "")» и убрать из Docker") {
                if let volume = app.destination { model.archiveSelected(to: volume, app: app) }
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

    private func relativeToVolume(_ url: URL) -> String {
        guard let root = app.destination?.mountPoint.path, url.path.hasPrefix(root + "/") else { return url.lastPathComponent }
        return String(url.path.dropFirst(root.count + 1))
    }

    private var header: some View {
        let model = app.docker
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Тома Docker").font(.headline)
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
            Button { model.reload(destination: app.destination) } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                .disabled(model.busy != nil)
            Button { confirmArchive = true } label: { Label("Архивировать на диск…", systemImage: "archivebox") }
                .disabled(model.selection.isEmpty || model.busy != nil || app.destination == nil)
                .help(app.destination == nil
                      ? "Нужен подключённый внешний диск: выберите его внизу боковой панели"
                      : "Упаковать выбранные тома на внешний диск и убрать их из Docker")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var footer: some View {
        let model = app.docker
        if !model.messages.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.messages, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
            }
            .padding(12)
        }
        if !model.archives.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Архивы на диске «\(app.destination?.name ?? "")»").font(.headline)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.archives, id: \.self) { archive in
                            HStack {
                                Image(systemName: "archivebox.fill").foregroundStyle(.secondary)
                                Text(relativeToVolume(archive)).lineLimit(1).truncationMode(.middle).help(archive.path)
                                Spacer()
                                Button("Вернуть в Docker…") {
                                    restoreName = DockerService.volumeName(fromArchive: archive) ?? ""
                                    restoreArchive = archive
                                }
                                .disabled(model.busy != nil)
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            .padding(12)
        }
    }
}
