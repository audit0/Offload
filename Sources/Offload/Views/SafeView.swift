import OffloadCore
import SwiftUI

struct SafeView: View {
    @Environment(AppModel.self) private var app
    @State private var password = ""
    @State private var confirmation = ""
    @State private var creatingAnother = false
    @State private var sheet: SafeSheet?
    @State private var excluded: Set<UUID> = []

    enum SafeSheet: Identifiable {
        case changePassword, compact, restoreHeader
        var id: Self { self }
    }

    var body: some View {
        let safe = app.safe
        Form {
            if let message = safe.message {
                Section { Notice(message) }
            }
            Section {
                statusSection
            } header: {
                Text("Сейф на диске")
            } footer: {
                Text("Сейф — зашифрованный образ (AES-256) на внешнем диске. Пока он закрыт, на диске лежит только шифротекст: потерянный или украденный диск ничего не выдаст. Пароль Offload не хранит и не записывает — если его забыть, данные не восстановит никто.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if safe.state?.isEncrypted == true {
                Section {
                    autoCloseSection
                } header: {
                    Text("Автоматическое закрытие")
                } footer: {
                    Text("Пока сейф открыт, ключ шифрования живёт в памяти Mac, а файлы доступны программам под вашей учётной записью. Поэтому лучше не держать его открытым без нужды. При выходе из Offload сейф закрывается всегда.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if app.destination != nil {
                Section {
                    exposureSection
                } header: {
                    Text("Открытые данные на диске")
                }
            }
            if safe.state?.isEncrypted == true {
                Section {
                    keySection
                } header: {
                    Text("Пароль, заголовок, место")
                }
            }
            Section {
                honestySection
            } header: {
                Text("Что защищено, а что нет")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Сейф")
        .disabled(safe.activity != nil && safe.migration == nil)
        .overlay(alignment: .top) {
            if let activity = safe.activity {
                Label(activity, systemImage: "hourglass")
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .changePassword: ChangePasswordSheet()
            case .compact: CompactSheet()
            case .restoreHeader: RestoreHeaderSheet()
            }
        }
    }

    // MARK: - Состояние

    @ViewBuilder
    private var statusSection: some View {
        let safe = app.safe
        if let host = app.destination {
            if let state = safe.state, state.volumeID == host.id {
                if !state.exists || creatingAnother {
                    createForm(host: host, replacing: creatingAnother ? state : nil)
                } else if !state.isEncrypted {
                    Notice(.error, "Образ «\(state.imageURL.lastPathComponent)» не зашифрован или шифрование не подтверждается. Offload не будет класть в него данные.")
                    candidatesPicker(state)
                    Button("Создать настоящий сейф") { creatingAnother = true }
                } else {
                    openedOrClosed(state: state, host: host)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Смотрю, что на диске «\(host.name)»…").foregroundStyle(.secondary) }
            }
        } else {
            Label("Подключите внешний диск — сейф живёт на нём.", systemImage: "externaldrive.badge.xmark").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func openedOrClosed(state: SafeModel.State, host: VolumeInfo) -> some View {
        let safe = app.safe
        HStack(spacing: 14) {
            Image(systemName: state.mount == nil ? "lock.shield.fill" : "lock.open.fill")
                .font(.system(size: 34))
                .foregroundStyle(state.mount == nil ? .green : .orange)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.mount == nil ? "Закрыт" : "Открыт").font(.title3.weight(.semibold))
                Text(state.mount == nil
                     ? "На диске только шифротекст. Чтобы класть в сейф или брать из него, откройте его паролем."
                     : "Перенос, бэкап и ключи сейчас идут сюда. Закройте после работы.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)

        LabeledContent("Образ") { Text("«\(state.imageURL.lastPathComponent)» на «\(host.name)»").textSelection(.enabled) }
        LabeledContent("Шифрование") {
            Text("AES-256" + (state.info?.version.map { ", формат \($0)" } ?? "") + (state.info.map { " · паролей: \($0.passphraseCount)" } ?? ""))
        }
        LabeledContent("Занимает на диске") { Text(Format.bytes(state.allocated)) }
        if let limit = state.sizeLimit {
            LabeledContent("Предел роста") { Text(Format.bytes(limit)) }
        }
        if let volume = app.safeVolume {
            LabeledContent("Свободно внутри") {
                Text("\(Format.bytes(volume.availableBytes))").help("Меньшее из свободного внутри образа и на самом диске")
            }
        }
        if let limit = state.sizeLimit, limit < 20 << 30 {
            Notice(.warning, "Этот образ ограничен \(Format.bytes(limit)): для ключей хватит, а для переноса больших папок — нет. Растянуть APFS внутри образа нельзя, поэтому для переноса нужен отдельный сейф на весь диск.")
            Button("Создать сейф на весь диск…") { creatingAnother = true }
        }
        candidatesPicker(state)

        if state.mount == nil {
            SafeUnlockRow()
        } else {
            HStack {
                Button { safe.close(app: app) } label: { Label("Закрыть сейф", systemImage: "lock.fill") }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                if let mount = state.mount {
                    Button("Показать в Finder") {
                        safe.noteUse()
                        revealInFinder(mount)
                    }
                }
                if let pending = safe.pendingClose {
                    Text("закроется после копирования (\(pending))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func candidatesPicker(_ state: SafeModel.State) -> some View {
        if state.candidates.count > 1 {
            Picker("Какой образ — сейф", selection: Binding(get: { state.imageURL.standardizedFileURL },
                                                          set: { app.safe.choose(image: $0, app: app) })) {
                ForEach(state.candidates, id: \.self) { url in
                    Text(url.lastPathComponent).tag(url.standardizedFileURL)
                }
            }
            .disabled(state.mount != nil)
        }
    }

    @ViewBuilder
    private func createForm(host: VolumeInfo, replacing: SafeModel.State?) -> some View {
        let fields = NewPasswordFields(password: $password, confirmation: $confirmation)
        VStack(alignment: .leading, spacing: 10) {
            Text(replacing == nil ? "На диске «\(host.name)» сейфа пока нет" : "Новый сейф на весь диск «\(host.name)»")
                .font(.headline)
            Text("Образ разрежённый: его предел — весь диск (\(Format.bytes(host.totalBytes))), а места он занимает ровно столько, сколько в нём лежит. Придумайте пароль, который не используете больше нигде. Надёжнее всего — фраза из 4–6 случайных слов.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            fields
            HStack {
                if replacing != nil {
                    Button("Отмена") {
                        creatingAnother = false
                        password = ""; confirmation = ""
                    }
                }
                Button("Создать сейф") {
                    app.safe.create(password: password, app: app)
                    password = ""; confirmation = ""
                    creatingAnother = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!fields.isAcceptable)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Автозакрытие

    @ViewBuilder
    private var autoCloseSection: some View {
        @Bindable var safe = app.safe
        Toggle("Когда Mac уходит в сон", isOn: $safe.closeOnSleep)
        Toggle("Когда экран заблокирован, включилась заставка или сменился пользователь", isOn: $safe.closeOnLock)
        Picker("Если им не пользоваться", selection: $safe.idleMinutes) {
            ForEach(SafeModel.idleChoices, id: \.self) { minutes in
                Text(minutes == 0 ? "не закрывать" : "\(minutes) мин").tag(minutes)
            }
        }
        Toggle("Прерывать копирование ради закрытия", isOn: $safe.interruptOperations)
        Text(safe.interruptOperations
             ? "Идущий перенос отменится, оригиналы останутся на месте: они удаляются только после сверки копии."
             : "Если в сейф идёт копирование, он закроется сразу после его окончания.")
            .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: - Открытые данные

    @ViewBuilder
    private var exposureSection: some View {
        let safe = app.safe
        let plain = app.plainRecords
        let chosen = plain.filter { !excluded.contains($0.id) }
        let bytes = plain.reduce(Int64(0)) { $0 + $1.bytes }
        if let migration = safe.migration {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: migration.bytesTotal > 0 ? Double(migration.bytesDone) / Double(migration.bytesTotal) : 0) {
                    Text("\(migration.index) из \(migration.count): «\(migration.item)» — \(migration.phase.lowercased())")
                }
                Text("\(Format.bytes(migration.bytesDone)) из \(Format.bytes(migration.bytesTotal))").font(.caption).monospacedDigit()
                Button("Остановить") { safe.cancelMigration() }
            }
        } else if plain.isEmpty {
            Label("Перенесённого, лежащего на диске открыто, нет.", systemImage: "checkmark.shield").foregroundStyle(.green)
        } else {
            Notice(.warning, "На диске «\(app.destination?.name ?? "")» открыто лежат перенесённые данные: \(plain.count) \(pluralRu(plain.count, "объект", "объекта", "объектов")), \(Format.bytes(bytes)). Кто получит диск в руки, прочтёт их без пароля.")
            ForEach(plain) { record in
                Toggle(isOn: Binding(get: { !excluded.contains(record.id) },
                                     set: { if $0 { excluded.remove(record.id) } else { excluded.insert(record.id) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: record.originalPath).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text("\(Format.bytes(record.bytes)) · \(relativeToHome(record.originalPath, home: app.rules.home))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Text("Если какой-то программой вы пользуетесь прямо с диска (например, моделями LM Studio), после переноса в сейф укажите ей новую папку и держите сейф открытым, пока она нужна. Такие пункты можно снять.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if app.safeVolume == nil {
                Text(app.targetProblem ?? "Откройте сейф.").font(.callout).foregroundStyle(.secondary)
            } else {
                Button {
                    safe.encrypt(chosen, app: app)
                } label: {
                    Label("Перенести в сейф и удалить открытые копии (\(chosen.count))", systemImage: "lock.doc")
                }
                .disabled(chosen.isEmpty || app.isBusy)
            }
        }
        diskEncryptionNote
    }

    @ViewBuilder
    private var diskEncryptionNote: some View {
        if let host = app.destination, let state = app.safe.state, state.volumeID == host.id {
            if state.hostEncrypted {
                Label("Сам диск «\(host.name)» зашифрован целиком.", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
            } else if ["apfs", "hfs"].contains(host.fsType) {
                Text("Сам диск «\(host.name)» не зашифрован. Его можно зашифровать целиком, не стирая: правый щелчок по диску в Finder → «Зашифровать». Тогда защищено будет и то, что лежит вне сейфа.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Сам диск «\(host.name)» (\(host.fsDisplayName)) зашифровать нельзя: у этой файловой системы шифрования нет. Удалённые с SSD и флешек файлы физически могут оставаться в памяти, пока контроллер их не перезапишет. Для защиты всего диска, как в VeraCrypt при шифровании раздела: перенесите данные, отформатируйте диск в «APFS (зашифрованный)» в Дисковой утилите и верните их.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Пароль и заголовок

    @ViewBuilder
    private var keySection: some View {
        let safe = app.safe
        let closed = !safe.isOpen
        LabeledContent("Пароль") {
            Button("Сменить…") { sheet = .changePassword }.disabled(!closed)
        }
        LabeledContent("Копия заголовка") {
            HStack {
                Button("Сохранить…") { safe.backupHeader(app: app) }
                Button("Восстановить…") { sheet = .restoreHeader }.disabled(!closed)
            }
        }
        LabeledContent("Место на диске") {
            Button("Вернуть…") { sheet = .compact }.disabled(!closed)
        }
        Text(closed
             ? "В заголовке лежит ключ данных, зашифрованный паролем: испортится он — пропадёт всё, даже при верном пароле. Храните копию заголовка отдельно от диска. Место, освобождённое внутри сейфа, идёт под новые данные, но сам образ на диске не уменьшается; сжатие возвращает его частично, а на больших сейфах macOS может не вернуть ничего — Offload покажет, сколько вернулось на самом деле."
             : "Смена пароля, восстановление заголовка и сжатие — на закрытом сейфе.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Честно о защите

    private var honestySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("**Как в VeraCrypt:** AES-256; пароль не хранится и не пишется на диск, в программы уходит только через stdin; шифрование проверяется у самой macOS до открытия и после; автозакрытие по сну, блокировке и простою; резервная копия заголовка; смена пароля без перешифровки данных; перенос со сверкой SHA-256.")
            } icon: { Image(systemName: "checkmark.circle").foregroundStyle(.green) }
            Label {
                Text("**Иначе, чем в VeraCrypt:** нет скрытых томов и правдоподобного отрицания, каскадов шифров и ключевых файлов. Формат образа — родной для macOS: его шифрование написала и проверяет Apple, мы не изобретаем своё. Если нужно именно отрицание существования данных — пользуйтесь VeraCrypt.")
            } icon: { Image(systemName: "minus.circle").foregroundStyle(.orange) }
            Label {
                Text("**Что сейф не защитит:** открытый сейф — от программ, запущенных под вашей учётной записью; Mac с вредоносной программой — от перехвата пароля при вводе; слабый пароль — от перебора.")
            } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary) }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Листы

struct ChangePasswordSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var old = ""
    @State private var new = ""
    @State private var confirmation = ""

    var body: some View {
        let fields = NewPasswordFields(password: $new, confirmation: $confirmation)
        VStack(alignment: .leading, spacing: 12) {
            Text("Сменить пароль сейфа").font(.title3.weight(.semibold))
            SecureField("Текущий пароль", text: $old)
            fields
            Text("Данные не перешифровываются — меняется только заголовок, поэтому это быстро. Копии заголовка, снятые раньше, откроются старым паролем: после смены снимите новую, а старые удалите.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Отмена") { clear(); dismiss() }
                Button("Сменить") {
                    app.safe.changePassword(old: old, new: new, app: app)
                    clear(); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(old.isEmpty || !fields.isAcceptable)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func clear() { old = ""; new = ""; confirmation = "" }
}

struct CompactSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Вернуть место на диск").font(.title3.weight(.semibold))
            Text("Файлы, удалённые или возвращённые из сейфа, продолжают занимать место на диске: образ сам не уменьшается, хотя внутри это место идёт под новые данные. Сжатие отдаёт диску полностью пустые участки образа. На больших сейфах macOS может не найти таких участков — тогда вернётся мало или ничего, и Offload так и скажет.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Пароль сейфа", text: $password)
            HStack {
                Spacer()
                Button("Отмена") { password = ""; dismiss() }
                Button("Сжать") {
                    app.safe.compact(password: password, app: app)
                    password = ""; dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

struct RestoreHeaderSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Восстановить заголовок").font(.title3.weight(.semibold))
            Text("Нужно, если сейф перестал открываться верным паролем (испортился заголовок). Сейф откроется паролем, который действовал, когда снималась копия. Если пароль к копии не подойдёт, прежний заголовок вернётся как был.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(file?.lastPathComponent ?? "Копия не выбрана").lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(file == nil ? .secondary : .primary)
                Spacer()
                Button("Выбрать…") { choose() }
            }
            SecureField("Пароль этой копии", text: $password)
            HStack {
                Spacer()
                Button("Отмена") { password = ""; dismiss() }
                Button("Восстановить") {
                    if let file { app.safe.restoreHeader(from: file, password: password, app: app) }
                    password = ""; dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(file == nil || password.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.message = "Файл копии заголовка (.offload-header)"
        if panel.runModal() == .OK { file = panel.url }
    }
}
