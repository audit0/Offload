import OffloadCore
import SwiftUI

struct BackupView: View {
    @Environment(AppModel.self) private var app
    @State private var editingExclusions = false

    var body: some View {
        PageScroll {
            CardSection(title: "Что бэкапить", number: 1) {
                sourcesSection
            }
            CardSection(title: "Исключения",
                        footer: "Эти папки восстанавливаются одной командой (npm install, pip install, сборка). Файлы с ключами и токенами — .env, .envrc, *.pem, *.key, *.p8, id_ed25519 — и папки .ssh, .gnupg, .aws в бэкап проектов не попадают никогда: для них раздел «Ключи и токены» ниже, и лежат они только в сейфе.") {
                exclusionsSection
            }
            CardSection(title: "Куда", number: 2) {
                destinationSection
            }
            CardSection(title: "Ключи и токены — только в сейф", number: 3) {
                keysSection
            }
        }
        .navigationTitle("Бэкап")
    }

    @ViewBuilder
    private var sourcesSection: some View {
        let model = app.backup
        if model.sources.isEmpty {
            Text("Добавьте папки с проектами и документами.")
                .foregroundStyle(.secondary)
                .rowPadding()
            RowDivider()
        }
        ForEach(model.sources, id: \.self) { url in
            HStack(spacing: 10) {
                IconTile(systemImage: "folder.fill", size: 26)
                Text(relativeToHome(url.path, home: app.rules.home)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(role: .destructive) { model.sources.removeAll { $0 == url } } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Убрать из бэкапа")
                .disabled(model.isRunning)
            }
            .rowPadding()
            RowDivider()
        }
        Button { model.addSources() } label: { Label("Добавить папки…", systemImage: "plus") }
            .buttonStyle(.borderless)
            .disabled(model.isRunning)
            .rowPadding()
    }

    @ViewBuilder
    private var exclusionsSection: some View {
        let model = app.backup
        @Bindable var bindable = model
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Не копировать папки и файлы с именами")
                Spacer()
                Button(editingExclusions ? "Готово" : "Изменить") { editingExclusions.toggle() }
                    .controlSize(.small)
            }
            if editingExclusions {
                TextField("node_modules, .venv, dist", text: $bindable.excludedText, axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
            } else if model.excludedNames.isEmpty {
                Text("Ничего не пропускается.").font(.callout).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(model.excludedNames.sorted(), id: \.self) { Chip(text: $0) }
                }
            }
        }
        .padding(Theme.cardPadding)
    }

    @ViewBuilder
    private var destinationSection: some View {
        let model = app.backup
        VStack(alignment: .leading, spacing: 12) {
            TargetSummary()
            if let volume = app.target {
                InfoRow(title: "Папка") {
                    HStack {
                        Text(model.destination(on: volume).path).lineLimit(1).truncationMode(.head).textSelection(.enabled)
                        Button("Выбрать…") { model.chooseDestination(on: volume) }.disabled(model.isRunning)
                    }
                }
                .font(.callout)
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
                    .prominentButton()
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
                SafeUnlockRow().frame(maxWidth: 440)
            }
        }
        .padding(Theme.cardPadding)
    }

    @ViewBuilder
    private var keysSection: some View {
        let model = app.backup
        VStack(alignment: .leading, spacing: 12) {
            Text("~/.ssh, учётка GitHub CLI, дотфайлы с токенами (.zshrc, .npmrc, .netrc…), базы KeePass и .env/.key/.pem из папок бэкапа. Складываются с сохранением путей; инструкция по восстановлению лежит в сейфе рядом.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if app.safeVolume != nil {
                HStack {
                    Button { model.putKeys(app: app) } label: { Label("Сложить в сейф", systemImage: "key.horizontal") }
                        .disabled(model.keysBusy)
                    if model.keysBusy { ProgressView().controlSize(.small) }
                }
            } else if app.safe.state?.isEncrypted == true {
                SafeUnlockRow().frame(maxWidth: 440)
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
        .padding(Theme.cardPadding)
    }
}
