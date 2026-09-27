using System.Text;
using Offload.Core;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Security;
using static Offload.Checks.Harness;

namespace Offload.Checks;

/// <summary>OffLoadAI Pro: ключ проверяется подписью без сети, чужой и испорченный не проходят, ключ от версии
/// для Mac подходит и здесь, проба и ранние пользователи считаются так, как обещано в окне «OffLoadAI Pro».</summary>
static partial class All
{
    /// <summary>Выпущен кодом версии для Mac (CryptoKit) тестовой парой с открытым ключом ниже — не настоящим.</summary>
    const string MacPublicKey = "dVxMuSVsp83ErP3Gz-7ahJAX5bn5UU6ZGRvWfgsNQnY";
    const string MacKey = "OFFLOAD-eyJpZCI6Im1hYzAwMDAxIiwiaXNzdWVkIjoiMjAyNi0wOS0yNyIsIm5hbWUiOiLQkNC90L3QsCDCq9GC0LXRgdGCwrsgLyBRQSIsInVudGlsIjoiMjAyNy0wOS0yNyIsInYiOjF9.R_9aBf4eJuOhEDrVJjbDvCs6jCPPls39yDd6EOrs6CPUT4XZT_4pydMYIsS0reRmV7V45U8BfSUuRL6muntpDQ";

    static void ChecksLicense()
    {
        var signer = new Ed25519PrivateKeyParameters(new SecureRandom());
        var publicKey = LicenseCodec.ToBase64Url(signer.GeneratePublicKey().GetEncoded());
        var issued = LicenseCodec.Day("2026-09-27")!.Value;
        var until = LicenseCodec.Day("2027-09-27")!.Value;
        var license = new License("a1b2c3d4", "Анна «тест» / QA", issued, until);
        static bool Is(Exception e, LicenseErrorKind kind) => e is LicenseException l && l.Kind == kind;

        Section("Pro: ключ", () =>
        {
            var key = LicenseCodec.Issue(license, signer);
            Check(key.StartsWith("OFFLOAD-", StringComparison.Ordinal), "ключ начинается с OFFLOAD-");
            Check(() => LicenseCodec.Verify(key, publicKey) == license, "свой ключ проверяется и читается как выпущен");
            // Письма и мессенджеры переносят длинные строки и добавляют пробелы по краям.
            var wrapped = "  " + string.Join("\r\n", Enumerable.Range(0, (key.Length + 39) / 40).Select(i => key.Substring(i * 40, Math.Min(40, key.Length - i * 40)))) + "\n";
            Check(() => LicenseCodec.Verify(wrapped, publicKey) == license, "ключ с переносами строк и пробелами проходит");

            var stranger = new Ed25519PrivateKeyParameters(new SecureRandom());
            var forged = LicenseCodec.Issue(license, stranger);
            ExpectError("ключ, подписанный чужим ключом, не проходит", () => LicenseCodec.Verify(forged, publicKey), e => Is(e, LicenseErrorKind.BadSignature));

            // Подмена срока обновлений в содержимом при прежней подписи.
            var parts = key[LicenseCodec.Prefix.Length..].Split('.');
            var body = Encoding.UTF8.GetString(LicenseCodec.FromBase64Url(parts[0])!).Replace("2027-09-27", "2099-09-27");
            var tampered = LicenseCodec.Prefix + LicenseCodec.ToBase64Url(Encoding.UTF8.GetBytes(body)) + "." + parts[1];
            ExpectError("ключ с продлённым вручную сроком не проходит", () => LicenseCodec.Verify(tampered, publicKey), e => Is(e, LicenseErrorKind.BadSignature));

            foreach (var garbage in new[] { "", "OFFLOAD-", "OFFLOAD-abc", "OFFLOAD-абв.где", "offload-" + key[8..], "OFFLOAD-..", key[..^4], key + "=" })
                ExpectError($"мусор «{garbage[..Math.Min(20, garbage.Length)]}» не проходит", () => LicenseCodec.Verify(garbage, publicKey), e => e is LicenseException);
            Check(LicenseCodec.PublicKey.Length == 43 && LicenseCodec.FromBase64Url(LicenseCodec.PublicKey)?.Length == 32,
                  "в программе настоящий открытый ключ Ed25519");
        });

        Section("Pro: один ключ на Mac и Windows", () =>
        {
            var mac = new License("mac00001", "Анна «тест» / QA", issued, until);
            Check(() => LicenseCodec.Verify(MacKey, MacPublicKey) == mac, "ключ, выпущенный версией для Mac, проверяется здесь");
            // Содержимое выпускается одинаково на обеих: ключи по алфавиту, кириллица и «/» без экранирования.
            var macBody = LicenseCodec.FromBase64Url(MacKey[LicenseCodec.Prefix.Length..].Split('.')[0])!;
            Check(LicenseCodec.Body(mac).SequenceEqual(macBody), "содержимое ключа совпадает с версией для Mac байт в байт");
            ExpectError("ключ от Mac с чужим открытым ключом не проходит", () => LicenseCodec.Verify(MacKey, publicKey), e => Is(e, LicenseErrorKind.BadSignature));
        });

        Section("Pro: какие версии открывает ключ", () =>
        {
            Check(license.Covers(null), "сборка из исходников без даты выхода — открывается");
            Check(license.Covers(LicenseCodec.Day("2027-09-27")), "версия, вышедшая в последний день обновлений, — открывается");
            Check(!license.Covers(LicenseCodec.Day("2027-09-28")), "версия, вышедшая позже, — нет");
        });

        Section("Pro: проба, ранние пользователи, продление", () =>
        {
            var start = LicenseCodec.Day("2026-10-01")!.Value;
            DateTime At(int days) => start.AddDays(days).AddHours(1);
            var later = LicenseCodec.Day("2028-01-01");
            Check(ProStatus.Resolve(null, null, false, start, At(0)) == ProStatus.Trial(14), "в первый день проба — 14 дней");
            Check(ProStatus.Resolve(null, null, false, start, At(13)) == ProStatus.Trial(1), "на 14-й день — остался один");
            Check(ProStatus.Resolve(null, null, false, start, At(14)) == ProStatus.Free, "на 15-й день — бесплатная версия");
            Check(ProStatus.Resolve(null, null, true, null, At(400)).IsPro, "ранний пользователь — Pro без срока");
            Check(ProStatus.Resolve(license, null, false, start, At(400)) == new ProStatus(ProStatusKind.Licensed, license), "ключ — Pro и после пробы");
            Check(ProStatus.Resolve(license, later, false, start, At(400)) == new ProStatus(ProStatusKind.Expired, license),
                  "версия новее конца обновлений — просит продлить, а не молчит");
            Check(ProStatus.Resolve(license, later, false, start, At(3)) == ProStatus.Trial(11), "ключ, не подходящий к версии, пробу не отнимает");
            Check(ProStatus.Resolve(license, later, true, null, At(400)) == ProStatus.Early, "ранний пользователь с просроченным ключом — всё открыто");
            // Часы переведены назад — проба не становится длиннее 14 дней.
            Check(ProStatus.Resolve(null, null, false, start, At(-30)) == ProStatus.Trial(14), "часы назад не удлиняют пробу");
        });

        Section("Pro: что закрыто, а что нет", () =>
        {
            Check(QuestionKind.Of(CleanupModule.Duplicates).ProFeature() == ProFeature.Duplicates, "лишние копии — Pro");
            Check(QuestionKind.Of(CleanupModule.Projects).ProFeature() == ProFeature.ProjectBackup, "проекты в бэкап — Pro");
            // То, что освобождает место без риска и возвращает своё, — бесплатно всегда.
            foreach (var kind in new[] { QuestionKind.Of(CleanupModule.Junk), QuestionKind.Of(CleanupModule.Safe), QuestionKind.Of(CleanupModule.Installers), QuestionKind.Docker })
                Check(kind.ProFeature() == null, $"{kind} — бесплатно");
        });
    }
}
