using System.Globalization;
using Offload.Core;

namespace Offload;

/// <summary>Сообщения о новых версиях. Выключены, пока человек их не включит: сам OffLoadAI в сеть не ходит.
/// Включённые — раз в сутки спрашивают у GitHub номер последнего выпуска (см. <see cref="UpdateCheck"/>).
/// Обновляется человек сам — той же командой установки, что сверяет архив.</summary>
public sealed class UpdatesModel : Observable
{
    /// <summary>Та же команда, что в README: скачивает выпуск, сверяет его и ставит на место этой версии.</summary>
    public const string InstallCommand = "irm https://raw.githubusercontent.com/audit0/Offload/main/windows/scripts/install.ps1 | iex";

    const string EnabledKey = "updates.enabled";
    const string LastCheckKey = "updates.lastCheck";
    const string PostponedKey = "updates.postponed";

    bool? enabled;
    /// <summary>null — человека ещё не спрашивали: тогда на «Обзоре» висит вопрос.</summary>
    public bool? Enabled { get => enabled; private set => Set(ref enabled, value); }

    UpdateCheck.Release? available;
    /// <summary>Вышла версия новее этой, и человек не отложил именно её.</summary>
    public UpdateCheck.Release? Available { get => available; private set => Set(ref available, value); }

    bool isChecking;
    public bool IsChecking { get => isChecking; private set => Set(ref isChecking, value); }

    public UpdatesModel()
    {
        // Снимки для README: вопроса на «Обзоре» нет, в сеть программа не ходит.
        enabled = Demo.IsOn ? false : Settings.Get<bool?>(EnabledKey);
    }

    public void SetEnabled(bool on)
    {
        Enabled = on;
        Settings.Set(EnabledKey, on);
        if (on) CheckIfDue();
        else Available = null;
    }

    /// <summary>При запуске и когда окно снова становится активным: раз в сутки и только с разрешения.</summary>
    public void CheckIfDue()
    {
        if (Enabled != true || Demo.IsOn || IsChecking) return;
        DateTime? last = DateTime.TryParse(Settings.Get<string>(LastCheckKey), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var parsed)
            ? parsed : null;
        if (UpdateCheck.IsDue(last, DateTime.UtcNow)) _ = Check(manual: false);
    }

    /// <summary>«Проверить обновления»: один вопрос к GitHub по нажатию — само нажатие и есть согласие.
    /// Итог для человека: null — вышла новая версия (она в <see cref="Available"/>), иначе фраза.</summary>
    public Task<string?> CheckNow() =>
        Demo.IsOn ? Task.FromResult<string?>("В демонстрации версии не проверяются.")
        : IsChecking ? Task.FromResult<string?>("Уже проверяю — подождите немного.")
        : Check(manual: true);

    /// <summary>Не напоминать об этой версии; о следующей — напомнить.</summary>
    public void Postpone()
    {
        if (Available is { } release) Settings.Set(PostponedKey, release.Version);
        Available = null;
    }

    async Task<string?> Check(bool manual)
    {
        IsChecking = true;
        // Время попытки запоминается и при неудаче: без сети программа не стучится в GitHub при каждом возврате к окну.
        Settings.Set(LastCheckKey, DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture));
        try
        {
            var release = await UpdateCheck.FetchAsync();
            var current = Dialogs.Version;
            if (!UpdateCheck.IsNewer(release.Version, current))
            {
                Available = null;
                return $"Установлена последняя версия — {current}.";
            }
            if (manual || Settings.Get<string>(PostponedKey) != release.Version) Available = release;
            return null;
        }
        catch (Exception e) { return "Не удалось проверить: " + e.Message; }
        finally { IsChecking = false; }
    }
}
