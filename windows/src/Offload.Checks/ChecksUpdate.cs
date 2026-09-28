using Offload.Core;
using static Offload.Checks.Harness;

namespace Offload.Checks;

/// <summary>Сообщение о новой версии: разбор ответа GitHub, сравнение номеров, раз в сутки — как на Mac.</summary>
static partial class All
{
    static void ChecksUpdate()
    {
        Section("Обновления: ответ GitHub и номера версий", () =>
        {
            static string Release(string fields) => "{" + fields + ",\"html_url\":\"https://evil.example/x\",\"body\":\"…\"}";
            var parsed = UpdateCheck.Parse(Release("\"tag_name\":\"v0.4.1\",\"draft\":false,\"prerelease\":false"));
            Check(parsed.Version == "0.4.1", "номер выпуска читается без «v»");
            Check(parsed.Page == "https://github.com/audit0/Offload/releases/tag/v0.4.1", "страница выпуска строится из номера, адрес из ответа не открывается");
            Check(UpdateCheck.Parse(Release("\"tag_name\":\"0.5.0\"")).Version == "0.5.0", "номер и без «v»");
            ExpectError("черновик не считается", () => UpdateCheck.Parse(Release("\"tag_name\":\"v9.0.0\",\"draft\":true")),
                        e => e is UpdateCheck.UpdateException);
            ExpectError("предварительный выпуск не считается", () => UpdateCheck.Parse(Release("\"tag_name\":\"v9.0.0\",\"prerelease\":true")),
                        e => e is UpdateCheck.UpdateException);
            foreach (var tag in new[] { "latest", "v1.2", "v1.2.3.4", "v1.2.3-beta", "v1.x.3", "v١.٢.٣", "v1234567.0.0" })
                ExpectError($"непонятный номер «{tag}» не считается", () => UpdateCheck.Parse(Release($"\"tag_name\":\"{tag}\"")),
                            e => e is UpdateCheck.UpdateException);
            ExpectError("номер не строкой — не считается", () => UpdateCheck.Parse(Release("\"tag_name\":123")), e => e is UpdateCheck.UpdateException);
            ExpectError("не JSON — ошибка", () => UpdateCheck.Parse("<html>"), e => e is UpdateCheck.UpdateException);

            Check(UpdateCheck.IsNewer("0.4.1", "0.4.0"), "0.4.1 новее 0.4.0");
            Check(UpdateCheck.IsNewer("0.10.0", "0.9.9"), "номера сравниваются числами, а не строками");
            Check(UpdateCheck.IsNewer("1.0.0", "0.99.99"), "1.0.0 новее 0.99.99");
            Check(!UpdateCheck.IsNewer("0.4.0", "0.4.0"), "та же версия — не новее");
            Check(!UpdateCheck.IsNewer("0.3.9", "0.4.0"), "старая версия — не новее");
            Check(!UpdateCheck.IsNewer("0.4.0", "0.4.0-ci"), "сборка для разработки той же версии — обновляться не нужно");
            Check(UpdateCheck.IsNewer("0.4.1", "0.4.0-ci"), "а следующая версия новее и её");
            Check(!UpdateCheck.IsNewer("9.9.9", "разработка"), "непонятный номер этой версии — молчим");

            var now = DateTime.UtcNow;
            Check(UpdateCheck.IsDue(null, now), "ни разу не спрашивали — пора");
            Check(!UpdateCheck.IsDue(now.AddHours(-1), now), "час назад спрашивали — рано");
            Check(UpdateCheck.IsDue(now.AddHours(-25), now), "больше суток назад — пора");
            Check(UpdateCheck.IsDue(now.AddHours(1), now), "часы перевели назад — проверка не застревает");
            Check(UpdateCheck.Endpoint is { Scheme: "https", Host: "api.github.com" }, "спрашивается только GitHub, по https");
        });
    }
}
