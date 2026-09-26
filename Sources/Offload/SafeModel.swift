import AppKit
import Observation
import OffloadCore

/// Сейф — зашифрованный образ (AES-256, APFS внутри) на внешнем диске.
///
/// Пока он открыт, перенос, бэкап и ключи идут в него; закрыт — на диске лежит только
/// шифротекст, и потерянный или украденный диск ничего не выдаёт. Пароль Offload не хранит:
/// он приходит из поля ввода, уходит в hdiutil через stdin и больше нигде не живёт.
@MainActor
@Observable
final class SafeModel {
    struct State: Equatable {
        /// Внешний диск, на котором лежит образ.
        var volumeID: String
        var imageURL: URL
        var exists: Bool
        var isEncrypted: Bool
        var info: SecretsVault.EncryptionInfo?
        var sizeLimit: Int64?
        var allocated: Int64
        var mount: URL?
        var candidates: [URL]
        /// Зашифрован ли сам внешний диск целиком (APFS с шифрованием).
        var hostEncrypted: Bool

        var displayName: String { imageURL.deletingPathExtension().lastPathComponent }
    }

    /// Перенос открытых архивов внутрь сейфа: какой по счёту и сколько байт.
    struct Migration: Equatable {
        var index: Int
        var count: Int
        var item: String
        var phase: String
        var bytesDone: Int64
        var bytesTotal: Int64
    }

    private(set) var state: State?
    /// Что сейчас делается с сейфом («Открываю…»): пока не nil, кнопки заблокированы.
    private(set) var activity: String?
    private(set) var migration: Migration?
    var message: Notice.Message?
    /// Почему не открылся: показывается прямо под полем пароля — там, где его вводили,
    /// будь то «Сейф», «Разобрать» или панель слева. Раньше ошибка была видна только
    /// в разделе «Сейф», а в остальных местах поле просто очищалось, и казалось, что ничего не произошло.
    var unlockError: String?
    /// Закрыть не дали открытые в сейфе файлы: предложить закрыть принудительно.
    var closeBlocked = false
    /// Куда смонтированы открытые зашифрованные образы — в том числе открытые в Finder.
    /// Такой том — это сейф, а не ещё один внешний диск, и в списке дисков его быть не должно.
    private(set) var encryptedMounts: Set<String> = []
    /// Почему сейф закроется, как только закончится идущая операция.
    private(set) var pendingClose: String?

    var closeOnSleep: Bool { didSet { persist() } }
    var closeOnLock: Bool { didSet { persist() } }
    /// Через сколько минут простоя закрывать сам; 0 — не закрывать.
    var idleMinutes: Int { didSet { persist() } }
    /// Закрывать даже посреди копирования: операция отменяется, оригиналы остаются на месте.
    var interruptOperations: Bool { didSet { persist() } }

    @ObservationIgnored private var preferredImages: [String: String] { didSet { persist() } }
    @ObservationIgnored private var lastUse = Date()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var idleTimer: Timer?
    @ObservationIgnored private var migrationToken: CancelToken?
    /// Формат и число паролей: у открытого образа macOS их не сообщает — помним с закрытого.
    @ObservationIgnored private var knownInfo: [String: SecretsVault.EncryptionInfo] = [:]

    var isOpen: Bool { state?.mount != nil }
    var exists: Bool { state?.exists == true }

    static let idleChoices = [0, 5, 15, 30, 60]

    init() {
        let defaults = UserDefaults.standard
        closeOnSleep = defaults.object(forKey: "safe.closeOnSleep") as? Bool ?? true
        closeOnLock = defaults.object(forKey: "safe.closeOnLock") as? Bool ?? true
        idleMinutes = defaults.object(forKey: "safe.idleMinutes") as? Int ?? 30
        interruptOperations = defaults.object(forKey: "safe.interrupt") as? Bool ?? false
        preferredImages = defaults.dictionary(forKey: "safe.images") as? [String: String] ?? [:]
    }

    private func persist() {
        guard !Demo.isOn else { return }
        let defaults = UserDefaults.standard
        defaults.set(closeOnSleep, forKey: "safe.closeOnSleep")
        defaults.set(closeOnLock, forKey: "safe.closeOnLock")
        defaults.set(idleMinutes, forKey: "safe.idleMinutes")
        defaults.set(interruptOperations, forKey: "safe.interrupt")
        defaults.set(preferredImages, forKey: "safe.images")
    }

    // MARK: - Состояние

    /// Перечитывает, что с сейфом на выбранном диске. Ответ привязан к диску: запрос про
    /// прежний диск, пришедший последним, не должен перезаписать состояние нового.
    func refresh(app: AppModel) {
        if Demo.isOn {
            state = Demo.safeState
            return
        }
        guard let host = app.destination else {
            state = nil
            return
        }
        let generation = UUID()
        self.generation = generation
        if state?.volumeID != host.id { state = nil }
        let preferred = preferredImages[host.id].map { URL(fileURLWithPath: $0, isDirectory: true) }
        Task {
            let (found, mounts) = await Task.detached(priority: .utility) { () -> (State, Set<String>) in
                // Один `hdiutil info` на всё: открыт ли сейф, какие образы открыты вообще.
                let attached = SecretsVault.attachedImages()
                let vault = SecretsVault(on: host, preferred: preferred, attached: attached)
                let status = vault.status(attached: attached)
                let state = State(volumeID: host.id, imageURL: vault.imageURL, exists: status.exists, isEncrypted: status.isEncrypted,
                                  info: status.info, sizeLimit: status.exists ? vault.sizeLimit : nil,
                                  allocated: status.exists ? vault.allocatedBytes : 0, mount: status.mountPoint,
                                  candidates: SecretsVault.candidates(in: host.mountPoint, attached: attached),
                                  hostEncrypted: Volumes.isVolumeEncrypted(host))
                return (state, Self.mounts(of: attached))
            }.value
            updateEncryptedMounts(mounts, app: app)
            guard self.generation == generation, app.destinationID == found.volumeID else { return }
            var snapshot = found
            if let info = snapshot.info {
                knownInfo[snapshot.imageURL.path] = info
            } else {
                snapshot.info = knownInfo[snapshot.imageURL.path]
            }
            state = snapshot
        }
    }

    nonisolated static func mounts(of attached: [String: SecretsVault.Attachment]) -> Set<String> {
        Set(attached.values.filter(\.encrypted).compactMap { $0.mountPoint?.standardizedFileURL.path })
    }

    /// Открытые зашифрованные образы изменились: список внешних дисков — без них.
    func updateEncryptedMounts(_ mounts: Set<String>, app: AppModel) {
        guard mounts != encryptedMounts else { return }
        encryptedMounts = mounts
        app.refreshVolumes()
    }

    /// Перечитать только, какие зашифрованные образы открыты, — после подключения диска или тома.
    func reloadEncryptedMounts(app: AppModel) async {
        guard !Demo.isOn else { return }
        let mounts = await Task.detached(priority: .utility) { Self.mounts(of: SecretsVault.attachedImages()) }.value
        updateEncryptedMounts(mounts, app: app)
    }

    /// Сейф как место назначения: том внутри образа, а свободное место — меньшее из того,
    /// что осталось внутри образа и на самом диске.
    func volume(host: VolumeInfo?) -> VolumeInfo? {
        if Demo.isOn { return isOpen ? Demo.safeVolume : nil }
        guard let host, let state, state.volumeID == host.id, state.isEncrypted, let mount = state.mount else { return nil }
        return Volumes.safe(mountedAt: mount, host: host)
    }

    /// Какой из зашифрованных образов на диске считать сейфом.
    func choose(image: URL, app: AppModel) {
        guard let host = app.destination else { return }
        preferredImages[host.id] = image.path
        refresh(app: app)
    }

    // MARK: - Открыть, закрыть, создать

    /// `failed` — своя реакция на ошибку вместо общего сообщения вверху раздела.
    private func perform(_ title: String, app: AppModel,
                         _ work: @escaping @Sendable () throws -> Notice.Message?,
                         failed: (@MainActor (Error) -> Void)? = nil,
                         after: @escaping @MainActor () -> Void = {}) {
        guard activity == nil else { return }
        activity = title
        message = nil
        Task {
            do {
                if let result = try await Task.detached(priority: .userInitiated, operation: work).value { message = result }
            } catch {
                if let failed { failed(error) } else { message = Notice.Message(.error, error.localizedDescription) }
            }
            activity = nil
            after()
            app.refreshVolumes()
            refresh(app: app)
        }
    }

    /// Сейф на выбранном диске с пределом `limit`. Образ разрежённый: места он занимает
    /// ровно столько, сколько в нём лежит, а предел потом можно увеличить (`grow`).
    func create(password: String, limit: Int64, app: AppModel) {
        guard let host = app.destination else { return }
        let vault = SecretsVault(imageURL: host.mountPoint.appendingPathComponent(SecretsVault.safeImageName, isDirectory: true))
        let limit = min(max(limit, 1 << 30), host.totalBytes)
        perform("Создаю сейф…", app: app, {
            try vault.create(password: password, maxBytes: limit, volumeName: SecretsVault.safeVolumeName)
            return Notice.Message(.success, "Сейф создан: AES-256, пароль знаете только вы. Если его забыть, данные не восстановит никто — даже Offload.")
        }, after: { [weak self] in
            self?.preferredImages[host.id] = vault.imageURL.path
        })
    }

    /// Увеличивает предел закрытого сейфа; содержимое остаётся на месте.
    func grow(to limit: Int64, password: String, app: AppModel) {
        guard let state, state.exists, state.mount == nil else { return }
        let vault = SecretsVault(imageURL: state.imageURL)
        perform("Увеличиваю сейф…", app: app) {
            try vault.grow(to: limit, password: password)
            return Notice.Message(.success, "Предел сейфа — \(Format.bytes(vault.sizeLimit ?? limit)). Содержимое на месте, а места на диске образ занимает столько же, сколько занимал.")
        }
    }

    /// Какие пределы предложить: круглые размеры больше `above` и меньше диска, и весь диск.
    static func limitChoices(host: VolumeInfo, above: Int64 = 0) -> [Int64] {
        let gigabyte: Int64 = 1_000_000_000
        let presets: [Int64] = [8, 16, 32, 64, 128, 256, 512, 1000, 2000, 4000].map { $0 * gigabyte }
        return presets.filter { $0 > above && $0 < host.totalBytes * 9 / 10 } + (host.totalBytes > above ? [host.totalBytes] : [])
    }

    /// Сколько примерно ещё поместится в сейф. Открыт — точно (с учётом места на диске);
    /// закрыт — предел минус занятое образом, но не больше свободного на диске.
    func roomLeft(host: VolumeInfo?, volume: VolumeInfo?) -> Int64? {
        if let volume { return volume.availableBytes }
        guard let host, let state, state.volumeID == host.id, state.isEncrypted, let limit = state.sizeLimit else { return nil }
        return max(0, min(limit - state.allocated, host.availableBytes))
    }

    func open(password: String, app: AppModel) {
        guard let state, state.exists else { return }
        let vault = SecretsVault(imageURL: state.imageURL)
        let opened = Collector<URL>()
        unlockError = nil
        perform("Открываю сейф…", app: app, {
            opened.append(try vault.attach(password: password))
            return nil
        }, failed: { [weak self] error in
            self?.unlockError = error.localizedDescription
        }, after: { [weak self] in
            guard let self else { return }
            lastUse = Date()
            // Сразу, не дожидаясь перечитывания: attach уже спросил macOS, что том зашифрован.
            if let mount = opened.all.first, self.state?.imageURL == vault.imageURL {
                self.state?.mount = mount
                self.state?.isEncrypted = true
            }
        })
    }

    /// Закрыть по команде человека. Если в сейф прямо сейчас пишется, он закроется сразу
    /// после конца операции: оборвать копирование ради закрытия — не то, чего человек ждёт.
    func close(app: AppModel, force: Bool = false, reason: String? = nil) {
        guard let mount = state?.mount else { return }
        if app.isBusy, !force {
            pendingClose = reason ?? "по вашей команде"
            message = Notice.Message(.info, "Идёт копирование — сейф закроется, как только оно закончится.")
            return
        }
        pendingClose = nil
        closeBlocked = false
        perform("Закрываю сейф…", app: app, {
            try SecretsVault.detach(mount, force: force)
            return Notice.Message(.success, reason.map { "Сейф закрыт: \($0)." } ?? "Сейф закрыт — на диске снова только шифротекст.")
        }, failed: { [weak self] error in
            // Открытые файлы — не ошибка, а вопрос: закрыть ли принудительно (см. ContentView).
            if (error as? VaultError) == .busy {
                self?.closeBlocked = true
            } else {
                self?.message = Notice.Message(.error, error.localizedDescription)
            }
        })
    }

    // MARK: - Автозакрытие

    /// Подписка на сон, блокировку экрана, заставку, смену пользователя и таймер простоя —
    /// то же, что «Auto-dismount» в VeraCrypt. Ключ шифрования живёт в памяти, пока сейф открыт,
    /// и лучший способ его защитить — не держать сейф открытым без нужды.
    func startGuards(app: AppModel) {
        // Вымышленный сейф закрывать нечем и незачем.
        guard !Demo.isOn else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self, weak app] _ in
            MainActor.assumeIsolated {
                guard let self, let app, self.closeOnSleep else { return }
                self.closeNow(reason: "Mac уходит в сон", app: app)
            }
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self, weak app] _ in
            MainActor.assumeIsolated {
                guard let self, let app, self.closeOnLock else { return }
                self.trigger("сменился пользователь", app: app)
            }
        }))
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            observers.append((distributed, distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self, weak app] _ in
                MainActor.assumeIsolated {
                    guard let self, let app, self.closeOnLock else { return }
                    self.trigger("экран заблокирован", app: app)
                }
            }))
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self, weak app] _ in
            MainActor.assumeIsolated {
                guard let self, let app else { return }
                self.checkIdle(app: app)
            }
        }
    }

    /// Любая работа с сейфом откладывает закрытие по простою.
    func noteUse() { lastUse = Date() }

    /// Операции закончились: если закрытие было отложено ради них — закрываем.
    func operationsFinished(app: AppModel) {
        lastUse = Date()
        if let reason = pendingClose { close(app: app, reason: reason) }
    }

    func trigger(_ reason: String, app: AppModel) {
        guard isOpen else { return }
        if app.isBusy {
            pendingClose = reason
            if interruptOperations {
                app.cancelEverything()
            } else {
                message = Notice.Message(.info, "Сейф закроется, как только закончится копирование (\(reason)).")
            }
            return
        }
        close(app: app, reason: reason)
    }

    /// Перед сном асинхронная задача может не успеть выполниться, поэтому закрываем прямо здесь.
    /// Если в сейф пишется, а прерывать операции не разрешено, он останется открытым —
    /// и об этом будет сказано, а не промолчано.
    private func closeNow(reason: String, app: AppModel) {
        guard let mount = state?.mount else { return }
        if app.isBusy, !interruptOperations {
            pendingClose = reason
            message = Notice.Message(.warning, "Перед сном сейф остался открытым: шло копирование. Он закроется, как только оно закончится.")
            return
        }
        if app.isBusy { app.cancelEverything() }
        do {
            try SecretsVault.detach(mount, force: interruptOperations)
            state?.mount = nil
            message = Notice.Message(.success, "Сейф закрыт: \(reason).")
        } catch {
            message = Notice.Message(.warning, "Перед сном сейф закрыть не удалось: \(error.localizedDescription)")
        }
        app.refreshVolumes()
    }

    private func checkIdle(app: AppModel) {
        guard idleMinutes > 0, isOpen, !app.isBusy, activity == nil,
              Date().timeIntervalSince(lastUse) > TimeInterval(idleMinutes * 60),
              let mount = state?.mount else { return }
        // Без force: если в сейфе открыты файлы (им пользуются в Finder или в программе),
        // закрытие откажет — и правильно. Попробуем снова через тот же срок.
        lastUse = Date()
        Task {
            let closed = await Task.detached { (try? SecretsVault.detach(mount)) != nil }.value
            if closed {
                message = Notice.Message(.success, "Сейф закрыт: им не пользовались \(idleMinutes) мин.")
            }
            app.refreshVolumes()
            refresh(app: app)
        }
    }

    // MARK: - Пароль, заголовок, место

    func changePassword(old: String, new: String, app: AppModel) {
        guard let state, state.exists, state.mount == nil else { return }
        let vault = SecretsVault(imageURL: state.imageURL)
        perform("Меняю пароль…", app: app) {
            try vault.changePassword(old: old, new: new)
            return Notice.Message(.success, "Пароль сменён.", details: [
                "Копии заголовка, снятые раньше, по-прежнему открываются старым паролем. Снимите новую копию, а старые удалите.",
            ])
        }
    }

    func compact(password: String, app: AppModel) {
        guard let state, state.exists, state.mount == nil else { return }
        let vault = SecretsVault(imageURL: state.imageURL)
        let before = state.allocated
        perform("Возвращаю место на диск…", app: app) {
            try vault.compact(password: password)
            let after = vault.allocatedBytes
            let returned = max(0, before - after)
            if returned < 16 << 20 {
                return Notice.Message(.info, "macOS не нашла в образе пустых участков: диску вернулось \(Format.bytes(returned)). Место внутри сейфа при этом свободно и пойдёт под новые данные.")
            }
            return Notice.Message(.success, "Диску возвращено \(Format.bytes(returned)). Сейф занимает \(Format.bytes(after)).")
        }
    }

    func backupHeader(app: AppModel) {
        guard let state, state.isEncrypted, state.mount == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Сохранить сюда"
        panel.message = "Куда положить копию заголовка сейфа. Лучше не на тот же диск: если он откажет, пропадут и сейф, и копия."
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let vault = SecretsVault(imageURL: state.imageURL)
        let sameDisk = directory.path.hasPrefix(state.imageURL.deletingLastPathComponent().path + "/")
        perform("Сохраняю копию заголовка…", app: app) {
            let url = try vault.backupHeader(to: directory)
            var details = ["Копия защищена тем же паролем, что и сейф. Без пароля она бесполезна."]
            if sameDisk { details.append("Копия лежит на том же диске, что и сейф: при отказе диска пропадут обе. Сохраните ещё одну в другом месте.") }
            return Notice.Message(.success, "Копия заголовка сохранена: \(url.path)", details: details)
        }
    }

    func restoreHeader(from file: URL, password: String, app: AppModel) {
        guard let state, state.exists, state.mount == nil else { return }
        let vault = SecretsVault(imageURL: state.imageURL)
        perform("Восстанавливаю заголовок…", app: app) {
            try vault.restoreHeader(from: file, password: password)
            return Notice.Message(.success, "Заголовок восстановлен из копии, сейф открывается паролем этой копии.")
        }
    }

    // MARK: - Зашифровать перенесённое

    /// Переносит архивы, лежащие на диске открыто, внутрь сейфа — по одному, со сверкой.
    func encrypt(_ records: [MoveRecord], app: AppModel) {
        guard let safe = volume(host: app.destination), migration == nil, activity == nil else { return }
        let token = CancelToken()
        migrationToken = token
        let operationID = app.beginOperation { token.cancel() }
        let rules = app.rules
        let throttle = Throttle()
        migration = Migration(index: 0, count: records.count, item: "", phase: "", bytesDone: 0, bytesTotal: 0)
        message = nil
        Task {
            var done = 0
            var failures: [String] = []
            for (index, record) in records.enumerated() {
                if token.isCancelled { break }
                let name = URL(fileURLWithPath: record.originalPath).lastPathComponent
                migration = Migration(index: index + 1, count: records.count, item: name, phase: "Подготовка", bytesDone: 0, bytesTotal: 0)
                do {
                    _ = try await Task.detached(priority: .userInitiated) {
                        try SafeMover(rules: rules).relocate(record, into: safe, isCancelled: { token.isCancelled }) { progress in
                            guard throttle.ready() else { return }
                            Task { @MainActor in
                                self.migration?.phase = progress.phase.rawValue
                                self.migration?.bytesDone = progress.bytesDone
                                self.migration?.bytesTotal = progress.bytesTotal
                            }
                        }
                    }.value
                    done += 1
                } catch is CancellationError {
                    break
                } catch {
                    failures.append("«\(name)»: \(error.localizedDescription)")
                }
            }
            migration = nil
            migrationToken = nil
            app.endOperation(operationID)
            var details = failures
            details.append("Удалённые открытые копии физически могут оставаться в памяти SSD или флешки, пока контроллер их не перезапишет. Полную гарантию даёт только диск, зашифрованный целиком.")
            message = Notice.Message(failures.isEmpty ? .success : .warning,
                                     token.isCancelled
                                         ? "Остановлено. В сейф перенесено: \(done) из \(records.count), остальное осталось на месте как было."
                                         : "В сейф перенесено и сверено: \(done) из \(records.count). Открытые копии удалены.",
                                     details: details)
            app.history.reload(volumes: app.historyVolumes)
            app.refreshVolumes()
            refresh(app: app)
        }
    }

    func cancelMigration() { migrationToken?.cancel() }
}
