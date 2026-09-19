import OffloadCore
import SwiftUI

struct BackupView: View {
    @Environment(AppModel.self) private var app
    @State private var password = ""
    @State private var confirmation = ""

    var body: some View {
        let model = app.backup
        @Bindable var bindable = model
        Form {
            Section {
                if model.sources.isEmpty {
                    Text("Добавьте папки с проектами и документами.").foregroundStyle(.secondary)
                }
                ForEach(model.sources, id: \.self) { url in
                    HStack {
                        Image(systemName: "folder")
                        Text(relativeToHome(url.path, home: app.rules.home)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { model.sources.removeAll { $0 == url } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isRunning)
                    }
                }
                Button { model.addSources() } label: { Label("Добавить папки…", systemImage: "plus") }
                    .disabled(model.isRunning)
            } header: {
                Text("Что бэкапить")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Не копировать папки и файлы с именами")
                    TextField("node_modules, .venv, dist", text: $bindable.excludedText, axis: .vertical)
                        .labelsHidden()
                        .lineLimit(2...5)
                }
                Text("Эти папки восстанавливаются одной командой (npm install, pip install, сборка). Файлы с ключами и токенами — .env, .envrc, *.pem, *.key, *.p8, id_ed25519 — и папки .ssh, .gnupg, .aws целиком в открытый бэкап не попадают никогда: для них шифрованный контейнер ниже.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Исключения")
            }

            Section {
                if let volume = app.destination {
                    LabeledContent("Куда") {
                        HStack {
                            Text(model.destination(on: volume).path).lineLimit(1).truncationMode(.head)
                            Button("Выбрать…") { model.chooseDestination(on: volume) }.disabled(model.isRunning)
                        }
                    }
                    if model.isRunning {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(model.currentItem).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.bytes(model.copiedBytes)).monospacedDigit()
                            Button("Остановить") { model.cancel() }
                        }
                    } else {
                        Button { model.run(on: volume, app: app) } label: {
                            Label("Обновить бэкап", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(model.sources.isEmpty)
                    }
                    if let report = model.report {
                        Notice(report.problems.isEmpty ? .success : .warning,
                               "Скопировано \(report.copied) (\(Format.bytes(report.bytesCopied))), без изменений \(report.unchanged). Секретов пропущено: \(report.secretsSkipped.count). Проблем: \(report.problems.count).")
                        if !report.problems.isEmpty {
                            DisclosureGroup("Проблемы") {
                                ForEach(report.problems.prefix(100), id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                            }
                        }
                    }
                    if let error = model.error { Notice(.error, error) }
                } else {
                    Notice(.warning, "Подключите внешний диск и выберите его внизу боковой панели.")
                }
            } header: {
                Text("Открытая часть")
            }

            Section {
                vaultSection
            } header: {
                Text("Шифрованный контейнер для ключей и токенов")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Бэкап")
        .task(id: app.destinationID) {
            if let volume = app.destination { model.refreshVault(on: volume) }
        }
    }

    @ViewBuilder
    private var vaultSection: some View {
        let model = app.backup
        if let volume = app.destination {
            Text("Сюда складываются ~/.ssh, учётка GitHub CLI, дотфайлы с токенами и .env/.key/.pem из папок бэкапа. Шифрование AES-256. Пароль Offload не хранит: если его забыть, данные не восстановить.")
                .font(.caption).foregroundStyle(.secondary)
            if let state = model.vault, state.volumeID == volume.id {
                if let mount = state.mount {
                    Label("Контейнер открыт: \(mount.path)", systemImage: "lock.open.fill").foregroundStyle(.orange)
                    Text("Пока контейнер открыт, файлы внутри не защищены. Закройте его после работы.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button { model.fillVault(on: volume, app: app) } label: { Label("Сложить секреты", systemImage: "tray.and.arrow.down") }
                            .disabled(!state.isEncrypted)
                            .help(state.isEncrypted ? "Скопировать ключи и токены в контейнер" : "Этот образ не зашифрован — складывать в него ключи нельзя")
                        Button { model.closeVault(on: volume) } label: { Label("Закрыть контейнер", systemImage: "lock.fill") }
                    }
                    .disabled(model.vaultBusy)
                } else if state.exists {
                    LabeledContent("Контейнер") {
                        HStack(spacing: 8) {
                            Text(state.imageURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Label(state.isEncrypted ? "зашифрован" : "НЕ зашифрован",
                                  systemImage: state.isEncrypted ? "lock.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(state.isEncrypted ? Color.green : Color.red)
                        }
                    }
                    if state.isEncrypted {
                        SecureField("Пароль", text: $password)
                        Button("Открыть") {
                            model.openVault(on: volume, password: password)
                            password = ""
                        }
                        .disabled(password.isEmpty || model.vaultBusy)
                    } else {
                        Notice(.error, "«\(state.imageURL.lastPathComponent)» — обычный образ без шифрования: пароль к нему подойдёт любой. Offload в него ничего не положит. Уберите его с диска или переименуйте, чтобы создать зашифрованный контейнер.")
                    }
                } else {
                    SecureField("Пароль (не короче \(SecretsVault.minimumPasswordLength) символов)", text: $password)
                    SecureField("Повторите пароль", text: $confirmation)
                    if !confirmation.isEmpty, confirmation != password {
                        Text("Пароли не совпадают").font(.caption).foregroundStyle(.red)
                    }
                    Button("Создать контейнер") {
                        model.createVault(on: volume, password: password)
                        password = ""
                        confirmation = ""
                    }
                    .disabled(password.count < SecretsVault.minimumPasswordLength || password != confirmation || model.vaultBusy)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Смотрю, есть ли контейнер на диске «\(volume.name)»…").foregroundStyle(.secondary)
                }
            }
            if model.vaultBusy { ProgressView().controlSize(.small) }
            if let message = model.vaultMessage { Notice(message) }
            if let report = model.vaultReport, let key = report.unprotectedKeys.first {
                Notice(.warning, "Ключи без парольной фразы: \(report.unprotectedKeys.joined(separator: ", ")). Если такой ключ утечёт с Mac, им воспользуются сразу. Задайте пароль командой: ssh-keygen -p -f ~/.ssh/\(key)")
            }
        } else {
            Notice(.warning, "Подключите внешний диск и выберите его внизу боковой панели.")
        }
    }
}
