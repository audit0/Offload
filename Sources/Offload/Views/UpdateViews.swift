import AppKit
import OffloadCore
import SwiftUI

/// Вопрос на «Обзоре», пока человек не решил, сообщать ли о новых версиях.
struct UpdateQuestionCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                IconTile(systemImage: "arrow.down.circle", tone: .brand, size: 36)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Сообщать о новых версиях?").font(.headline)
                    Text("Раз в сутки OffLoadAI спросит у GitHub номер последней версии и скажет, если вышла новая: в новых версиях бывают исправления безопасности. В запросе нет ничего о компьютере и файлах — GitHub видит только адрес сети, как при открытии любой страницы. Обновление ставите вы сами. Передумать можно в меню OffLoadAI.")
                        .font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Сообщать") { app.updates.setEnabled(true) }
                            .prominentButton()
                        Button("Не надо") { app.updates.setEnabled(false) }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
}

/// Строка в боковой колонке: вышла новая версия.
struct UpdateSidebarRow: View {
    @Environment(AppModel.self) private var app
    let release: UpdateCheck.Release
    @State private var hovering = false

    var body: some View {
        Button { app.updates.isPresented = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Theme.ink)
                    .frame(width: 20)
                Text("Вышла версия \(release.version)").font(.callout).fontWeight(.medium).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background(hovering ? Color.white.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Что нового и как обновиться")
    }
}

/// Вышла новая версия: что нового — на странице выпуска, обновиться — командой в Терминале.
struct UpdateSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        let updates = app.updates
        SheetLayout(systemImage: "arrow.down.circle", title: "Вышла версия \(updates.available?.version ?? "")",
                    subtitle: UpdatesModel.currentVersion.map { "У вас — \($0)" }, width: 540) {
            Text("Чтобы обновиться, вставьте эту команду в Терминал. Она скачает новую версию, сверит её и поставит на место этой. Если идёт копирование, OffLoadAI сначала спросит, прервать ли его. Настройки, ключ Pro, журнал и сейф останутся как были.")
                .font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                Text(UpdatesModel.installCommand)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copied ? "Скопировано" : "Скопировать") {
                    updates.copyCommand()
                    copied = true
                }
            }
            .padding(12)
            .background(Theme.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } actions: {
            if let page = updates.available?.page {
                Button("Что нового") { NSWorkspace.shared.open(page) }
            }
            Button("Не напоминать об этой") {
                updates.postpone()
                dismiss()
            }
            Button("Готово") { dismiss() }
                .prominentButton()
                .keyboardShortcut(.defaultAction)
        }
    }
}
