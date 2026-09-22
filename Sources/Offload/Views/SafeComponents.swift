import OffloadCore
import SwiftUI

/// Шкала стойкости пароля с советами, что именно его ослабляет.
struct PasswordStrengthView: View {
    let password: String

    var body: some View {
        let strength = PasswordStrength.evaluate(password)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Gauge(value: min(1, strength.bits / 128)) { EmptyView() }
                    .gaugeStyle(.linearCapacity)
                    .tint(color(strength.level))
                    .frame(maxWidth: 220)
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
            SecureField("Ещё раз", text: $confirmation)
            PasswordStrengthView(password: password)
            if !confirmation.isEmpty, confirmation != password {
                Text("Пароли не совпадают.").font(.caption).foregroundStyle(.red)
            }
        }
    }
}

/// Открыть сейф прямо там, где он понадобился: в окне переноса, в бэкапе, в панели.
/// Пароль стирается из поля сразу после попытки — удачной или нет.
struct SafeUnlockRow: View {
    @Environment(AppModel.self) private var app
    @State private var password = ""
    var prompt = "Пароль сейфа"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
            SecureField(prompt, text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(open)
            if app.safe.activity != nil {
                ProgressView().controlSize(.small)
            } else {
                Button("Открыть", action: open).disabled(password.isEmpty)
            }
        }
    }

    private func open() {
        guard !password.isEmpty else { return }
        app.safe.open(password: password, app: app)
        password = ""
    }
}

/// Куда пойдут данные — одной строкой, с замком. Главное, что человек должен видеть
/// перед любым переносом: зашифровано это будет или нет.
struct TargetSummary: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let target = app.target {
            if target.isEncryptedImage {
                Label {
                    Text("В сейф «\(target.name)» · зашифровано · свободно \(Format.bytes(target.availableBytes))")
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(.green)
                }
            } else {
                Label {
                    Text("На диск «\(target.name)» открыто · не зашифровано · свободно \(Format.bytes(target.availableBytes))")
                } icon: {
                    Image(systemName: "lock.open.trianglebadge.exclamationmark").foregroundStyle(.orange)
                }
            }
        } else if let problem = app.targetProblem {
            Label(problem, systemImage: "lock.slash").foregroundStyle(.secondary)
        }
    }
}

/// Нижняя панель боковой колонки: диск, сейф и куда класть. Видна из любого раздела —
/// сейф и его замок должны быть перед глазами всегда, а не прятаться в одном из разделов.
struct SafeStatusPanel: View {
    @Environment(AppModel.self) private var app
    @State private var unlocking = false

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Внешний диск").font(.caption).foregroundStyle(.secondary)
                if app.volumes.isEmpty {
                    Label("Не подключён", systemImage: "externaldrive.badge.xmark").font(.callout).foregroundStyle(.secondary)
                } else {
                    Picker("Внешний диск", selection: $app.destinationID) {
                        ForEach(app.volumes) { volume in
                            Text(volume.name).tag(Optional(volume.id))
                        }
                    }
                    .labelsHidden()
                    if let volume = app.destination {
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var safeRow: some View {
        let safe = app.safe
        HStack(spacing: 8) {
            Image(systemName: safe.isOpen ? "lock.open.fill" : "lock.fill")
                .foregroundStyle(safe.isOpen ? .orange : (safe.exists ? .green : .secondary))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Сейф").font(.callout.weight(.medium))
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
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Открыть сейф «\(safe.state?.displayName ?? "")»").font(.headline)
                            SafeUnlockRow().frame(width: 300)
                            if let message = safe.message, message.kind == .error { Notice(message) }
                        }
                        .padding(14)
                        .onChange(of: safe.isOpen) { if safe.isOpen { unlocking = false } }
                    }
            } else {
                Button("Создать") { app.section = .safe }.controlSize(.small)
            }
        }
    }

    private var status: String {
        let safe = app.safe
        guard let state = safe.state else { return "смотрю…" }
        if !state.exists { return "не создан" }
        if !state.isEncrypted { return "образ не зашифрован" }
        if let volume = app.safeVolume { return "открыт · \(Format.bytes(volume.availableBytes))" }
        return "закрыт · \(state.displayName)"
    }
}
