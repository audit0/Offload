import Foundation
import OffloadCore

// Сообщение о новой версии: разбор ответа GitHub, сравнение номеров, раз в сутки.
func checksUpdate() {
    section("Обновления: ответ GitHub и номера версий") {
        func release(_ fields: String) -> Data { Data("{\(fields),\"html_url\":\"https://evil.example/x\",\"body\":\"…\"}".utf8) }
        let parsed = try UpdateCheck.parse(release(#""tag_name":"v0.4.1","draft":false,"prerelease":false"#))
        check(parsed.version == "0.4.1", "номер выпуска читается без «v»")
        check(parsed.page.absoluteString == "https://github.com/audit0/Offload/releases/tag/v0.4.1",
              "страница выпуска строится из номера, адрес из ответа не открывается")
        check((try? UpdateCheck.parse(release(#""tag_name":"0.5.0""#)))?.version == "0.5.0", "номер и без «v»")
        expectError("черновик не считается") { _ = try UpdateCheck.parse(release(#""tag_name":"v9.0.0","draft":true"#)) }
        expectError("предварительный выпуск не считается") { _ = try UpdateCheck.parse(release(#""tag_name":"v9.0.0","prerelease":true"#)) }
        for tag in ["latest", "v1.2", "v1.2.3.4", "v1.2.3-beta", "v1.x.3", "v١.٢.٣", "v1234567.0.0"] {
            expectError("непонятный номер «\(tag)» не считается") { _ = try UpdateCheck.parse(release("\"tag_name\":\"\(tag)\"")) }
        }
        expectError("не JSON — ошибка") { _ = try UpdateCheck.parse(Data("<html>".utf8)) }

        check(UpdateCheck.isNewer("0.4.1", than: "0.4.0"), "0.4.1 новее 0.4.0")
        check(UpdateCheck.isNewer("0.10.0", than: "0.9.9"), "номера сравниваются числами, а не строками")
        check(UpdateCheck.isNewer("1.0.0", than: "0.99.99"), "1.0.0 новее 0.99.99")
        check(!UpdateCheck.isNewer("0.4.0", than: "0.4.0"), "та же версия — не новее")
        check(!UpdateCheck.isNewer("0.3.9", than: "0.4.0"), "старая версия — не новее")
        check(!UpdateCheck.isNewer("0.4.0", than: "0.4.0-ci"), "сборка для разработки той же версии — обновляться не нужно")
        check(UpdateCheck.isNewer("0.4.1", than: "0.4.0-ci"), "а следующая версия новее и её")
        check(!UpdateCheck.isNewer("9.9.9", than: "разработка"), "непонятный номер этой версии — молчим")

        let now = Date()
        check(UpdateCheck.isDue(lastCheck: nil, now: now), "ни разу не спрашивали — пора")
        check(!UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-3600), now: now), "час назад спрашивали — рано")
        check(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-25 * 3600), now: now), "больше суток назад — пора")
        check(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(3600), now: now), "часы перевели назад — проверка не застревает")
        check(UpdateCheck.endpoint.host == "api.github.com" && UpdateCheck.endpoint.scheme == "https",
              "спрашивается только GitHub, по https")
    }
}
