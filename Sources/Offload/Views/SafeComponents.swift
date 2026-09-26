import OffloadCore
import SwiftUI

extension SafeModel {
    /// Состояние сейфа одной строкой — для боковой панели и «Обзора».
    var summary: (title: String, systemImage: String, tone: Tone) {
        guard let state else { return ("Смотрю, есть ли сейф…", "lock", .neutral) }
        if !state.exists { return ("Сейфа нет", "lock.slash", .neutral) }
        if !state.isEncrypted { return ("Образ не зашифрован", "exclamationmark.octagon.fill", .danger) }
        return isOpen ? ("Сейф открыт", "lock.open.fill", .caution) : ("Сейф закрыт", "lock.fill", .good)
    }
}

/// Шкала стойкости пароля с советами, что именно его ослабляет.
struct PasswordStrengthView: View {
    let password: String

    var body: some View {
        let strength = PasswordStrength.evaluate(password)
        // Четыре деления — четыре уровня: слабый, так себе, хороший, надёжный.
        let filled = password.isEmpty ? 0 : strength.level.rawValue + 1
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    ForEach(0..<4) { index in
                        Capsule()
                            .fill(index < filled ? color(strength.level) : Theme.track)
                            .frame(width: 34, height: 5)
                    }
                }
                Text(password.isEmpty ? "Введите пароль" : "\(strength.title) · ≈\(Int(strength.bits)) бит")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(password.isEmpty ? .secondary : color(strength.level))
                    .monospacedDigit()
            }
            ForEach(strength.advice, id: \.self) { tip in
                Text(tip).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func color(_ level: PasswordStrength.Level) -> Color {
        switch level {
        case .weak: return .red
        case .fair: return .orange
        case .good: return .green
        case .strong: return .green
        }
    }
}

/// Новый пароль дважды и шкала. Годится для создания сейфа и смены пароля.
struct NewPasswordFields: View {
    @Binding var password: String
    @Binding var confirmation: String

    var isAcceptable: Bool {
        PasswordStrength.evaluate(password).isAcceptable && password == confirmation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Новый пароль", text: $password)
                .textFieldStyle(.roundedBorder)
            SecureField("Ещё раз", text: $confirmation)
                .textFieldStyle(.roundedBorder)
            PasswordStrengthView(password: password)
            if !confirmation.isEmpty, confirmation != password {
                Label("Пароли не совпадают.", systemImage: "xmark.circle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }
}

/// Открыть сейф прямо там, где он понадобился: в окне переноса, в бэкапе, в панели.
/// Пароль стирается из поля сразу после попытки — удачной или нет, а почему не открылся,
/// написано тут же, под полем.
struct SafeUnlockRow: View {
    @Environment(AppModel.self) private var app
    @State private var password = ""
    var prompt = "Пароль сейфа"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                SecureField(prompt, text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(open)
                if app.safe.activity != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Открыть", action: open)
                        .buttonStyle(.borderedProminent)
                        .disabled(password.isEmpty)
                }
            }
            if let error = app.safe.unlockError {
                Label(error, systemImage: "xmark.circle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: password) { if !password.isEmpty { app.safe.unlockError = nil } }
    }

    private func open() {
        guard !password.isEmpty else { return }
        app.safe.open(password: password, app: app)
        password = ""
    }
}

/// Куда пойдут данные — с замком и цветом. Главное, что человек должен видеть
/// перед любым переносом: зашифровано это будет или нет.
struct TargetSummary: View {
    @Environment(AppModel.self) private var app
    /// Каким цветом показать, что класть некуда: в окне переноса это то, что мешает перенести.
    var problemTone: Tone = .neutral

    var body: some View {
        if let target = app.target {
            if target.isEncryptedImage {
                banner(systemImage: "lock.fill", tone: .good,
                       title: "В сейф «\(target.name)»",
                       detail: "зашифровано · свободно \(Format.bytes(target.availableBytes))")
            } else {
                banner(systemImage: "lock.open.trianglebadge.exclamationmark", tone: .caution,
                       title: "На диск «\(target.name)» открыто",
                       detail: "не зашифровано · свободно \(Format.bytes(target.availableBytes))")
            }
        } else if let problem = app.targetProblem {
            banner(systemImage: "lock.slash", tone: problemTone, title: problem, detail: nil)
        }
    }

    private func banner(systemImage: String, tone: Tone, title: String, detail: String?) -> some View {
        HStack(spacing: 10) {
            IconTile(systemImage: systemImage, tone: tone, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tone.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Нижняя панель боковой колонки: диск, сейф и куда класть. Видна из любого раздела —
/// сейф и его замок должны быть перед глазами всегда, а не прятаться в одном из разделов.
struct SafeStatusPanel: View {
    @Environment(AppModel.self) private var app
    @State private var unlocking = false

    var body: some View {
        @Bindable var app = app
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Внешний диск").font(.caption).foregroundStyle(.secondary)
                if app.volumes.isEmpty {
                    Label("Не подключён", systemImage: "externaldrive.badge.xmark").font(.callout).foregroundStyle(.secondary)
                } else {
                    // Выбор нужен, только когда дисков несколько; один диск — просто его имя.
                    if app.volumes.count > 1 || app.destination == nil {
                        Picker("Внешний диск", selection: $app.destinationID) {
                            ForEach(app.volumes) { volume in
                                Text(volume.name).tag(Optional(volume.id))
                            }
                        }
                        .labelsHidden()
                    } else if let volume = app.destination {
                        Label(volume.name, systemImage: "externaldrive.fill")
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                    }
                    if let volume = app.destination {
                        if volume.totalBytes > 0 {
                            CapacityBar(fraction: Double(volume.totalBytes - volume.availableBytes) / Double(volume.totalBytes), height: 4)
                        }
                        Text("\(volume.fsDisplayName) · свободно \(Format.bytes(volume.availableBytes))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if app.destination != nil {
                Divider()
                safeRow
                Picker("Куда класть", selection: $app.storeMode) {
                    ForEach(StoreMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Куда пойдут перенос, бэкап и тома Docker")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: shape)
    }

    @ViewBuilder
    private var safeRow: some View {
        let safe = app.safe
        let summary = safe.summary
        HStack(spacing: 8) {
            IconTile(systemImage: summary.systemImage, tone: summary.tone, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if safe.activity != nil {
                ProgressView().controlSize(.small)
            } else if safe.isOpen {
                Button("Закрыть") { safe.close(app: app) }
                    .controlSize(.small)
                    .help("Закрыть сейф (⌘⇧L)")
            } else if safe.state?.isEncrypted == true {
                Button("Открыть") { unlocking = true }
                    .controlSize(.small)
                    .popover(isPresented: $unlocking, arrowEdge: .trailing) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                IconTile(systemImage: "lock.fill", tone: .good, size: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Открыть сейф").font(.headline)
                                    Text("«\(safe.state?.displayName ?? "")»").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            SafeUnlockRow().frame(width: 300)
                        }
                        .padding(16)
                        .onChange(of: safe.isOpen) { if safe.isOpen { unlocking = false } }
                    }
            } else {
                Button("Создать") { app.section = .safe }.controlSize(.small)
            }
        }
    }

    /// Вторая строка под состоянием: где сейф и сколько в нём места.
    private var status: String {
        let safe = app.safe
        guard let state = safe.state, state.exists else { return "на «\(app.destination?.name ?? "")»" }
        if !state.isEncrypted { return "класть в него нельзя" }
        if let volume = app.safeVolume { return "свободно \(Format.bytes(volume.availableBytes))" }
        return "«\(state.displayName)»"
    }
}
