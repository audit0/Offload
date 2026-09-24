import OffloadCore
import SwiftUI

struct SafeView: View {
    @Environment(AppModel.self) private var app
    @State private var password = ""
    @State private var confirmation = ""
    @State private var creatingAnother = false
    /// Предел нового сейфа; nil — весь диск.
    @State private var newLimit: Int64?
    @State private var sheet: SafeSheet?
    @State private var excluded: Set<UUID> = []

    enum SafeSheet: Identifiable {
        case changePassword, compact, restoreHeader, grow
        var id: Self { self }
    }

    var body: some View {
        let safe = app.safe
        PageScroll {
            if let message = safe.message { Notice(message) }
            VStack(alignment: .leading, spacing: 8) {
                Card(spacing: 16) {
                    statusSection
                }
                Text("Сейф — зашифрованный образ (AES-256) на внешнем диске. Пока он закрыт, на диске лежит только шифротекст: потерянный или украденный диск ничего не выдаст. Пароль Offload не хранит и не записывает — если его забыть, данные не восстановит никто.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            if safe.state?.isEncrypted == true {
                CardSection(title: "Автоматическое закрытие",
                            footer: "Пока сейф открыт, ключ шифрования живёт в памяти Mac, а файлы доступны программам под вашей учётной записью. Поэтому лучше не держать его открытым без нужды. При выходе из Offload сейф закрывается всегда.") {
                    autoCloseSection
                }
            }
            if app.destination != nil {
                CardSection(title: "Открытые данные на диске") {
                    exposureSection
                }
            }
            if safe.state?.isEncrypted == true {
                CardSection(title: "Пароль, заголовок, место",
                            footer: safe.isOpen
                                ? "Смена пароля, восстановление заголовка, увеличение и сжатие — на закрытом сейфе."
                                : "В заголовке лежит ключ данных, зашифрованный паролем: испортится он — пропадёт всё, даже при верном пароле. Храните копию заголовка отдельно от диска. Место, освобождённое внутри сейфа, идёт под новые данные, но сам образ на диске не уменьшается; сжатие возвращает его частично, а на больших сейфах macOS может не вернуть ничего — Offload покажет, сколько вернулось на самом деле.") {
                    keySection
                }
            }
            CardSection(title: "Что защищено, а что нет") {
                honestySection
            }
        }
        .navigationTitle("Сейф")
        .disabled(safe.activity != nil && safe.migration == nil)
        .overlay(alignment: .top) {
            if let activity = safe.activity {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activity)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(Theme.cardStroke) }
                .padding(.top, 10)
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .changePassword: ChangePasswordSheet()
            case .compact: CompactSheet()
            case .restoreHeader: RestoreHeaderSheet()
            case .grow: GrowSafeSheet()
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
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Смотрю, что на диске «\(host.name)»…").foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(spacing: 14) {
                IconTile(systemImage: "externaldrive.badge.xmark", tone: .neutral, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Нет внешнего диска").font(.title2.weight(.semibold))
                    Text("Подключите внешний диск — сейф живёт на нём.").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func openedOrClosed(state: SafeModel.State, host: VolumeInfo) -> some View {
        let safe = app.safe
        let isOpen = state.mount != nil
        HStack(spacing: 14) {
            IconTile(systemImage: isOpen ? "lock.open.fill" : "lock.shield.fill", tone: isOpen ? .caution : .good, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(isOpen ? "Сейф открыт" : "Сейф закрыт").font(.title2.weight(.semibold))
                Text(isOpen
                     ? "Перенос, бэкап и ключи сейчас идут сюда. Закройте после работы."
                     : "На диске только шифротекст. Чтобы класть в сейф или брать из него, откройте его паролем.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let mount = state.mount {
                Button("Показать в Finder") {
                    safe.noteUse()
                    revealInFinder(mount)
                }
                Button { safe.close(app: app) } label: { Label("Закрыть сейф", systemImage: "lock.fill") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
        if state.mount == nil {
            SafeUnlockRow().frame(maxWidth: 440)
        } else if let pending = safe.pendingClose {
            Label("Закроется после копирования (\(pending))", systemImage: "clock")
                .font(.callout).foregroundStyle(.secondary)
        }

        Divider()
        HStack(alignment: .top, spacing: 16) {
            fact(Format.bytes(state.allocated), "занимает на диске")
            if let limit = state.sizeLimit {
                fact(Format.bytes(limit), "предел роста")
            }
            if let volume = app.safeVolume {
                fact(Format.bytes(volume.availableBytes), "свободно внутри")
                    .help("Меньшее из свободного внутри образа и на самом диске")
            }
        }
        VStack(spacing: 6) {
            InfoRow(title: "Образ") {
                Text("«\(state.imageURL.lastPathComponent)» на «\(host.name)»").textSelection(.enabled)
            }
            InfoRow("Шифрование", value: "AES-256" + (state.info?.version.map { ", формат \($0)" } ?? "") + (state.info.map { " · паролей: \($0.passphraseCount)" } ?? ""))
        }
        .font(.callout)
        if let limit = state.sizeLimit, limit < 20 << 30 {
            Notice(.warning, "Этот сейф ограничен \(Format.bytes(limit)): для ключей хватит, а для переноса больших папок — нет. Предел можно увеличить — содержимое останется на месте.")
            HStack {
                Button { sheet = .grow } label: { Label("Увеличить предел…", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderedProminent)
                Button("Создать другой сейф…") { creatingAnother = true }
            }
        }
        candidatesPicker(state)
    }

    private func fact(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        HStack(alignment: .top, spacing: 14) {
            IconTile(systemImage: "lock.shield", tone: .brand, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(replacing == nil ? "На диске «\(host.name)» сейфа пока нет" : "Новый сейф на диске «\(host.name)»")
                    .font(.title2.weight(.semibold))
                Text("Образ разрежённый: места он занимает ровно столько, сколько в нём лежит, а предел лишь не даёт ему вырасти больше. Предел потом можно увеличить. Придумайте пароль, который не используете больше нигде. Надёжнее всего — фраза из 4–6 случайных слов.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            Picker("Предел сейфа", selection: $newLimit) {
                ForEach(SafeModel.limitChoices(host: host), id: \.self) { limit in
                    Text(limit == host.totalBytes ? "весь диск (\(Format.bytes(limit)))" : Format.bytes(limit))
                        .tag(limit == host.totalBytes ? Int64?.none : Int64?.some(limit))
                }
            }
            .fixedSize()
            Text("Остальное место на «\(host.name)» остаётся для обычных файлов, пока сейф до него не дорос.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        fields.frame(maxWidth: 440)
        HStack {
            if replacing != nil {
                Button("Отмена") {
                    creatingAnother = false
                    password = ""; confirmation = ""
                }
            }
            Button("Создать сейф") {
                app.safe.create(password: password, limit: newLimit ?? host.totalBytes, app: app)
                password = ""; confirmation = ""
                creatingAnother = false
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!fields.isAcceptable)
        }
    }

    // MARK: - Автозакрытие

    @ViewBuilder
    private var autoCloseSection: some View {
        @Bindable var safe = app.safe
        ToggleRow(title: "Когда Mac уходит в сон", isOn: $safe.closeOnSleep)
        RowDivider()
        ToggleRow(title: "Когда экран заблокирован, включилась заставка или сменился пользователь", isOn: $safe.closeOnLock)
        RowDivider()
        FormRow(title: "Если им не пользоваться") {
            Picker("Если им не пользоваться", selection: $safe.idleMinutes) {
                ForEach(SafeModel.idleChoices, id: \.self) { minutes in
                    Text(minutes == 0 ? "не закрывать" : "\(minutes) мин").tag(minutes)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        RowDivider()
        ToggleRow(title: "Прерывать копирование ради закрытия",
                  detail: safe.interruptOperations
                      ? "Идущий перенос отменится, оригиналы останутся на месте: они удаляются только после сверки копии."
                      : "Если в сейф идёт копирование, он закроется сразу после его окончания.",
                  isOn: $safe.interruptOperations)
    }

    // MARK: - Открытые данные

    @ViewBuilder
    private var exposureSection: some View {
        let safe = app.safe
        let plain = app.plainRecords
        let chosen = plain.filter { !excluded.contains($0.id) }
        let bytes = plain.reduce(Int64(0)) { $0 + $1.bytes }
        if let migration = safe.migration {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(migration.index) из \(migration.count): «\(migration.item)» — \(migration.phase.lowercased())")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(Format.bytes(migration.bytesDone)) из \(Format.bytes(migration.bytesTotal))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                ProgressView(value: migration.bytesTotal > 0 ? Double(migration.bytesDone) / Double(migration.bytesTotal) : 0)
                Button("Остановить") { safe.cancelMigration() }
            }
            .rowPadding()
        } else if plain.isEmpty {
            Label("Перенесённого, лежащего на диске открыто, нет.", systemImage: "checkmark.shield.fill")
                .foregroundStyle(.green)
                .rowPadding()
        } else {
            Notice(.warning, "На диске «\(app.destination?.name ?? "")» открыто лежат перенесённые данные: \(plain.count) \(pluralRu(plain.count, "объект", "объекта", "объектов")), \(Format.bytes(bytes)). Кто получит диск в руки, прочтёт их без пароля.")
                .padding(12)
            ForEach(plain) { record in
                Toggle(isOn: Binding(get: { !excluded.contains(record.id) },
                                     set: { if $0 { excluded.remove(record.id) } else { excluded.insert(record.id) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: record.originalPath).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text("\(Format.bytes(record.bytes)) · \(relativeToHome(record.originalPath, home: app.rules.home))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.leading, 4)
                }
                .toggleStyle(.checkbox)
                .rowPadding()
                RowDivider()
            }
            VStack(alignment: .leading, spacing: 10) {
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
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty || app.isBusy)
                }
            }
            .rowPadding()
        }
        diskEncryptionNote
    }

    @ViewBuilder
    private var diskEncryptionNote: some View {
        if let host = app.destination, let state = app.safe.state, state.volumeID == host.id {
            RowDivider()
            Group {
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
            .rowPadding()
        }
    }

    // MARK: - Пароль и заголовок

    @ViewBuilder
    private var keySection: some View {
        let safe = app.safe
        let closed = !safe.isOpen
        FormRow(title: "Пароль", detail: "Данные не перешифровываются — меняется только заголовок.") {
            Button("Сменить…") { sheet = .changePassword }.disabled(!closed)
        }
        RowDivider()
        FormRow(title: "Копия заголовка", detail: "Храните отдельно от диска: без заголовка сейф не откроется.") {
            HStack {
                Button("Сохранить…") { safe.backupHeader(app: app) }
                Button("Восстановить…") { sheet = .restoreHeader }.disabled(!closed)
            }
        }
        RowDivider()
        FormRow(title: "Предел роста",
                detail: "Сейчас \(app.safe.state?.sizeLimit.map { Format.bytes($0) } ?? "неизвестно"). Увеличивается без потери содержимого.") {
            Button("Увеличить…") { sheet = .grow }.disabled(!closed)
        }
        RowDivider()
        FormRow(title: "Место на диске", detail: "Образ сам не уменьшается, когда из сейфа удаляют файлы.") {
            Button("Вернуть…") { sheet = .compact }.disabled(!closed)
        }
    }

    // MARK: - Честно о защите

    private var honestySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            honesty("checkmark.circle.fill", .good, "**Как в VeraCrypt:** AES-256; пароль не хранится и не пишется на диск, в программы уходит только через stdin; шифрование проверяется у самой macOS до открытия и после; автозакрытие по сну, блокировке и простою; резервная копия заголовка; смена пароля без перешифровки данных; перенос со сверкой SHA-256.")
            honesty("minus.circle.fill", .caution, "**Иначе, чем в VeraCrypt:** нет скрытых томов и правдоподобного отрицания, каскадов шифров и ключевых файлов. Формат образа — родной для macOS: его шифрование написала и проверяет Apple, мы не изобретаем своё. Если нужно именно отрицание существования данных — пользуйтесь VeraCrypt.")
            honesty("exclamationmark.triangle.fill", .neutral, "**Что сейф не защитит:** открытый сейф — от программ, запущенных под вашей учётной записью; Mac с вредоносной программой — от перехвата пароля при вводе; слабый пароль — от перебора.")
        }
        .font(.callout)
        .padding(Theme.cardPadding)
    }

    /// Текст — LocalizedStringKey, а не String: иначе выделение **жирным** не отрисуется.
    private func honesty(_ symbol: String, _ tone: Tone, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tone.color)
        }
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
        SheetLayout(systemImage: "key.fill", title: "Сменить пароль сейфа",
                    subtitle: "Данные не перешифровываются — меняется только заголовок, поэтому это быстро.") {
            SecureField("Текущий пароль", text: $old)
                .textFieldStyle(.roundedBorder)
            fields
            Text("Копии заголовка, снятые раньше, откроются старым паролем: после смены снимите новую, а старые удалите.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("Отмена") { clear(); dismiss() }
            Button("Сменить") {
                app.safe.changePassword(old: old, new: new, app: app)
                clear(); dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(old.isEmpty || !fields.isAcceptable)
        }
    }

    private func clear() { old = ""; new = ""; confirmation = "" }
}

struct CompactSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        SheetLayout(systemImage: "arrow.down.right.and.arrow.up.left", title: "Вернуть место на диск") {
            Text("Файлы, удалённые или возвращённые из сейфа, продолжают занимать место на диске: образ сам не уменьшается, хотя внутри это место идёт под новые данные. Сжатие отдаёт диску полностью пустые участки образа. На больших сейфах macOS может не найти таких участков — тогда вернётся мало или ничего, и Offload так и скажет.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Пароль сейфа", text: $password)
                .textFieldStyle(.roundedBorder)
        } actions: {
            Button("Отмена") { password = ""; dismiss() }
            Button("Сжать") {
                app.safe.compact(password: password, app: app)
                password = ""; dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(password.isEmpty)
        }
    }
}

/// Увеличить предел сейфа. Открывается и из «Сейфа», и из «Разобрать», когда выбранное не помещается.
struct GrowSafeSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var limit: Int64?
    @State private var password = ""
    /// Сколько человек собирается положить — чтобы сразу предложить подходящий предел.
    var needed: Int64 = 0

    var body: some View {
        let safe = app.safe
        let current = safe.state?.sizeLimit ?? 0
        let choices = app.destination.map { SafeModel.limitChoices(host: $0, above: current) } ?? []
        let target = (safe.state?.allocated ?? 0) + needed
        let chosen = limit ?? choices.first { $0 >= target } ?? choices.last
        SheetLayout(systemImage: "arrow.up.left.and.arrow.down.right", title: "Увеличить предел сейфа",
                    subtitle: "Сейчас — \(Format.bytes(current))") {
            Text("Содержимое остаётся на месте, а места на диске образ занимает столько же, сколько занимал: предел лишь разрешает ему расти.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if choices.isEmpty {
                Notice(.info, "Сейф уже может занять весь диск — увеличивать некуда.")
            } else {
                Picker("Новый предел", selection: Binding(get: { chosen }, set: { limit = $0 })) {
                    ForEach(choices, id: \.self) { value in
                        Text(value == app.destination?.totalBytes ? "весь диск (\(Format.bytes(value)))" : Format.bytes(value))
                            .tag(Int64?.some(value))
                    }
                }
                .fixedSize()
                if needed > 0, let chosen, chosen < target {
                    Text("Выбранное для сейфа (\(Format.bytes(needed))) при таком пределе поместится не целиком.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if safe.isOpen {
                    HStack {
                        Text("Сейф открыт — увеличить можно только закрытый.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Закрыть сейф") { safe.close(app: app) }
                    }
                } else {
                    SecureField("Пароль сейфа", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                Text("На время увеличения сейф ненадолго подключится без открытия: файлы не видны ни Finder, ни программам.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("Отмена") { password = ""; dismiss() }
            Button("Увеличить") {
                if let chosen { safe.grow(to: chosen, password: password, app: app) }
                password = ""; dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(chosen == nil || password.isEmpty || safe.isOpen || safe.activity != nil)
        }
    }
}

struct RestoreHeaderSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var password = ""

    var body: some View {
        SheetLayout(systemImage: "arrow.counterclockwise", tone: .caution, title: "Восстановить заголовок") {
            Text("Нужно, если сейф перестал открываться верным паролем (испортился заголовок). Сейф откроется паролем, который действовал, когда снималась копия. Если пароль к копии не подойдёт, прежний заголовок вернётся как был.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Image(systemName: "doc").foregroundStyle(.secondary)
                Text(file?.lastPathComponent ?? "Копия не выбрана").lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(file == nil ? .secondary : .primary)
                Spacer()
                Button("Выбрать…") { choose() }
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            SecureField("Пароль этой копии", text: $password)
                .textFieldStyle(.roundedBorder)
        } actions: {
            Button("Отмена") { password = ""; dismiss() }
            Button("Восстановить") {
                if let file { app.safe.restoreHeader(from: file, password: password, app: app) }
                password = ""; dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(file == nil || password.isEmpty)
        }
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
