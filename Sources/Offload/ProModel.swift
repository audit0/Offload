import AppKit
import Foundation
import Observation
import OffloadCore

/// Offload Pro на этом Mac: ключ, пробные две недели, ранние пользователи.
///
/// Ключ проверяется подписью, без сети. Всё хранится в настройках программы; сбросить пробу,
/// удалив их, можно — Pro держится на честности тех, кому Offload полезен, а не на защите.
@MainActor
@Observable
final class ProModel {
    /// Где купить: бот в Telegram — оплата Stars, криптовалютой или по СБП, ключ приходит сообщением.
    static let purchaseURL = URL(string: "https://t.me/OffLoadmg_bot?start=pro")!

    private(set) var status: ProStatus = .free
    private(set) var license: License?
    /// Ключ не подошёл — почему, одной фразой.
    var keyProblem: String?
    /// Окно «Offload Pro» и то, ради чего его открыли (nil — просто из меню).
    var isPresented = false
    private(set) var reason: ProFeature?

    private static let licenseKey = "pro.license"
    private static let trialKey = "pro.trialStarted"
    private static let earlyKey = "pro.early"

    /// День выхода этой версии: ключ открывает версии, вышедшие до конца его обновлений.
    /// Пишется в Info.plist при сборке; у сборки из исходников его нет — тогда ключ подходит любой.
    static let releaseDate: Date? = (Bundle.main.infoDictionary?["OffloadReleaseDate"] as? String).flatMap(LicenseCodec.day)

    init() {
        guard !Demo.isOn else {
            // Снимки для README показывают всё, что умеет программа. OFFLOAD_DEMO_PRO=free или trial —
            // как это выглядит без ключа.
            switch ProcessInfo.processInfo.environment["OFFLOAD_DEMO_PRO"] {
            case "free": status = .free
            case "trial": status = .trial(daysLeft: 9)
            default: status = .early
            }
            return
        }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.earlyKey) == nil {
            // Первый запуск версии с Pro. Кто пользовался Offload раньше, получает всё, что было,
            // навсегда: забирать то, чем человек уже пользовался бесплатно, нечестно.
            let early = Self.usedBefore()
            defaults.set(early, forKey: Self.earlyKey)
            if !early { defaults.set(Date(), forKey: Self.trialKey) }
        }
        if let text = defaults.string(forKey: Self.licenseKey) {
            license = try? LicenseCodec.verify(text)
        }
        refresh()
    }

    func allows(_ feature: ProFeature) -> Bool { status.isPro }

    /// Открыть окно «Offload Pro» — из-за конкретной возможности или просто так.
    func offer(_ feature: ProFeature? = nil) {
        reason = feature
        keyProblem = nil
        isPresented = true
    }

    func refresh() {
        guard !Demo.isOn else { return }
        let defaults = UserDefaults.standard
        status = ProStatus.resolve(license: license, release: Self.releaseDate,
                                   early: defaults.bool(forKey: Self.earlyKey),
                                   trialStarted: defaults.object(forKey: Self.trialKey) as? Date, now: Date())
    }

    /// Проверить и запомнить ключ. Ответ — подошёл ли.
    @discardableResult
    func activate(_ text: String) -> Bool {
        do {
            let checked = try LicenseCodec.verify(text)
            guard checked.covers(release: Self.releaseDate) else {
                keyProblem = "Ключ верный, но его обновления закончились \(Self.day(checked.updatesUntil)), а эта версия вышла позже. Продлите ключ — или поставьте версию, вышедшую до этой даты: с ней ключ работает всегда."
                return false
            }
            license = checked
            keyProblem = nil
            if !Demo.isOn { UserDefaults.standard.set(text.filter { !$0.isWhitespace }, forKey: Self.licenseKey) }
            refresh()
            return true
        } catch {
            keyProblem = error.localizedDescription
            return false
        }
    }

    /// Убрать ключ с этого Mac — например, перед продажей Mac. Ключ остаётся у владельца.
    func removeLicense() {
        license = nil
        if !Demo.isOn { UserDefaults.standard.removeObject(forKey: Self.licenseKey) }
        refresh()
    }

    /// Одной строкой — для боковой колонки.
    var summary: String {
        switch status {
        case .licensed: return "Offload Pro"
        case .early: return "Pro — ранний пользователь"
        case .trial(let days): return "Pro: пробный, \(days) \(pluralRu(days, "день", "дня", "дней"))"
        case .expired: return "Pro: продлите ключ"
        case .free: return "Бесплатная версия"
        }
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "ru_RU")))
    }

    /// Остались ли следы прежних версий: база решений, журнал переносов или настройки.
    private static func usedBefore() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: DecisionStore.defaultURL.path) || fm.fileExists(atPath: Journal.localURL.path) { return true }
        let defaults = UserDefaults.standard
        return ["storeMode", "backup.sources", "backup.destination"].contains { defaults.object(forKey: $0) != nil }
    }
}
