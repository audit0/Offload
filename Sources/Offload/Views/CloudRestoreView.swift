import OffloadCore
import SwiftUI

/// Вернуть файл или папку из бэкапа restic в iCloud Drive.
struct CloudRestoreView: View {
    @Environment(AppModel.self) private var app
    @State private var password = ""

    /// Длинные папки показываются не целиком: остальное находится поиском.
    private let visibleLimit = 300

    var body: some View {
        let model = app.cloud
        PageScroll {
            CardSection(title: tr("Хранилище"), number: 1,
                        footer: tr("Бэкапы restic из iCloud Drive — например, копия внешнего диска. OffLoadAI только читает хранилище и ничего в нём не меняет, а пароль держит в памяти, пока хранилище открыто: сон и блокировка экрана его стирают.")) {
                repositorySection
            }
            if model.isUnlocked {
                CardSection(title: tr("Снимок"), number: 2) {
                    snapshotSection
                }
                CardSection(title: tr("Куда восстановить"), number: 3) {
                    destinationSection
                }
                CardSection(title: tr("Файлы"), number: 4) {
                    filesSection
                }
            }
        }
        .navigationTitle(tr("Из iCloud"))
        .task { model.discover() }
    }

    // MARK: - Хранилище

    @ViewBuilder
    private var repositorySection: some View {
        let model = app.cloud
        if !model.resticInstalled {
            VStack(alignment: .leading, spacing: 10) {
                Notice(.warning, CloudRestore.RestoreError.resticMissing.localizedDescription)
                Button(tr("Проверить снова")) { model.discover() }
            }
            .padding(Theme.cardPadding)
            RowDivider()
        }
        if model.searching && model.repositories.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(tr("Ищу бэкапы в iCloud Drive…")).foregroundStyle(Theme.muted)
            }
            .rowPadding()
            RowDivider()
        } else if model.repositories.isEmpty {
            Text(tr("В iCloud Drive бэкапов restic не нашлось. Если хранилище лежит в другом месте, выберите его папку."))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .rowPadding()
            RowDivider()
        }
        ForEach(model.repositories) { repository in
            repositoryRow(repository)
            RowDivider()
        }
        Button { model.chooseRepository() } label: { Label(tr("Выбрать папку хранилища…"), systemImage: "folder") }
            .buttonStyle(.borderless)
            .disabled(model.restoring != nil)
            .rowPadding()
        if model.repository != nil {
            RowDivider()
            passwordRow
        }
    }

    private func repositoryRow(_ repository: CloudRestore.Repository) -> some View {
        let model = app.cloud
        let selected = model.repository == repository
        return Button { model.repository = repository } label: {
            HStack(spacing: 10) {
                IconTile(systemImage: "icloud", tone: selected ? .brand : .neutral, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(repository.name).fontWeight(selected ? .semibold : .regular).foregroundStyle(Theme.ink)
                    Text(location(of: repository)).font(.caption).foregroundStyle(Theme.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").foregroundStyle(Theme.ink) }
            }
            .contentShape(Rectangle())
            .rowPadding()
        }
        .buttonStyle(.plain)
        .disabled(model.restoring != nil || model.loading != nil)
    }

    private func location(of repository: CloudRestore.Repository) -> String {
        let drive = CloudRestore.iCloudDrive.path
        let path = repository.url.path
        return path.hasPrefix(drive + "/") ? "iCloud Drive/" + path.dropFirst(drive.count + 1) : relativeToHome(path, home: app.rules.home)
    }

    @ViewBuilder
    private var passwordRow: some View {
        let model = app.cloud
        VStack(alignment: .leading, spacing: 8) {
            if model.isUnlocked {
                HStack {
                    Label(tr("Открыто · \(model.snapshots.count) \(pluralRu(model.snapshots.count, tr("снимок"), tr("снимка"), tr("снимков")))"),
                          systemImage: "lock.open.fill")
                    Spacer()
                    Button(tr("Закрыть")) { model.lock() }.disabled(model.restoring != nil)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(Theme.muted)
                    SecureField(tr("Пароль хранилища"), text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(unlock)
                    if model.loading != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(tr("Открыть"), action: unlock)
                            .prominentButton()
                            .disabled(password.isEmpty)
                    }
                }
                HStack(spacing: 12) {
                    if let file = model.passwordFile {
                        Button(tr("Пароль из «\(file.lastPathComponent)»")) { model.unlockWithFile(file) }
                            .buttonStyle(InkLinkStyle())
                            .help(relativeToHome(file.path, home: app.rules.home))
                    }
                    Button(tr("Пароль из файла…")) { model.unlockWithFile() }
                        .buttonStyle(InkLinkStyle())
                }
                .font(.callout)
                .disabled(model.loading != nil)
            }
            if let error = model.error {
                Label(error, systemImage: "xmark.circle.fill")
                    .font(.caption).foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(Theme.cardPadding)
        .onChange(of: password) { if !password.isEmpty { model.error = nil } }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        app.cloud.unlock(password: password)
        password = ""
    }

    // MARK: - Снимок

    @ViewBuilder
    private var snapshotSection: some View {
        let model = app.cloud
        @Bindable var bindable = model
        VStack(alignment: .leading, spacing: 10) {
            Picker(tr("Снимок"), selection: $bindable.snapshotID) {
                ForEach(model.snapshots) { snapshot in
                    Text(title(of: snapshot)).tag(Optional(snapshot.id))
                }
            }
            .pickerStyle(.menu)
            .disabled(model.restoring != nil || model.loading != nil)
            if let snapshot = model.snapshot {
                InfoRow(tr("Что в снимке"), value: snapshot.paths.joined(separator: ", "))
                    .font(.callout)
            }
        }
        .padding(Theme.cardPadding)
    }

    private func title(of snapshot: CloudRestore.Snapshot) -> String {
        var parts = [snapshot.time.formatted(date: .abbreviated, time: .shortened)]
        if let bytes = snapshot.totalBytes { parts.append(Format.bytes(bytes)) }
        parts.append(snapshot.shortID)
        return parts.joined(separator: " · ")
    }

    // MARK: - Куда

    @ViewBuilder
    private var destinationSection: some View {
        let model = app.cloud
        VStack(alignment: .leading, spacing: 12) {
            InfoRow(title: tr("Папка")) {
                HStack {
                    Text(relativeToHome(model.destination.path, home: app.rules.home))
                        .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                    Button(tr("Выбрать…")) { model.chooseDestination() }.disabled(model.restoring != nil)
                }
            }
            .font(.callout)
            Text(tr("Внутри появится новая папка «Из бэкапа …»: ничего существующего не перезаписывается. Восстановленное сверяется с бэкапом."))
                .font(.caption).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let entry = model.restoring {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(tr("Восстанавливаю «\(entry.name)»")).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let progress = model.progress, progress.bytesTotal > 0 {
                            Text(tr("\(Format.bytes(progress.bytesDone)) из \(Format.bytes(progress.bytesTotal))"))
                                .monospacedDigit().foregroundStyle(Theme.muted)
                        }
                        Button(tr("Остановить")) { model.cancelRestore() }
                    }
                    if let progress = model.progress {
                        ProgressView(value: progress.fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                        Text(tr("Считаю размер…")).font(.caption).foregroundStyle(Theme.muted)
                    }
                    if model.waitingForCloud {
                        Notice(.warning, tr("Жду iCloud: часть бэкапа хранится только в облаке, и iCloud её ещё не скачал. OffLoadAI попросил скачать и ждёт. Если долго ничего не меняется, проверьте в Finder → iCloud Drive, что синхронизация идёт, — или остановите и попробуйте позже."))
                    }
                }
            }
            if let message = model.restoreMessage {
                Notice(message)
                if let item = model.restoredItem {
                    Button { revealInFinder(item) } label: { Label(tr("Показать в Finder"), systemImage: "folder") }
                }
            }
        }
        .padding(Theme.cardPadding)
    }

    // MARK: - Файлы

    @ViewBuilder
    private var filesSection: some View {
        let model = app.cloud
        @Bindable var bindable = model
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField(tr("Найти по имени во всём снимке"), text: $bindable.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.search() }
            Button(tr("Найти")) { model.search() }
                .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty || model.loading != nil)
            if model.searchResults != nil {
                Button(tr("Сбросить")) { model.clearSearch() }
            }
        }
        .rowPadding()
        RowDivider()
        if let loading = model.loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(loading).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            .rowPadding()
            RowDivider()
        }
        if let results = model.searchResults {
            Text(results.isEmpty ? tr("Ничего не нашлось.") : tr("Найдено: \(results.count)") + (results.count >= 500 ? tr(" — показаны первые 500, уточните запрос") : ""))
                .font(.callout).foregroundStyle(Theme.muted)
                .rowPadding()
            ForEach(results) { entry in
                RowDivider()
                entryRow(entry, showsPath: true)
            }
        } else {
            breadcrumbs
            if model.entries.isEmpty && model.loading == nil {
                RowDivider()
                Text(tr("Папка пуста.")).foregroundStyle(Theme.muted).rowPadding()
            }
            ForEach(model.entries.prefix(visibleLimit)) { entry in
                RowDivider()
                entryRow(entry, showsPath: false)
            }
            if model.entries.count > visibleLimit {
                RowDivider()
                Text(tr("Ещё \(model.entries.count - visibleLimit) не показаны — найдите нужное по имени."))
                    .font(.callout).foregroundStyle(Theme.muted).rowPadding()
            }
        }
    }

    private var breadcrumbs: some View {
        let model = app.cloud
        let path = CloudRestore.ancestors(of: model.directory)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(path.enumerated()), id: \.element) { index, item in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.faint) }
                    let name = item == "/" ? tr("Корень") : (item as NSString).lastPathComponent
                    if item == model.directory {
                        Text(name).fontWeight(.semibold)
                    } else {
                        Button(name) { model.open(item) }
                            .buttonStyle(InkLinkStyle())
                            .disabled(model.loading != nil)
                    }
                }
            }
            .font(.callout)
        }
        .rowPadding()
    }

    private func entryRow(_ entry: CloudRestore.Entry, showsPath: Bool) -> some View {
        let model = app.cloud
        return HStack(spacing: 10) {
            Button {
                if entry.isDirectory { model.open(entry.path) }
            } label: {
                HStack(spacing: 10) {
                    IconTile(systemImage: entry.isDirectory ? "folder.fill" : "doc", tone: entry.isDirectory ? .brand : .neutral, size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                        Text(detail(of: entry, showsPath: showsPath))
                            .font(.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if entry.isDirectory { Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.faint) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!entry.isDirectory || model.loading != nil)
            Button(tr("Восстановить")) { model.restore(entry, app: app) }
                .controlSize(.small)
                .disabled(model.restoring != nil)
        }
        .rowPadding()
    }

    private func detail(of entry: CloudRestore.Entry, showsPath: Bool) -> String {
        var parts: [String] = []
        if showsPath { parts.append(CloudRestore.parentDirectory(entry.path)) }
        if let size = entry.size, !entry.isDirectory { parts.append(Format.bytes(size)) }
        if let modified = entry.modified { parts.append(modified.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }
}
