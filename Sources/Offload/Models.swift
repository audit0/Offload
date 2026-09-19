import AppKit
import Observation
import OffloadCore

// MARK: - Обзор

@MainActor
@Observable
final class OverviewModel {
    private(set) var disk: VolumeInfo?
    private(set) var memory: MemorySnapshot?
    private(set) var advice: [String] = []

    func poll() async {
        while !Task.isCancelled {
            let snapshot = await Task.detached(priority: .utility) {
                (Volumes.info(for: FileManager.default.homeDirectoryForCurrentUser), MemoryStats.snapshot())
            }.value
            disk = snapshot.0
            memory = snapshot.1
            advice = Self.diskAdvice(snapshot.0) + MemoryStats.advice(for: snapshot.1)
            try? await Task.sleep(for: .seconds(5))
        }
    }

    static func diskAdvice(_ disk: VolumeInfo?) -> [String] {
        guard let disk, disk.totalBytes > 0,
              Double(disk.availableBytes) / Double(disk.totalBytes) < 0.15 else { return [] }
        return ["На диске Mac свободно всего \(Format.bytes(disk.availableBytes)). Когда места мало, macOS тормозит: ей негде держать swap. Откройте «Что занимает место»."]
    }
}

// MARK: - Что занимает место

@MainActor
@Observable
final class SpaceModel {
    private(set) var location: URL?
    private(set) var items: [SpaceItem] = []
    private(set) var isScanning = false
    @ObservationIgnored private var token = CancelToken()
    @ObservationIgnored private var cache: [String: [SpaceItem]] = [:]

    static let smallItem: Int64 = 1 << 20

    /// Посчитанные — по убыванию размера, ещё считающиеся — ниже, по имени.
    var visibleItems: [SpaceItem] {
        let measured = items.filter { $0.isMeasured && ($0.bytes >= Self.smallItem || $0.accessDenied) }
            .sorted { ($0.bytes, $1.url.lastPathComponent) > ($1.bytes, $0.url.lastPathComponent) }
        let pending = items.filter { !$0.isMeasured }
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        return measured + pending
    }
    var hiddenSmallCount: Int { items.filter { $0.isMeasured && $0.bytes < Self.smallItem && !$0.accessDenied }.count }
    var largest: Int64 { max(items.map(\.bytes).max() ?? 0, 1) }

    func title(home: URL) -> String {
        guard let location else { return "Домашняя папка и общие файлы" }
        return relativeToHome(location.path, home: home)
    }

    func open(_ url: URL?, rules: SafetyRules) {
        token.cancel()
        location = url
        if let cached = cache[Self.key(url)] {
            items = cached
            isScanning = false
            return
        }
        scan(rules: rules)
    }

    func rescan(rules: SafetyRules) {
        cache[Self.key(location)] = nil
        open(location, rules: rules)
    }

    /// После переноса размеры во всех родительских папках устарели.
    func invalidateAll() { cache.removeAll() }

    func goUp(rules: SafetyRules) {
        guard let location else { return }
        let parent = location.deletingLastPathComponent().standardizedFileURL
        let rootLevel = parent.path == rules.home.path || location.path == "/Users/Shared"
        open(rootLevel ? nil : parent, rules: rules)
    }

    private func scan(rules: SafetyRules) {
        let token = CancelToken()
        self.token = token
        items = []
        isScanning = true
        let location = self.location
        let key = Self.key(location)
        let collector = Collector<SpaceItem>()
        let throttle = Throttle(interval: 0.3)
        // Модель живёт всё время работы приложения, а классы с @MainActor можно передавать
        // между задачами, поэтому self захватывается напрямую, без weak.
        Task.detached(priority: .userInitiated) {
            let urls = location.map { SpaceScanner.children(of: $0) } ?? Self.roots(home: rules.home)
            let placeholders = urls.map { SpaceScanner.placeholder($0, rules: rules) }
            await MainActor.run {
                guard !token.isCancelled else { return }
                self.items = placeholders
            }
            await SpaceScanner.scan(urls, rules: rules, isCancelled: { token.isCancelled }) { item in
                collector.append(item)
                guard throttle.ready() else { return }
                let measured = collector.all
                Task { @MainActor in
                    guard !token.isCancelled else { return }
                    self.apply(measured)
                }
            }
            let all = collector.all
            await MainActor.run {
                guard !token.isCancelled else { return }
                self.apply(all)
                self.isScanning = false
                self.cache[key] = self.items
            }
        }
    }

    /// Подставляет посчитанные строки на место заглушек.
    private func apply(_ measured: [SpaceItem]) {
        let byID = Dictionary(measured.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        items = items.map { byID[$0.id] ?? $0 }
    }

    nonisolated static func roots(home: URL) -> [URL] {
        var urls = SpaceScanner.children(of: home)
        let shared = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
        if FileManager.default.fileExists(atPath: shared.path) { urls.append(shared) }
        return urls
    }

    nonisolated static func key(_ url: URL?) -> String { url?.path ?? "" }
}

// MARK: - Перенос

@MainActor
@Observable
final class MoveModel {
    enum Stage {
        case idle
        case inspecting
        case ready(MovePlan)
        case running(MoveProgress)
        case done(MoveRecord)
        case failed(String)
    }

    var stage: Stage = .idle
    var deleteOriginal = true
    var acceptCautions = false
    /// Перенос действительно состоялся — только тогда раздел со списком стоит пересчитывать заново.
    private(set) var didMove = false
    @ObservationIgnored private var token = CancelToken()
    @ObservationIgnored private let operationID = UUID()

    var isBusy: Bool {
        switch stage {
        case .inspecting, .running: return true
        default: return false
        }
    }

    func canRun(_ plan: MovePlan) -> Bool {
        guard plan.canProceed else { return false }
        if case .caution = plan.verdict { return acceptCautions }
        return true
    }

    func prepare(source: URL, volume: VolumeInfo, rules: SafetyRules) {
        token.cancel()
        let token = CancelToken()
        self.token = token
        stage = .inspecting
        acceptCautions = false
        Task {
            let plan = await Task.detached(priority: .userInitiated) {
                SafeMover(rules: rules).plan(source: source, volume: volume, isCancelled: { token.isCancelled })
            }.value
            // Без этой ветки отмена оставляла окно навсегда в состоянии «Проверяю…»:
            // спиннер крутится, кнопка «Отменить» уже ничего не делает, закрыть нечем.
            guard !token.isCancelled else {
                stage = .failed("Проверка отменена. Ничего не скопировано и не удалено.")
                return
            }
            stage = .ready(plan)
        }
    }

    func run(_ plan: MovePlan, app: AppModel) {
        let rules = app.rules
        let token = CancelToken()
        self.token = token
        let deleteOriginal = deleteOriginal
        let acceptCautions = acceptCautions
        let throttle = Throttle()
        app.beginOperation(operationID) { token.cancel() }
        stage = .running(MoveProgress(phase: .inspecting, bytesDone: 0, bytesTotal: plan.content.logicalBytes,
                                      item: plan.source.lastPathComponent))
        Task {
            do {
                let record = try await Task.detached(priority: .userInitiated) {
                    try SafeMover(rules: rules).execute(plan, deleteOriginal: deleteOriginal, acceptCautions: acceptCautions,
                                                        isCancelled: { token.isCancelled }) { progress in
                        guard throttle.ready() else { return }
                        Task { @MainActor in
                            if case .running = self.stage { self.stage = .running(progress) }
                        }
                    }
                }.value
                stage = .done(record)
                didMove = true
            } catch is CancellationError {
                stage = .failed("Перенос отменён. Оригинал не тронут, незаконченная копия удалена.")
            } catch {
                stage = .failed(error.localizedDescription)
            }
            app.endOperation(operationID)
        }
    }

    func cancel() { token.cancel() }
}

// MARK: - Перенесённое

@MainActor
@Observable
final class HistoryModel {
    private(set) var records: [MoveRecord] = []
    private(set) var busyID: UUID?
    private(set) var progress: MoveProgress?
    var message: Notice.Message?
    @ObservationIgnored private var token = CancelToken()
    @ObservationIgnored private let operationID = UUID()
    /// Есть ли архив на диске — считается при перечитывании списка, а не в каждой строке:
    /// иначе прокрутка и каждое обновление прогресса опрашивали бы внешний диск заново.
    @ObservationIgnored private var availability: [UUID: Bool] = [:]

    func reload(volumes: [VolumeInfo]) {
        var byID: [UUID: MoveRecord] = [:]
        for record in Journal.localRecords() { byID[record.id] = record }
        for volume in volumes {
            for record in Journal.records(on: volume) { byID[record.id] = record }
        }
        records = byID.values.sorted { $0.date > $1.date }
        let fm = FileManager.default
        availability = Dictionary(uniqueKeysWithValues: records.map { ($0.id, fm.fileExists(atPath: $0.archivedPath)) })
    }

    func archiveExists(_ record: MoveRecord) -> Bool { availability[record.id] ?? false }
    func isArchiveAvailable(_ record: MoveRecord) -> Bool { !record.restored && archiveExists(record) }

    func restore(_ record: MoveRecord, deleteArchive: Bool, app: AppModel) {
        let token = CancelToken()
        self.token = token
        let rules = app.rules
        let throttle = Throttle()
        busyID = record.id
        progress = nil
        message = nil
        app.beginOperation(operationID) { token.cancel() }
        Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try SafeMover(rules: rules).restore(record, deleteArchive: deleteArchive, isCancelled: { token.isCancelled }) { progress in
                        guard throttle.ready() else { return }
                        Task { @MainActor in
                            if self.busyID == record.id { self.progress = progress }
                        }
                    }
                }.value
                let name = URL(fileURLWithPath: record.originalPath).lastPathComponent
                let text = "«\(name)» возвращён на место, каждый файл перечитан и сверен по SHA-256."
                message = outcome.notes.isEmpty
                    ? Notice.Message(.success, text)
                    : Notice.Message(.warning, ([text] + outcome.notes).joined(separator: " "))
            } catch is CancellationError {
                message = Notice.Message(.info, "Возврат отменён, незаконченная копия удалена. Архив на диске не тронут.")
            } catch {
                message = Notice.Message(.error, "Вернуть не удалось: \(error.localizedDescription) Архив на диске не тронут.")
            }
            busyID = nil
            progress = nil
            app.endOperation(operationID)
            app.refreshVolumes()
            app.space.invalidateAll()
            reload(volumes: app.volumes)
        }
    }

    func cancel() { token.cancel() }
}

// MARK: - Бэкап

@MainActor
@Observable
final class BackupModel {
    var sources: [URL] { didSet { persist() } }
    var excludedText: String { didSet { persist() } }
    private(set) var isRunning = false
    private(set) var currentItem = ""
    private(set) var copiedBytes: Int64 = 0
    private(set) var report: BackupReport?
    var error: String?
    @ObservationIgnored private var token = CancelToken()

    private(set) var vault: VaultState?
    private(set) var vaultBusy = false
    private(set) var vaultReport: SecretsReport?
    var vaultMessage: Notice.Message?
    @ObservationIgnored private var vaultGeneration = UUID()
    @ObservationIgnored private let operationID = UUID()

    /// Снимок состояния контейнера на выбранном диске. Раньше оно определялось один раз
    /// и потом врало: после извлечения диска раздел продолжал показывать «Контейнер открыт»,
    /// а при переключении дисков — контейнер с прошлого.
    struct VaultState: Sendable, Equatable {
        var volumeID: String
        var imageURL: URL
        var exists: Bool
        var isEncrypted: Bool
        var mount: URL?
    }

    /// Своя папка бэкапа на диске (например, уже существующая), иначе «Offload Backup» в корне.
    var destinationPath: String? { didSet { persist() } }

    private static let sourcesKey = "backup.sources"
    private static let excludedKey = "backup.excluded"
    private static let destinationKey = "backup.destination"

    init() {
        let defaults = UserDefaults.standard
        sources = (defaults.stringArray(forKey: Self.sourcesKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        excludedText = defaults.string(forKey: Self.excludedKey)
            ?? BackupEngine.defaultExcludedNames.sorted().joined(separator: ", ")
        destinationPath = defaults.string(forKey: Self.destinationKey)
    }

    var excludedNames: Set<String> {
        Set(excludedText.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("/") })
    }

    func destination(on volume: VolumeInfo) -> URL {
        if let destinationPath, destinationPath.hasPrefix(volume.mountPoint.path + "/") {
            return URL(fileURLWithPath: destinationPath, isDirectory: true)
        }
        return volume.mountPoint.appendingPathComponent("Offload Backup", isDirectory: true)
    }

    func chooseDestination(on volume: VolumeInfo) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = volume.mountPoint
        panel.prompt = "Выбрать"
        panel.message = "Папка для бэкапа на диске «\(volume.name)» — можно указать уже существующую"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.path.hasPrefix(volume.mountPoint.path + "/") else {
            error = "Папка должна лежать на диске «\(volume.name)»."
            return
        }
        destinationPath = url.path
    }

    private func persist() {
        UserDefaults.standard.set(sources.map(\.path), forKey: Self.sourcesKey)
        UserDefaults.standard.set(excludedText, forKey: Self.excludedKey)
        UserDefaults.standard.set(destinationPath, forKey: Self.destinationKey)
    }

    func addSources() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Добавить"
        panel.message = "Выберите папки с проектами и документами для бэкапа"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !sources.contains(url) { sources.append(url) }
    }

    func run(on volume: VolumeInfo, app: AppModel) {
        let token = CancelToken()
        self.token = token
        app.beginOperation(operationID) { token.cancel() }
        let sources = sources
        let excluded = excludedNames
        let destination = destination(on: volume)
        let throttle = Throttle(interval: 0.2)
        let counter = Counter()
        isRunning = true
        report = nil
        error = nil
        copiedBytes = 0
        currentItem = ""
        Task {
            do {
                report = try await Task.detached(priority: .userInitiated) {
                    try BackupEngine.run(sources: sources, destination: destination, excludedNames: excluded,
                                         isCancelled: { token.isCancelled }) { item, bytes in
                        let total = counter.add(bytes)
                        guard throttle.ready() else { return }
                        Task { @MainActor in
                            guard self.isRunning else { return }
                            self.currentItem = item
                            self.copiedBytes = total
                        }
                    }
                }.value
            } catch is CancellationError {
                self.error = "Бэкап остановлен. Уже скопированные файлы остались на диске."
            } catch {
                self.error = error.localizedDescription
            }
            isRunning = false
            app.endOperation(operationID)
            // Бэкап занял место на диске: без этого в боковой панели оставалась прежняя цифра.
            app.refreshVolumes()
        }
    }

    func cancel() { token.cancel() }

    /// Перечитывает состояние контейнера: есть ли он, зашифрован ли, открыт ли сейчас.
    /// Ответ от прошлого диска не должен перезаписать ответ нового, поэтому есть поколение.
    func refreshVault(on volume: VolumeInfo) {
        let generation = UUID()
        vaultGeneration = generation
        if vault?.volumeID != volume.id { vault = nil }
        Task {
            let state = await Task.detached(priority: .utility) { () -> VaultState in
                let vault = SecretsVault(on: volume)
                return VaultState(volumeID: volume.id, imageURL: vault.imageURL, exists: vault.exists,
                                  isEncrypted: vault.isEncrypted, mount: vault.currentMountPoint())
            }.value
            guard vaultGeneration == generation else { return }
            vault = state
        }
    }

    func createVault(on volume: VolumeInfo, password: String) {
        let vault = SecretsVault(on: volume)
        vaultBusy = true
        vaultMessage = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try vault.create(password: password) }.value
                vaultMessage = Notice.Message(.success, "Контейнер создан, шифрование AES-256 подтверждено. Откройте его, чтобы сложить ключи.")
            } catch {
                vaultMessage = Notice.Message(.error, error.localizedDescription)
            }
            vaultBusy = false
            refreshVault(on: volume)
        }
    }

    func openVault(on volume: VolumeInfo, password: String) {
        let vault = SecretsVault(on: volume)
        vaultBusy = true
        vaultMessage = nil
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) { try vault.attach(password: password) }.value
            } catch {
                vaultMessage = Notice.Message(.error, error.localizedDescription)
            }
            vaultBusy = false
            refreshVault(on: volume)
        }
    }

    func fillVault(on volume: VolumeInfo, app: AppModel) {
        guard let state = vault, let mount = state.mount, state.isEncrypted else { return }
        let home = app.rules.home
        let roots = sources
        vaultBusy = true
        vaultMessage = nil
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                SecretsVault.fill(mount, home: home, projectRoots: roots)
            }.value
            vaultReport = report
            let text = "Сложено файлов: \(report.copied), без изменений: \(report.unchanged)" + (report.problems.isEmpty ? "." : ", проблем: \(report.problems.count).")
            vaultMessage = Notice.Message(report.problems.isEmpty ? .success : .warning, text)
            vaultBusy = false
            app.refreshVolumes()
            refreshVault(on: volume)
        }
    }

    func closeVault(on volume: VolumeInfo) {
        guard let mount = vault?.mount else { return }
        vaultBusy = true
        Task {
            do {
                try await Task.detached { try SecretsVault.detach(mount) }.value
                vaultMessage = Notice.Message(.success, "Контейнер закрыт — данные внутри снова зашифрованы.")
            } catch {
                vaultMessage = Notice.Message(.error, "Закрыть не удалось: \(error.localizedDescription)")
            }
            vaultBusy = false
            refreshVault(on: volume)
        }
    }
}

// MARK: - Docker

@MainActor
@Observable
final class DockerModel {
    enum Status: Equatable {
        case unknown, checking, notInstalled, notRunning, ready
    }

    private(set) var status: Status = .unknown
    private(set) var volumes: [DockerVolume] = []
    var selection: Set<String> = []
    private(set) var activity: [String: Date] = [:]
    private(set) var checking: Set<String> = []
    private(set) var rawBytes: Int64?
    /// Docker ещё считает размеры томов.
    private(set) var sizing = false
    private(set) var archives: [URL] = []
    private(set) var busy: String?
    private(set) var messages: [String] = []
    @ObservationIgnored private var token = CancelToken()
    @ObservationIgnored private var reloadGeneration = UUID()
    @ObservationIgnored private let service = DockerService()

    static func archiveFolder(on volume: VolumeInfo) -> URL {
        volume.mountPoint.appendingPathComponent(SafeMover.folderName, isDirectory: true)
            .appendingPathComponent("docker-volumes", isDirectory: true)
    }

    var selectedBytes: Int64 {
        volumes.filter { selection.contains($0.name) }.compactMap(\.sizeBytes).reduce(0, +)
    }

    func reload(destination: VolumeInfo?) {
        status = .checking
        let service = service
        let generation = UUID()
        reloadGeneration = generation
        Task {
            // Сначала быстрый список без размеров, потом размеры: docker system df работает десятки секунд.
            let quick: (Status, [DockerVolume], Int64?) = await Task.detached(priority: .userInitiated) {
                guard service.isInstalled else { return (.notInstalled, [], nil) }
                guard let volumes = try? service.volumes(withSizes: false) else { return (.notRunning, [], service.rawDiskBytes()) }
                return (.ready, volumes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, service.rawDiskBytes())
            }.value
            guard reloadGeneration == generation else { return }
            status = quick.0
            volumes = quick.1
            rawBytes = quick.2
            selection = selection.intersection(Set(volumes.map(\.name)))
            archives = destination.map { DockerService.archives(on: $0) } ?? []
            guard status == .ready, !volumes.isEmpty else { return }
            sizing = true
            let sizes = await Task.detached(priority: .userInitiated) { service.volumeSizes() }.value
            guard reloadGeneration == generation else { return }
            volumes = volumes.map { DockerVolume(name: $0.name, createdAt: $0.createdAt, sizeBytes: sizes[$0.name], usedBy: $0.usedBy) }
                .sorted { ($0.sizeBytes ?? 0, $1.name) > ($1.sizeBytes ?? 0, $0.name) }
            sizing = false
        }
    }

    func checkActivity(_ names: [String]) {
        let service = service
        for name in names where !checking.contains(name) {
            checking.insert(name)
            Task {
                let date = await Task.detached(priority: .utility) { try? service.lastActivity(of: name) }.value
                if let date { activity[name] = date }
                checking.remove(name)
            }
        }
    }

    func archiveSelected(to volume: VolumeInfo, app: AppModel) {
        let names = volumes.filter { selection.contains($0.name) }.map(\.name)
        guard !names.isEmpty else { return }
        let token = CancelToken()
        self.token = token
        let folder = Self.archiveFolder(on: volume)
        let service = service
        messages = []
        Task {
            for name in names {
                if token.isCancelled { break }
                busy = "«\(name)»: подготовка"
                do {
                    let archive = try await Task.detached(priority: .userInitiated) {
                        let url = try service.archive(name, into: folder, isCancelled: { token.isCancelled }) { status in
                            Task { @MainActor in
                                if self.busy != nil { self.busy = "«\(name)»: \(status.lowercased())" }
                            }
                        }
                        try service.removeVolume(name)
                        return url
                    }.value
                    let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { Format.bytes(Int64($0)) } ?? ""
                    messages.append("✓ «\(name)» упакован в \(archive.lastPathComponent) (\(size)), сверен и убран из Docker.")
                } catch is CancellationError {
                    messages.append("«\(name)»: отменено, том не тронут.")
                } catch {
                    messages.append("✗ «\(name)»: \(error.localizedDescription)")
                }
            }
            busy = nil
            selection = []
            app.refreshVolumes()
            reload(destination: app.destination)
        }
    }

    func restore(_ archive: URL, name: String, app: AppModel) {
        let token = CancelToken()
        self.token = token
        let service = service
        busy = "«\(name)»: подготовка"
        messages = []
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try service.restore(archive: archive, as: name, isCancelled: { token.isCancelled }) { status in
                        Task { @MainActor in
                            if self.busy != nil { self.busy = "«\(name)»: \(status.lowercased())" }
                        }
                    }
                }.value
                messages.append("✓ Том «\(name)» восстановлен из \(archive.lastPathComponent) и сверен. Архив остался на диске.")
            } catch is CancellationError {
                messages.append("«\(name)»: отменено, созданный том удалён.")
            } catch {
                messages.append("✗ «\(name)»: \(error.localizedDescription)")
            }
            busy = nil
            app.refreshVolumes()
            reload(destination: app.destination)
        }
    }

    func cancel() { token.cancel() }
}
