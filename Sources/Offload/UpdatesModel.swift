import AppKit
import Foundation
import Observation
import OffloadCore

/// Сообщения о новых версиях. Выключены, пока человек их не включит: сам OffLoadAI в сеть не ходит.
/// Включённые — раз в сутки спрашивают у GitHub номер последнего выпуска (см. `UpdateCheck`).
/// Обновляется человек сам — той же командой установки, что сверяет архив.
@MainActor
@Observable
final class UpdatesModel {
    /// Та же команда, что в README: скачивает выпуск, сверяет его и ставит на место этой версии.
    static let installCommand = "curl -fsSL https://raw.githubusercontent.com/audit0/Offload/main/scripts/install.sh | zsh"

    /// Номер этой версии из Info.plist. У запуска без пакета (`swift run`) его нет — сообщать не о чем.
    static let currentVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    private static let enabledKey = "updates.enabled"
    private static let lastCheckKey = "updates.lastCheck"
    private static let postponedKey = "updates.postponed"

    /// nil — человека ещё не спрашивали: тогда на «Обзоре» висит вопрос.
    private(set) var enabled: Bool?
    /// Вышла версия новее этой, и человек не отложил именно её.
    private(set) var available: UpdateCheck.Release?
    private(set) var isChecking = false
    /// Окно «Вышла новая версия».
    var isPresented = false
    /// Итог проверки из меню: установлена последняя версия или почему проверить не вышло.
    var checkResult: String?

    init() {
        // Снимки для README: вопроса на «Обзоре» нет, в сеть программа не ходит.
        enabled = Demo.isOn ? false : UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { checkIfDue() } else { available = nil }
    }

    /// При запуске и когда окно снова становится активным: раз в сутки и только с разрешения.
    func checkIfDue() {
        guard enabled == true, !Demo.isOn, !isChecking,
              UpdateCheck.isDue(lastCheck: UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date) else { return }
        Task { await check(manual: false) }
    }

    /// «Проверить обновления…» из меню: один вопрос к GitHub по нажатию — само нажатие и есть согласие.
    func checkNow() {
        guard !Demo.isOn, !isChecking else { return }
        Task { await check(manual: true) }
    }

    /// Не напоминать об этой версии; о следующей — напомнить.
    func postpone() {
        if let available { UserDefaults.standard.set(available.version, forKey: Self.postponedKey) }
        available = nil
        isPresented = false
    }

    private func check(manual: Bool) async {
        isChecking = true
        defer { isChecking = false }
        // Время попытки запоминается и при неудаче: без сети программа не стучится в GitHub при каждом возврате к окну.
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        do {
            let release = try await UpdateCheck.fetch()
            guard let current = Self.currentVersion else {
                if manual { checkResult = "У сборки для разработки нет номера версии. Последний выпуск — \(release.version)." }
                return
            }
            guard UpdateCheck.isNewer(release.version, than: current) else {
                available = nil
                if manual { checkResult = "Установлена последняя версия — \(current)." }
                return
            }
            if manual || UserDefaults.standard.string(forKey: Self.postponedKey) != release.version { available = release }
            if manual { isPresented = true }
        } catch {
            if manual { checkResult = "Не удалось проверить: \(error.localizedDescription)" }
        }
    }

    func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.installCommand, forType: .string)
    }
}
