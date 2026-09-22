import OffloadCore
import SwiftUI

struct BackupView: View {
    @Environment(AppModel.self) private var app

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
                Text("1. Что бэкапить")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Не копировать папки и файлы с именами")
                    TextField("node_modules, .venv, dist", text: $bindable.excludedText, axis: .vertical)
                        .labelsHidden()
                        .lineLimit(2...5)
                }
                Text("Эти папки восстанавливаются одной командой (npm install, pip install, сборка). Файлы с ключами и токенами — .env, .envrc, *.pem, *.key, *.p8, id_ed25519 — и папки .ssh, .gnupg, .aws в бэкап проектов не попадают никогда: для них раздел «Ключи и токены» ниже, и лежат они только в сейфе.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Исключения")
            }

            Section {
                destinationSection
            } header: {
                Text("2. Куда")
            }

            Section {
                keysSection
            } header: {
                Text("3. Ключи и токены — только в сейф")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Бэкап")
    }

    @ViewBuilder
    private var destinationSection: some View {
        let model = app.backup
        TargetSummary()
        if let volume = app.target {
            LabeledContent("Папка") {
                HStack {
                    Text(model.destination(on: volume).path).lineLimit(1).truncationMode(.head).textSelection(.enabled)
                    Button("Выбрать…") { model.chooseDestination(on: volume) }.disabled(model.isRunning)
                }
            }
            if !volume.isEncryptedImage {
                Notice(.warning, "Бэкап ляжет на диск открыто: кто получит диск, прочтёт ваши проекты. Чтобы зашифровать, выберите внизу боковой панели «В сейф».")
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
        } else if app.destination != nil, app.storeMode == .safe, app.safe.state?.isEncrypted == true {
            SafeUnlockRow()
        }
    }

    @ViewBuilder
    private var keysSection: some View {
        let model = app.backup
        Text("~/.ssh, учётка GitHub CLI, дотфайлы с токенами (.zshrc, .npmrc, .netrc…), базы KeePass и .env/.key/.pem из папок бэкапа. Складываются с сохранением путей; инструкция по восстановлению лежит в сейфе рядом.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if app.safeVolume != nil {
            HStack {
                Button { model.putKeys(app: app) } label: { Label("Сложить в сейф", systemImage: "key.horizontal") }
                    .disabled(model.keysBusy)
                if model.keysBusy { ProgressView().controlSize(.small) }
            }
        } else if app.safe.state?.isEncrypted == true {
            SafeUnlockRow()
        } else if app.destination != nil {
            Button("Создать сейф…") { app.section = .safe }
        } else {
            Text("Подключите внешний диск.").foregroundStyle(.secondary)
        }
        if let message = model.keysMessage { Notice(message) }
        if let report = model.keysReport, !report.unprotectedKeys.isEmpty {
            Notice(.warning, "SSH-ключи без парольной фразы: \(report.unprotectedKeys.joined(separator: ", ")). Любой, кто получит сам файл ключа, сразу сможет им пользоваться. Добавьте фразу: ssh-keygen -p -f ~/.ssh/<ключ>")
        }
    }
}
