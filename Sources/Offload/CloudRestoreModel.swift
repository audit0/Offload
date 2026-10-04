import AppKit
import OffloadCore

/// Раздел «Из iCloud»: найти бэкап restic в iCloud Drive, открыть его паролем,
/// выбрать снимок и вернуть из него файл или папку на Mac.
@MainActor
@Observable
final class CloudRestoreModel {
    typealias Repository = CloudRestore.Repository
    typealias Snapshot = CloudRestore.Snapshot
    typealias Entry = CloudRestore.Entry

    private(set) var resticInstalled = CloudRestore.isResticInstalled
    private(set) var repositories: [Repository] = []
    private(set) var searching = false
    var repository: Repository? {
        didSet {
            guard repository != oldValue else { return }
            lock()
            if !Demo.isOn { UserDefaults.standard.set(repository?.url.path, forKey: Self.repositoryKey) }
        }
    }

    /// Пароль живёт только в памяти и только пока хранилище открыто: сон и блокировка экрана его стирают.
    @ObservationIgnored private var password: CloudRestore.Password?
    /// Файл с паролем, который выбирали в прошлый раз, — только путь, не содержимое.
    private(set) var passwordFile: URL?
    private(set) var snapshots: [Snapshot] = []
    var snapshotID: String? {
        didSet {
            guard snapshotID != oldValue, let snapshot else { return }
            searchResults = nil
            open(snapshot.root)
        }
    }
    var snapshot: Snapshot? { snapshots.first { $0.id == snapshotID } }
    var isUnlocked: Bool { !snapshots.isEmpty }

    private(set) var directory = "/"
    private(set) var entries: [Entry] = []
    var query = ""
    private(set) var searchResults: [Entry]?

    /// Что сейчас загружается — одной фразой; пока не nil, остальные кнопки ждут.
    private(set) var loading: String?
    var error: String?

    private(set) var destination: URL
    private(set) var restoring: Entry?
    private(set) var progress: CloudRestore.Progress?
    /// iCloud ещё не отдал часть бэкапа: restic ждёт и повторяет чтение.
    private(set) var waitingForCloud = false
    private(set) var restoreMessage: Notice.Message?
    private(set) var restoredItem: URL?
    @ObservationIgnored private var token: CancelToken?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private static let repositoryKey = "icloud.repository"
    private static let passwordFileKey = "icloud.passwordFile"
    private static let destinationKey = "icloud.destination"

    init() {
        let defaults = UserDefaults.standard
        destination = defaults.string(forKey: Self.destinationKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        if Demo.isOn {
            repositories = Demo.cloudRepositories
            repository = repositories.first
            snapshots = Demo.cloudSnapshots
            snapshotID = snapshots.first?.id
            directory = Demo.cloudDirectory
            entries = Demo.cloudEntries
            return
        }
        passwordFile = defaults.string(forKey: Self.passwordFileKey).map { URL(fileURLWithPath: $0) }
        if let saved = defaults.string(forKey: Self.repositoryKey) { repository = Repository(url: URL(fileURLWithPath: saved, isDirectory: true)) }
        startGuards()
    }

    // MARK: - Хранилище и пароль

    /// Ищет хранилища в iCloud Drive. Запомненное в прошлый раз остаётся в списке, даже если лежит в другом месте.
    func discover() {
        guard !Demo.isOn, !searching else { return }
        resticInstalled = CloudRestore.isResticInstalled
        searching = true
        Task {
            var found = await Task.detached(priority: .userInitiated) { CloudRestore.discover() }.value
            if let repository, !found.contains(repository), CloudRestore.isRepository(repository.url) { found.insert(repository, at: 0) }
            repositories = found
            if repository.map({ !CloudRestore.isRepository($0.url) }) ?? true { repository = found.first }
            searching = false
        }
    }

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = CloudRestore.iCloudDrive
        panel.prompt = tr("Выбрать")
        panel.message = tr("Папка хранилища restic — в ней лежат config, keys и data")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard CloudRestore.isRepository(url) else {
            error = CloudRestore.RestoreError.notARepository(url.path).localizedDescription
            return
        }
        let chosen = Repository(url: url)
        if !repositories.contains(chosen) { repositories.insert(chosen, at: 0) }
        repository = chosen
    }

    func unlock(password text: String) {
        guard !text.isEmpty else { return }
        unlock(with: .typed(text))
    }

    func unlockWithFile(_ file: URL? = nil) {
        var file = file
        if file == nil {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.showsHiddenFiles = true
            panel.prompt = tr("Выбрать")
            panel.message = tr("Файл, в котором записан пароль хранилища")
            guard panel.runModal() == .OK else { return }
            file = panel.url
        }
        guard let file else { return }
        unlock(with: .file(file))
    }

    private func unlock(with candidate: CloudRestore.Password) {
        guard let repository, loading == nil else { return }
        if Demo.isOn { return }
        loading = tr("Открываю хранилище…")
        error = nil
        Task {
            do {
                let found = try await Task.detached(priority: .userInitiated) {
                    try CloudRestore.snapshots(repository, password: candidate)
                }.value
                guard repository == self.repository else { loading = nil; return }
                password = candidate
                if case .file(let url) = candidate {
                    passwordFile = url
                    UserDefaults.standard.set(url.path, forKey: Self.passwordFileKey)
                }
                snapshots = found
                loading = nil
                if found.isEmpty { error = tr("В хранилище пока нет ни одного снимка.") }
                snapshotID = found.first?.id
            } catch {
                loading = nil
                self.error = error.localizedDescription
            }
        }
    }

    /// Забыть пароль и всё прочитанное из хранилища.
    func lock() {
        token?.cancel()
        // Начатый просмотр или поиск, узнав, что снимка больше нет, выходит молча — индикатор снимается здесь,
        // иначе «Открыть» так и крутился бы до перезапуска.
        loading = nil
        password = nil
        snapshots = []
        snapshotID = nil
        entries = []
        searchResults = nil
        directory = "/"
        query = ""
    }

    // MARK: - Просмотр

    func open(_ path: String) {
        guard let repository, let password, let snapshotID else {
            if Demo.isOn { directory = path }
            return
        }
        loading = tr("Читаю «\((path as NSString).lastPathComponent)»…")
        error = nil
        Task {
            do {
                let listed = try await Task.detached(priority: .userInitiated) {
                    try CloudRestore.list(repository, password: password, snapshot: snapshotID, directory: path)
                }.value
                guard snapshotID == self.snapshotID else { return }
                directory = path
                entries = listed
                searchResults = nil
            } catch {
                self.error = error.localizedDescription
            }
            loading = nil
        }
    }

    func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { searchResults = nil; return }
        guard let repository, let password, let snapshotID else { return }
        loading = tr("Ищу «\(text)»…")
        error = nil
        Task {
            do {
                let found = try await Task.detached(priority: .userInitiated) {
                    try CloudRestore.search(repository, password: password, snapshot: snapshotID, query: text)
                }.value
                guard snapshotID == self.snapshotID else { return }
                searchResults = found
            } catch {
                self.error = error.localizedDescription
            }
            loading = nil
        }
    }

    func clearSearch() {
        query = ""
        searchResults = nil
    }

    // MARK: - Восстановление

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        panel.prompt = tr("Выбрать")
        panel.message = tr("Куда класть восстановленное — внутри появится новая папка")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
        if !Demo.isOn { UserDefaults.standard.set(url.path, forKey: Self.destinationKey) }
    }

    func restore(_ entry: Entry, app: AppModel) {
        guard restoring == nil else { return }
        if Demo.isOn {
            restoreMessage = Notice.Message(.success, tr("Демонстрация: «\(entry.name)» восстановился бы в новую папку в «\(destination.lastPathComponent)»."))
            return
        }
        guard let repository, let password, let snapshot else { return }
        let destination = destination
        let token = CancelToken()
        self.token = token
        let operationID = app.beginOperation { token.cancel() }
        let throttle = Throttle(interval: 0.2)
        restoring = entry
        progress = nil
        waitingForCloud = false
        restoreMessage = nil
        restoredItem = nil
        error = nil
        Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try CloudRestore.restore(entry, from: repository, password: password, snapshot: snapshot, into: destination,
                                             isCancelled: { token.isCancelled },
                                             waitingForCloud: { _ in
                        Task { @MainActor in if self.restoring == entry { self.waitingForCloud = true } }
                    }) { update in
                        guard throttle.ready() || update.fraction >= 1 else { return }
                        Task { @MainActor in
                            guard self.restoring == entry else { return }
                            // Данные пошли — значит, iCloud докачал.
                            if update.bytesDone > (self.progress?.bytesDone ?? 0) { self.waitingForCloud = false }
                            self.progress = update
                        }
                    }
                }.value
                restoredItem = report.item
                let what = entry.isDirectory
                    ? "\(report.files) \(pluralRu(report.files, tr("файл"), tr("файла"), tr("файлов"))), \(Format.bytes(report.bytes))"
                    : Format.bytes(report.bytes)
                restoreMessage = report.verified && report.problems.isEmpty
                    ? Notice.Message(.success, tr("«\(entry.name)» восстановлено и сверено с бэкапом: \(what)."))
                    : Notice.Message(.warning, tr("«\(entry.name)» восстановлено не целиком: \(what). Файлы, которые не прочитались из бэкапа, убраны — они были бы испорчены; остальное с бэкапом не сверено: после ошибок restic не сверяет. Не удалось:"),
                                     details: Array(report.problems.prefix(10)))
            } catch is CancellationError {
                restoreMessage = Notice.Message(.info, tr("Восстановление остановлено, недокачанное убрано."))
            } catch {
                restoreMessage = Notice.Message(.error, error.localizedDescription)
            }
            restoring = nil
            progress = nil
            waitingForCloud = false
            self.token = nil
            app.endOperation(operationID)
        }
    }

    func cancelRestore() { token?.cancel() }

    // MARK: - Защита пароля

    /// Сон и блокировка экрана забывают пароль — как у сейфа.
    private func startGuards() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockIfIdle() }
            }))
        }
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            observers.append((distributed, distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockIfIdle() }
            }))
        }
    }

    /// Идущее восстановление не прерывается: пароль у него уже есть, а бросать его на середине незачем.
    private func lockIfIdle() {
        guard restoring == nil, password != nil else { return }
        lock()
    }
}
