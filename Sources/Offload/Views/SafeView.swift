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
                Text(tr("Сейф — зашифрованный образ (AES-256) на внешнем диске. Пока он закрыт, на диске лежит только шифротекст: потерянный или украденный диск ничего не выдаст. Пароль OffLoadAI не хранит и не записывает — если его забыть, данные не восстановит никто."))
                    .font(.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            if safe.state?.isEncrypted == true {
                CardSection(title: tr("Автоматическое закрытие"),
                            footer: tr("Пока сейф открыт, ключ шифрования живёт в памяти Mac, а файлы доступны программам под вашей учётной записью. Поэтому лучше не держать его открытым без нужды. При выходе из OffLoadAI сейф закрывается всегда.")) {
                    autoCloseSection
                }
            }
            if app.destination != nil {
                CardSection(title: tr("Открытые данные на диске")) {
                    exposureSection
                }
            }
            if safe.state?.isEncrypted == true {
                CardSection(title: tr("Пароль, заголовок, место"),
                            footer: safe.isOpen
                                ? tr("Смена пароля, копия и восстановление заголовка, увеличение и сжатие — на закрытом сейфе.")
                                : tr("В заголовке лежит ключ данных, зашифрованный паролем: испортится он — пропадёт всё, даже при верном пароле. Храните копию заголовка отдельно от диска. Место, освобождённое внутри сейфа, идёт под новые данные, но сам образ на диске не уменьшается; сжатие возвращает его частично, а на больших сейфах macOS может не вернуть ничего — OffLoadAI покажет, сколько вернулось на самом деле.")) {
                    keySection
                }
            }
            CardSection(title: tr("Что защищено, а что нет")) {
                honestySection
            }
        }
        .navigationTitle(tr("Сейф"))
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
                    Notice(.error, tr("Образ «\(state.imageURL.lastPathComponent)» не зашифрован или шифрование не подтверждается. OffLoadAI не будет класть в него данные."))
                    candidatesPicker(state)
                    Button(tr("Создать настоящий сейф")) { creatingAnother = true }
                } else {
                    openedOrClosed(state: state, host: host)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(tr("Смотрю, что на диске «\(host.name)»…")).foregroundStyle(Theme.muted)
                }
            }
        } else {
            HStack(spacing: 14) {
                IconTile(systemImage: "externaldrive.badge.xmark", tone: .neutral, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Нет внешнего диска")).font(Theme.display(22))
                    Text(tr("Подключите внешний диск — сейф живёт на нём.")).foregroundStyle(Theme.muted)
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
                Text(isOpen ? tr("Сейф открыт") : tr("Сейф закрыт")).font(Theme.display(22))
                Text(isOpen
                     ? tr("Перенос, бэкап и ключи сейчас идут сюда. Закройте после работы.")
                     : tr("На диске только шифротекст. Чтобы класть в сейф или брать из него, откройте его паролем."))
                    .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let mount = state.mount {
                Button(tr("Показать в Finder")) {
                    safe.noteUse()
                    // Том сейфа скрыт из боковой панели Finder (-nobrowse), поэтому открываем
                    // саму папку тома, а не выделяем её в /Volumes, где её не видно.
                    NSWorkspace.shared.open(mount)
                }
                Button { safe.close(app: app) } label: { Label(tr("Закрыть сейф"), systemImage: "lock.fill") }
                    .prominentButton()
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
        if state.mount == nil {
            SafeUnlockRow().frame(maxWidth: 440)
        } else if let pending = safe.pendingClose {
            Label(tr("Закроется после копирования (\(pending))"), systemImage: "clock")
                .font(.callout).foregroundStyle(Theme.muted)
        }

        Divider()
        HStack(alignment: .top, spacing: 16) {
            fact(Format.bytes(state.allocated), tr("занимает на диске"))
            if let limit = state.sizeLimit {
                fact(Format.bytes(limit), tr("предел роста"))
            }
            if let volume = app.safeVolume {
                fact(Format.bytes(volume.availableBytes), tr("свободно внутри"))
                    .help(tr("Меньшее из свободного внутри образа и на самом диске"))
            }
        }
        VStack(spacing: 6) {
            InfoRow(title: tr("Образ")) {
                Text(tr("«\(state.imageURL.lastPathComponent)» на «\(host.name)»")).textSelection(.enabled)
            }
            InfoRow(tr("Шифрование"), value: "AES-256" + (state.info?.version.map { tr(", формат \($0)") } ?? "") + (state.info.map { tr(" · паролей: \($0.passphraseCount)") } ?? ""))
        }
        .font(.callout)
        if let limit = state.sizeLimit, limit < 20 << 30 {
            Notice(.warning, tr("Этот сейф ограничен \(Format.bytes(limit)): для ключей хватит, а для переноса больших папок — нет. Предел можно увеличить — содержимое останется на месте."))
            HStack {
                Button { sheet = .grow } label: { Label(tr("Увеличить предел…"), systemImage: "arrow.up.left.and.arrow.down.right") }
                    .prominentButton()
                Button(tr("Создать другой сейф…")) { creatingAnother = true }
            }
        }
        candidatesPicker(state)
    }

    private func fact(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Theme.display(20))
                .monospacedDigit()
            Text(title).font(.caption).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func candidatesPicker(_ state: SafeModel.State) -> some View {
        if state.candidates.count > 1 {
            Picker(tr("Какой образ — сейф"), selection: Binding(get: { state.imageURL.standardizedFileURL },
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
                Text(replacing == nil ? tr("На диске «\(host.name)» сейфа пока нет") : tr("Новый сейф на диске «\(host.name)»"))
                    .font(Theme.display(22))
                Text(tr("Образ разрежённый: места он занимает ровно столько, сколько в нём лежит, а предел лишь не даёт ему вырасти больше. Предел потом можно увеличить. Придумайте пароль, который не используете больше нигде. Надёжнее всего — фраза из 4–6 случайных слов."))
                    .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            Picker(tr("Предел сейфа"), selection: $newLimit) {
                ForEach(SafeModel.limitChoices(host: host), id: \.self) { limit in
                    Text(limit == host.totalBytes ? tr("весь диск (\(Format.bytes(limit)))") : Format.bytes(limit))
                        .tag(limit == host.totalBytes ? Int64?.none : Int64?.some(limit))
                }
            }
            .fixedSize()
            Text(tr("Остальное место на «\(host.name)» остаётся для обычных файлов, пока сейф до него не дорос."))
                .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        fields.frame(maxWidth: 440)
        HStack {
            if replacing != nil {
                Button(tr("Отмена")) {
                    creatingAnother = false
                    password = ""; confirmation = ""
                }
            }
            Button(tr("Создать сейф")) {
                app.safe.create(password: password, limit: newLimit ?? host.totalBytes, app: app)
                password = ""; confirmation = ""
                creatingAnother = false
            }
            .prominentButton()
            .keyboardShortcut(.defaultAction)
            .disabled(!fields.isAcceptable)
        }
    }

    // MARK: - Автозакрытие

    @ViewBuilder
    private var autoCloseSection: some View {
        @Bindable var safe = app.safe
        ToggleRow(title: tr("Когда Mac уходит в сон"), isOn: $safe.closeOnSleep)
        RowDivider()
        ToggleRow(title: tr("Когда экран заблокирован, включилась заставка или сменился пользователь"), isOn: $safe.closeOnLock)
        RowDivider()
        FormRow(title: tr("Если им не пользоваться")) {
            Picker(tr("Если им не пользоваться"), selection: $safe.idleMinutes) {
                ForEach(SafeModel.idleChoices, id: \.self) { minutes in
                    Text(minutes == 0 ? tr("не закрывать") : tr("\(minutes) мин")).tag(minutes)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        RowDivider()
        ToggleRow(title: tr("Прерывать копирование ради закрытия"),
                  detail: safe.interruptOperations
                      ? tr("Идущий перенос отменится, оригиналы останутся на месте: они удаляются только после сверки копии.")
                      : tr("Если в сейф идёт копирование, он закроется сразу после его окончания."),
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
                    Text(tr("\(migration.index) из \(migration.count): «\(migration.item)» — \(migration.phase.lowercased())"))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(tr("\(Format.bytes(migration.bytesDone)) из \(Format.bytes(migration.bytesTotal))"))
                        .font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
                }
                ProgressView(value: migration.bytesTotal > 0 ? Double(migration.bytesDone) / Double(migration.bytesTotal) : 0)
                Button(tr("Остановить")) { safe.cancelMigration() }
            }
            .rowPadding()
        } else if plain.isEmpty {
            Label(tr("Перенесённого, лежащего на диске открыто, нет."), systemImage: "checkmark.shield.fill")
                .foregroundStyle(Theme.ok)
                .rowPadding()
        } else {
            Notice(.warning, tr("На диске «\(app.destination?.name ?? "")» открыто лежат перенесённые данные: \(plain.count) \(pluralRu(plain.count, tr("объект"), tr("объекта"), tr("объектов"))), \(Format.bytes(bytes)). Кто получит диск в руки, прочтёт их без пароля."))
                .padding(12)
            ForEach(plain) { record in
                Toggle(isOn: Binding(get: { !excluded.contains(record.id) },
                                     set: { if $0 { excluded.remove(record.id) } else { excluded.insert(record.id) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: record.originalPath).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text("\(Format.bytes(record.bytes)) · \(relativeToHome(record.originalPath, home: app.rules.home))")
                            .font(.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.leading, 4)
                }
                .toggleStyle(.checkbox)
                .rowPadding()
                RowDivider()
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(tr("Если какой-то программой вы пользуетесь прямо с диска (например, моделями LM Studio), после переноса в сейф укажите ей новую папку и держите сейф открытым, пока она нужна. Такие пункты можно снять."))
                    .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if app.safeVolume == nil {
                    Text(app.targetProblem ?? tr("Откройте сейф.")).font(.callout).foregroundStyle(Theme.muted)
                } else {
                    Button {
                        safe.encrypt(chosen, app: app)
                    } label: {
                        Label(tr("Перенести в сейф и удалить открытые копии (\(chosen.count))"), systemImage: "lock.doc")
                    }
                    .prominentButton()
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
                    Label(tr("Сам диск «\(host.name)» зашифрован целиком."), systemImage: "checkmark.shield.fill").foregroundStyle(Theme.ok)
                } else if ["apfs", "hfs"].contains(host.fsType) {
                    Text(tr("Сам диск «\(host.name)» не зашифрован. Его можно зашифровать целиком, не стирая: правый щелчок по диску в Finder → «Зашифровать». Тогда защищено будет и то, что лежит вне сейфа."))
                        .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(tr("Сам диск «\(host.name)» (\(host.fsDisplayName)) зашифровать нельзя: у этой файловой системы шифрования нет. Удалённые с SSD и флешек файлы физически могут оставаться в памяти, пока контроллер их не перезапишет. Для защиты всего диска, как в VeraCrypt при шифровании раздела: перенесите данные, отформатируйте диск в «APFS (зашифрованный)» в Дисковой утилите и верните их."))
                        .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
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
        FormRow(title: tr("Пароль"), detail: tr("Данные не перешифровываются — меняется только заголовок.")) {
            Button(tr("Сменить…")) { sheet = .changePassword }.disabled(!closed)
        }
        RowDivider()
        FormRow(title: tr("Копия заголовка"), detail: tr("Храните отдельно от диска: без заголовка сейф не откроется.")) {
            HStack {
                Button(tr("Сохранить…")) { safe.backupHeader(app: app) }.disabled(!closed)
                Button(tr("Восстановить…")) { sheet = .restoreHeader }.disabled(!closed)
            }
        }
        RowDivider()
        FormRow(title: tr("Предел роста"),
                detail: tr("Сейчас \(app.safe.state?.sizeLimit.map { Format.bytes($0) } ?? tr("неизвестно")). Увеличивается без потери содержимого.")) {
            Button(tr("Увеличить…")) { sheet = .grow }.disabled(!closed)
        }
        RowDivider()
        FormRow(title: tr("Место на диске"), detail: tr("Образ сам не уменьшается, когда из сейфа удаляют файлы.")) {
            Button(tr("Вернуть…")) { sheet = .compact }.disabled(!closed)
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
        SheetLayout(systemImage: "key.fill", title: tr("Сменить пароль сейфа"),
                    subtitle: tr("Данные не перешифровываются — меняется только заголовок, поэтому это быстро.")) {
            SecureField(tr("Текущий пароль"), text: $old)
                .textFieldStyle(.roundedBorder)
            fields
            Text(tr("Копии заголовка, снятые раньше, откроются старым паролем: после смены снимите новую, а старые удалите."))
                .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button(tr("Отмена")) { clear(); dismiss() }
            Button(tr("Сменить")) {
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
        SheetLayout(systemImage: "arrow.down.right.and.arrow.up.left", title: tr("Вернуть место на диск")) {
            Text(tr("Файлы, удалённые или возвращённые из сейфа, продолжают занимать место на диске: образ сам не уменьшается, хотя внутри это место идёт под новые данные. Сжатие отдаёт диску полностью пустые участки образа. На больших сейфах macOS может не найти таких участков — тогда вернётся мало или ничего, и OffLoadAI так и скажет."))
                .font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            SecureField(tr("Пароль сейфа"), text: $password)
                .textFieldStyle(.roundedBorder)
        } actions: {
            Button(tr("Отмена")) { password = ""; dismiss() }
            Button(tr("Сжать")) {
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
        SheetLayout(systemImage: "arrow.up.left.and.arrow.down.right", title: tr("Увеличить предел сейфа"),
                    subtitle: tr("Сейчас — \(Format.bytes(current))")) {
            Text(tr("Содержимое остаётся на месте, а места на диске образ занимает столько же, сколько занимал: предел лишь разрешает ему расти."))
                .font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if choices.isEmpty {
                Notice(.info, tr("Сейф уже может занять весь диск — увеличивать некуда."))
            } else {
                Picker(tr("Новый предел"), selection: Binding(get: { chosen }, set: { limit = $0 })) {
                    ForEach(choices, id: \.self) { value in
                        Text(value == app.destination?.totalBytes ? tr("весь диск (\(Format.bytes(value)))") : Format.bytes(value))
                            .tag(Int64?.some(value))
                    }
                }
                .fixedSize()
                if needed > 0, let chosen, chosen < target {
                    Text(tr("Выбранное для сейфа (\(Format.bytes(needed))) при таком пределе поместится не целиком."))
                        .font(.caption).foregroundStyle(Theme.warn)
                }
                if safe.isOpen {
                    HStack {
                        Text(tr("Сейф открыт — увеличить можно только закрытый."))
                            .font(.callout).foregroundStyle(Theme.muted)
                        Spacer()
                        Button(tr("Закрыть сейф")) { safe.close(app: app) }
                    }
                } else {
                    SecureField(tr("Пароль сейфа"), text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                Text(tr("На время увеличения сейф ненадолго подключится без открытия: файлы не видны ни Finder, ни программам."))
                    .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button(tr("Отмена")) { password = ""; dismiss() }
            Button(tr("Увеличить")) {
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
        SheetLayout(systemImage: "arrow.counterclockwise", tone: .caution, title: tr("Восстановить заголовок")) {
            Text(tr("Нужно, если сейф перестал открываться верным паролем (испортился заголовок). Сейф откроется паролем, который действовал, когда снималась копия. Если пароль к копии не подойдёт, прежний заголовок вернётся как был."))
                .font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Image(systemName: "doc").foregroundStyle(Theme.muted)
                Text(file?.lastPathComponent ?? tr("Копия не выбрана")).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(file == nil ? .secondary : .primary)
                Spacer()
                Button(tr("Выбрать…")) { choose() }
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            SecureField(tr("Пароль этой копии"), text: $password)
                .textFieldStyle(.roundedBorder)
        } actions: {
            Button(tr("Отмена")) { password = ""; dismiss() }
            Button(tr("Восстановить")) {
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
        panel.message = tr("Файл копии заголовка (.offload-header)")
        if panel.runModal() == .OK { file = panel.url }
    }
}
