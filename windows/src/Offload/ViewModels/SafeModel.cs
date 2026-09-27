using System.Runtime.InteropServices;
using System.Windows.Threading;
using Microsoft.Win32;
using Offload.Core;

namespace Offload;

/// <summary>Сейф — зашифрованный BitLocker образ VHDX на внешнем диске.
///
/// Пока он открыт, перенос, бэкап и ключи идут в него; закрыт — на диске лежит только шифротекст,
/// и потерянный или украденный диск ничего не выдаёт. Пароль Offload не хранит: он приходит из поля ввода,
/// уходит в BitLocker и больше нигде не живёт.</summary>
public sealed class SafeModel : Observable
{
    public sealed record State(
        /// <summary>Внешний диск, на котором лежит образ.</summary>
        string VolumeId,
        string ImagePath,
        bool Exists,
        bool IsEncrypted,
        EncryptionInfo? Info,
        long? SizeLimit,
        long Allocated,
        string? Mount,
        IReadOnlyList<string> Candidates,
        /// <summary>Зашифрован ли сам внешний диск целиком (BitLocker To Go).</summary>
        bool HostEncrypted)
    {
        public string DisplayName => System.IO.Path.GetFileNameWithoutExtension(ImagePath);
    }

    /// <summary>Перенос открытых архивов внутрь сейфа: какой по счёту и сколько байт.</summary>
    public sealed record Migration(int Index, int Count, string Item, string Phase, long BytesDone, long BytesTotal)
    {
        public double Fraction => BytesTotal > 0 ? Math.Min(1, (double)BytesDone / BytesTotal) : 0;
    }

    State? state;
    public State? Current { get => state; private set { Set(ref state, value); Raise(nameof(IsOpen), nameof(Exists), nameof(Summary), nameof(SummaryGlyph), nameof(SummaryTone)); } }

    string? activity;
    /// <summary>Что сейчас делается с сейфом («Открываю…»): пока не null, кнопки заблокированы.</summary>
    public string? Activity { get => activity; private set => Set(ref activity, value); }

    Migration? migration;
    public Migration? MigrationProgress { get => migration; private set => Set(ref migration, value); }

    NoticeMessage? message;
    public NoticeMessage? Message { get => message; set => Set(ref message, value); }

    string? unlockError;
    /// <summary>Почему не открылся: показывается прямо под полем пароля — там, где его вводили.</summary>
    public string? UnlockError { get => unlockError; set => Set(ref unlockError, value); }

    bool closeBlocked;
    /// <summary>Закрыть не дали открытые в сейфе файлы: предложить закрыть принудительно.</summary>
    public bool CloseBlocked { get => closeBlocked; set => Set(ref closeBlocked, value); }

    /// <summary>Куда подключены открытые зашифрованные образы — в том числе открытые Проводником.
    /// Такой том — это сейф, а не ещё один внешний диск.</summary>
    public HashSet<string> EncryptedMounts { get; private set; } = new(Paths.Comparer);

    string? pendingClose;
    /// <summary>Почему сейф закроется, как только закончится идущая операция.</summary>
    public string? PendingClose { get => pendingClose; private set => Set(ref pendingClose, value); }
    /// <summary>Сон или блокировка пришли, пока сейф открывался: закрыть, как только откроется.</summary>
    string? closeAfterOpening;
    public const string OpeningTitle = "Открываю сейф…";

    bool closeOnSleep = Settings.Get<bool?>("safe.closeOnSleep") ?? true;
    public bool CloseOnSleep { get => closeOnSleep; set { if (Set(ref closeOnSleep, value)) Settings.Set("safe.closeOnSleep", value); } }
    bool closeOnLock = Settings.Get<bool?>("safe.closeOnLock") ?? true;
    public bool CloseOnLock { get => closeOnLock; set { if (Set(ref closeOnLock, value)) Settings.Set("safe.closeOnLock", value); } }
    int idleMinutes = Settings.Get<int?>("safe.idleMinutes") ?? 30;
    /// <summary>Через сколько минут простоя закрывать сам; 0 — не закрывать.</summary>
    public int IdleMinutes { get => idleMinutes; set { if (Set(ref idleMinutes, value)) Settings.Set("safe.idleMinutes", value); } }
    bool interruptOperations = Settings.Get<bool?>("safe.interrupt") ?? false;
    /// <summary>Закрывать даже посреди копирования: операция отменяется, оригиналы остаются на месте.</summary>
    public bool InterruptOperations { get => interruptOperations; set { if (Set(ref interruptOperations, value)) Settings.Set("safe.interrupt", value); } }

    readonly Dictionary<string, string> preferredImages = Settings.Get<Dictionary<string, string>>("safe.images") ?? [];
    DateTime lastUse = DateTime.UtcNow;
    Guid generation = Guid.NewGuid();
    DispatcherTimer? idleTimer;
    DispatcherTimer? screensaverTimer;
    bool screensaverWasRunning;
    CancelToken? migrationToken;
    /// <summary>Формат и число паролей: у открытого образа их не узнать — помним с закрытого.</summary>
    readonly Dictionary<string, EncryptionInfo> knownInfo = new(Paths.Comparer);

    public bool IsOpen => state?.Mount != null;
    public bool Exists => state?.Exists == true;

    public static readonly int[] IdleChoices = [0, 5, 15, 30, 60];

    // MARK: Состояние одной строкой — для боковой панели и «Обзора».

    public string Summary => state == null ? "Смотрю, есть ли сейф…" : !state.Exists ? "Сейфа нет" : !state.IsEncrypted ? "Образ не зашифрован"
                           : IsOpen ? "Сейф открыт" : "Сейф закрыт";
    public string SummaryGlyph => state == null ? Glyphs.Lock : !state.Exists ? Glyphs.LockSlash : !state.IsEncrypted ? Glyphs.Error
                                : IsOpen ? Glyphs.Unlock : Glyphs.Lock;
    public Tone SummaryTone => state == null || !state.Exists ? Tone.Neutral : !state.IsEncrypted ? Tone.Danger : IsOpen ? Tone.Caution : Tone.Good;

    // MARK: Состояние

    /// <summary>Перечитывает, что с сейфом на выбранном диске. Ответ привязан к диску: запрос про прежний диск,
    /// пришедший последним, не должен перезаписать состояние нового.</summary>
    public async void Refresh(AppModel app)
    {
        if (Demo.IsOn)
        {
            Current = Demo.SafeState;
            return;
        }
        if (app.Destination is not { } host)
        {
            Current = null;
            app.RaiseDerived();
            return;
        }
        var generation = Guid.NewGuid();
        this.generation = generation;
        if (state?.VolumeId != host.Id) Current = null;
        preferredImages.TryGetValue(host.Id, out var preferred);
        var answer = await Task.Run(() =>
        {
            // Нет ответа — состояние не трогаем: открытый сейф не должен на время сбоя «закрыться»
            // в интерфейсе и выпасть из автозакрытия.
            if (SecretsVault.AttachedImagesIfKnown() is not { } attached) return ((State, HashSet<string>)?)null;
            var vault = new SecretsVault(host, preferred, attached);
            var status = vault.GetStatus(attached);
            var found = new State(host.Id, vault.ImagePath, status.Exists, status.IsEncrypted, status.Info,
                                  status.Exists ? vault.SizeLimit : null, status.Exists ? vault.AllocatedBytes : 0, status.MountPoint,
                                  SecretsVault.Candidates(host.MountPoint, attached), Offload.Core.Volumes.IsVolumeEncrypted(host));
            return (found, Mounts(attached));
        });
        if (answer is not var (found, mounts)) return;
        UpdateEncryptedMounts(mounts, app);
        if (this.generation != generation || app.DestinationId != found.VolumeId) return;
        if (found.Info is { } info) knownInfo[found.ImagePath] = info;
        else if (knownInfo.TryGetValue(found.ImagePath, out var known)) found = found with { Info = known };
        Current = found;
        app.RaiseDerived();
    }

    static HashSet<string> Mounts(Dictionary<string, SecretsVault.Attachment> attached) =>
        attached.Values.Where(a => a.Encrypted && a.MountPoint != null).Select(a => a.MountPoint!).ToHashSet(Paths.Comparer);

    /// <summary>Открытые зашифрованные образы изменились: список внешних дисков — без них.</summary>
    void UpdateEncryptedMounts(HashSet<string> mounts, AppModel app)
    {
        if (mounts.SetEquals(EncryptedMounts)) return;
        EncryptedMounts = mounts;
        app.RefreshVolumes();
    }

    /// <summary>Перечитать только, какие зашифрованные образы открыты, — после подключения диска или тома.</summary>
    public async Task ReloadEncryptedMounts(AppModel app)
    {
        if (Demo.IsOn) return;
        var mounts = await Task.Run(() => Mounts(SecretsVault.AttachedImages()));
        UpdateEncryptedMounts(mounts, app);
    }

    /// <summary>Сейф как место назначения: том внутри образа, а свободное место — меньшее из того,
    /// что осталось внутри образа и на самом диске.</summary>
    public VolumeInfo? Volume(VolumeInfo? host)
    {
        if (Demo.IsOn) return IsOpen ? Demo.SafeVolume : null;
        if (host == null || state == null || state.VolumeId != host.Id || !state.IsEncrypted || state.Mount is not { } mount) return null;
        return Offload.Core.Volumes.Safe(mount, host);
    }

    /// <summary>Какой из зашифрованных образов на диске считать сейфом.</summary>
    public void Choose(string image, AppModel app)
    {
        if (app.Destination is not { } host) return;
        preferredImages[host.Id] = image;
        Settings.Set("safe.images", preferredImages);
        Refresh(app);
    }

    // MARK: Открыть, закрыть, создать

    /// <summary>failed — своя реакция на ошибку вместо общего сообщения вверху раздела.</summary>
    async void Perform(string title, AppModel app, Func<NoticeMessage?> work, Action<Exception>? failed = null, Action? after = null)
    {
        if (Activity != null) return;
        Activity = title;
        Message = null;
        try
        {
            if (await Task.Run(work) is { } result) Message = result;
        }
        catch (Exception error)
        {
            if (failed != null) failed(error);
            else Message = new NoticeMessage(NoticeKind.Error, error.Message);
        }
        Activity = null;
        after?.Invoke();
        app.RefreshVolumes();
        Refresh(app);
    }

    /// <summary>Сейф на выбранном диске с пределом limit. Образ разрежённый: места он занимает ровно столько,
    /// сколько в нём лежит, а предел потом можно увеличить.</summary>
    public void Create(string password, long limit, AppModel app)
    {
        if (app.Destination is not { } host) return;
        var vault = new SecretsVault(System.IO.Path.Combine(host.MountPoint, SecretsVault.SafeImageName));
        long bounded = Math.Min(Math.Max(limit, 1L << 30), host.TotalBytes);
        Perform("Создаю сейф…", app, () =>
        {
            vault.Create(password, bounded, SecretsVault.SafeVolumeName);
            return new NoticeMessage(NoticeKind.Success, "Сейф создан: BitLocker, XTS-AES-256, пароль знаете только вы. Если его забыть, данные не восстановит никто — даже Offload.");
        }, after: () =>
        {
            preferredImages[host.Id] = vault.ImagePath;
            Settings.Set("safe.images", preferredImages);
        });
    }

    /// <summary>Увеличивает предел закрытого сейфа; содержимое остаётся на месте.</summary>
    public void Grow(long limit, string password, AppModel app)
    {
        if (state is not { Exists: true, Mount: null } current) return;
        var vault = new SecretsVault(current.ImagePath);
        Perform("Увеличиваю сейф…", app, () =>
        {
            vault.Grow(limit, password);
            return new NoticeMessage(NoticeKind.Success,
                $"Предел сейфа — {Format.Bytes(vault.SizeLimit ?? limit)}. Содержимое на месте, а места на диске образ занимает столько же, сколько занимал.");
        });
    }

    /// <summary>Какие пределы предложить: круглые размеры больше above и меньше диска, и весь диск.</summary>
    public static List<long> LimitChoices(VolumeInfo host, long above = 0)
    {
        const long gigabyte = 1_000_000_000;
        var presets = new long[] { 8, 16, 32, 64, 128, 256, 512, 1000, 2000, 4000 }.Select(g => g * gigabyte);
        var result = presets.Where(p => p > above && p < host.TotalBytes * 9 / 10).ToList();
        if (host.TotalBytes > above) result.Add(host.TotalBytes);
        return result;
    }

    /// <summary>Сколько примерно ещё поместится в сейф. Открыт — точно (с учётом места на диске);
    /// закрыт — предел минус занятое образом, но не больше свободного на диске.</summary>
    public long? RoomLeft(VolumeInfo? host, VolumeInfo? volume)
    {
        if (volume != null) return volume.AvailableBytes;
        if (host == null || state == null || state.VolumeId != host.Id || !state.IsEncrypted || state.SizeLimit is not { } limit) return null;
        return Math.Max(0, Math.Min(limit - state.Allocated, host.AvailableBytes));
    }

    public void Open(string password, AppModel app)
    {
        if (state is not { Exists: true } current) return;
        var vault = new SecretsVault(current.ImagePath);
        string? opened = null;
        UnlockError = null;
        closeAfterOpening = null;
        Perform(OpeningTitle, app, () =>
        {
            opened = vault.Attach(password);
            return null;
        }, failed: error => UnlockError = error.Message, after: () =>
        {
            lastUse = DateTime.UtcNow;
            // Сразу, не дожидаясь перечитывания: открытие уже спросило BitLocker, что том зашифрован.
            if (opened != null && state != null && Paths.Same(state.ImagePath, vault.ImagePath))
            {
                Current = state with { Mount = opened, IsEncrypted = true };
                app.RaiseDerived();
            }
            if (closeAfterOpening is { } reason)
            {
                closeAfterOpening = null;
                Close(app, reason: reason);
            }
        });
    }

    /// <summary>Закрыть по команде человека. Если в сейф прямо сейчас пишется, он закроется сразу после конца
    /// операции: оборвать копирование ради закрытия — не то, чего человек ждёт.</summary>
    public void Close(AppModel app, bool force = false, string? reason = null)
    {
        if (state?.Mount is not { } mount) return;
        if (app.IsBusy && !force)
        {
            PendingClose = reason ?? "по вашей команде";
            Message = new NoticeMessage(NoticeKind.Info, "Идёт копирование — сейф закроется, как только оно закончится.");
            return;
        }
        PendingClose = null;
        CloseBlocked = false;
        Perform("Закрываю сейф…", app, () =>
        {
            SecretsVault.Detach(mount, force);
            return new NoticeMessage(NoticeKind.Success, reason != null ? $"Сейф закрыт: {reason}." : "Сейф закрыт — на диске снова только шифротекст.");
        }, failed: error =>
        {
            // Открытые файлы — не ошибка, а вопрос: закрыть ли принудительно.
            if (error is VaultException { Kind: VaultErrorKind.Busy }) CloseBlocked = true;
            else Message = new NoticeMessage(NoticeKind.Error, error.Message);
        });
    }

    // MARK: Автозакрытие

    [DllImport("user32.dll")]
    static extern bool SystemParametersInfo(uint action, uint parameter, out bool value, uint flags);
    const uint SPI_GETSCREENSAVERRUNNING = 0x0072;

    /// <summary>Подписка на сон, блокировку экрана, заставку, смену пользователя и таймер простоя —
    /// то же, что «Auto-dismount» в VeraCrypt. Ключ шифрования живёт в памяти, пока сейф открыт,
    /// и лучший способ его защитить — не держать сейф открытым без нужды.</summary>
    public void StartGuards(AppModel app)
    {
        // Вымышленный сейф закрывать нечем и незачем.
        if (Demo.IsOn) return;
        SystemEvents.PowerModeChanged += (_, e) =>
        {
            if (e.Mode != PowerModes.Suspend || !CloseOnSleep) return;
            // Перед сном асинхронная работа может не успеть — закрываем прямо здесь.
            Ui.Post(() => CloseNow("компьютер уходит в сон", app));
        };
        SystemEvents.SessionSwitch += (_, e) =>
        {
            if (!CloseOnLock) return;
            string? reason = e.Reason switch
            {
                SessionSwitchReason.SessionLock => "экран заблокирован",
                SessionSwitchReason.ConsoleDisconnect or SessionSwitchReason.RemoteDisconnect => "сменился пользователь",
                SessionSwitchReason.SessionLogoff => "выход из учётной записи",
                _ => null,
            };
            if (reason != null) Ui.Post(() => Trigger(reason, app));
        };
        screensaverTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        screensaverTimer.Tick += (_, _) =>
        {
            bool running = SystemParametersInfo(SPI_GETSCREENSAVERRUNNING, 0, out var value, 0) && value;
            if (running && !screensaverWasRunning && CloseOnLock) Trigger("включилась заставка", app);
            screensaverWasRunning = running;
        };
        screensaverTimer.Start();
        idleTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(60) };
        idleTimer.Tick += (_, _) => CheckIdle(app);
        idleTimer.Start();
    }

    /// <summary>Любая работа с сейфом откладывает закрытие по простою.</summary>
    public void NoteUse() => lastUse = DateTime.UtcNow;

    /// <summary>Операции закончились: если закрытие было отложено ради них — закрываем.</summary>
    public void OperationsFinished(AppModel app)
    {
        lastUse = DateTime.UtcNow;
        if (PendingClose is { } reason) Close(app, reason: reason);
    }

    public void Trigger(string reason, AppModel app)
    {
        if (Activity == OpeningTitle)
        {
            closeAfterOpening = reason;
            return;
        }
        if (!IsOpen) return;
        if (app.IsBusy)
        {
            PendingClose = reason;
            if (InterruptOperations) app.CancelEverything();
            else Message = new NoticeMessage(NoticeKind.Info, $"Сейф закроется, как только закончится копирование ({reason}).");
            return;
        }
        Close(app, reason: reason);
    }

    /// <summary>Перед сном закрываем прямо здесь. Если в сейф пишется, а прерывать операции не разрешено,
    /// он останется открытым — и об этом будет сказано, а не промолчано.</summary>
    void CloseNow(string reason, AppModel app)
    {
        if (Activity == OpeningTitle)
        {
            closeAfterOpening = reason;
            return;
        }
        if (state?.Mount is not { } mount) return;
        if (app.IsBusy && !InterruptOperations)
        {
            PendingClose = reason;
            Message = new NoticeMessage(NoticeKind.Warning, "Перед сном сейф остался открытым: шло копирование. Он закроется, как только оно закончится.");
            return;
        }
        if (app.IsBusy) app.CancelEverything();
        try
        {
            SecretsVault.Detach(mount, InterruptOperations);
            Current = state with { Mount = null };
            Message = new NoticeMessage(NoticeKind.Success, $"Сейф закрыт: {reason}.");
        }
        catch (Exception error)
        {
            Message = new NoticeMessage(NoticeKind.Warning, $"Перед сном сейф закрыть не удалось: {error.Message}");
        }
        app.RefreshVolumes();
    }

    async void CheckIdle(AppModel app)
    {
        if (IdleMinutes <= 0 || !IsOpen || app.IsBusy || Activity != null || DateTime.UtcNow - lastUse <= TimeSpan.FromMinutes(IdleMinutes)
            || state?.Mount is not { } mount) return;
        // Без force: если в сейфе открыты файлы, закрытие откажет — и правильно. Попробуем снова через тот же срок.
        lastUse = DateTime.UtcNow;
        bool closed = await Task.Run(() =>
        {
            try { SecretsVault.Detach(mount); return true; }
            catch (Exception) { return false; }
        });
        if (closed) Message = new NoticeMessage(NoticeKind.Success, $"Сейф закрыт: им не пользовались {IdleMinutes} мин.");
        app.RefreshVolumes();
        Refresh(app);
    }

    // MARK: Пароль, заголовок, место

    public void ChangePassword(string oldPassword, string newPassword, AppModel app)
    {
        if (state is not { Exists: true, Mount: null } current) return;
        var vault = new SecretsVault(current.ImagePath);
        Perform("Меняю пароль…", app, () =>
        {
            vault.ChangePassword(oldPassword, newPassword);
            return new NoticeMessage(NoticeKind.Success, "Пароль сменён.",
                ["Копии заголовка, снятые раньше, по-прежнему открываются старым паролем. Снимите новую копию, а старые удалите."]);
        });
    }

    public void Compact(string password, AppModel app)
    {
        if (state is not { Exists: true, Mount: null } current) return;
        var vault = new SecretsVault(current.ImagePath);
        long before = current.Allocated;
        Perform("Возвращаю место на диск…", app, () =>
        {
            var note = vault.Compact(password);
            long after = vault.AllocatedBytes;
            long returned = Math.Max(0, before - after);
            var details = note.Length > 0 ? new[] { note } : [];
            if (returned < 16L << 20)
                return new NoticeMessage(NoticeKind.Info, $"Пустых участков в образе почти не нашлось: диску вернулось {Format.Bytes(returned)}. Место внутри сейфа при этом свободно и пойдёт под новые данные.", details);
            return new NoticeMessage(NoticeKind.Success, $"Диску возвращено {Format.Bytes(returned)}. Сейф занимает {Format.Bytes(after)}.", details);
        });
    }

    public void BackupHeader(string directory, AppModel app)
    {
        if (state is not { IsEncrypted: true, Mount: null } current) return;
        var vault = new SecretsVault(current.ImagePath);
        bool sameDisk = Paths.Same(Paths.Root(directory), Paths.Root(current.ImagePath));
        Perform("Сохраняю копию заголовка…", app, () =>
        {
            var path = vault.BackupHeader(directory);
            var details = new List<string> { "Копия защищена тем же паролем, что и сейф. Без пароля она бесполезна." };
            if (sameDisk) details.Add("Копия лежит на том же диске, что и сейф: при отказе диска пропадут обе. Сохраните ещё одну в другом месте.");
            return new NoticeMessage(NoticeKind.Success, $"Копия заголовка сохранена: {path}", details);
        });
    }

    public void RestoreHeader(string file, string password, AppModel app)
    {
        if (state is not { Exists: true, Mount: null } current) return;
        var vault = new SecretsVault(current.ImagePath);
        Perform("Восстанавливаю заголовок…", app, () =>
        {
            vault.RestoreHeader(file, password);
            return new NoticeMessage(NoticeKind.Success, "Заголовок восстановлен из копии, сейф открывается паролем этой копии.");
        });
    }

    // MARK: Зашифровать перенесённое

    /// <summary>Переносит архивы, лежащие на диске открыто, внутрь сейфа — по одному, со сверкой.</summary>
    public async void Encrypt(IReadOnlyList<MoveRecord> records, AppModel app)
    {
        if (Volume(app.Destination) is not { } safe || MigrationProgress != null || Activity != null) return;
        var token = new CancelToken();
        migrationToken = token;
        var operation = app.BeginOperation(token.Cancel);
        var rules = app.Rules;
        var throttle = new Throttle();
        MigrationProgress = new Migration(0, records.Count, "", "", 0, 0);
        Message = null;
        int done = 0;
        var failures = new List<string>();
        for (int index = 0; index < records.Count; index++)
        {
            if (token.IsCancelled) break;
            var record = records[index];
            var name = record.OriginalName;
            MigrationProgress = new Migration(index + 1, records.Count, name, "Подготовка", 0, 0);
            try
            {
                await Task.Run(() => new SafeMover(rules).Relocate(record, safe, () => token.IsCancelled, progress =>
                {
                    if (!throttle.Ready()) return;
                    Ui.Post(() =>
                    {
                        if (MigrationProgress is { } current)
                            MigrationProgress = current with { Phase = progress.Phase.Title(), BytesDone = progress.BytesDone, BytesTotal = progress.BytesTotal };
                    });
                }));
                done++;
            }
            catch (OperationCanceledException) { break; }
            catch (Exception error) { failures.Add($"«{name}»: {error.Message}"); }
        }
        MigrationProgress = null;
        migrationToken = null;
        app.EndOperation(operation);
        var details = new List<string>(failures)
        {
            "Удалённые открытые копии физически могут оставаться в памяти SSD или флешки, пока контроллер их не перезапишет. Полную гарантию даёт только диск, зашифрованный целиком (BitLocker To Go).",
        };
        Message = new NoticeMessage(failures.Count == 0 ? NoticeKind.Success : NoticeKind.Warning,
            token.IsCancelled
                ? $"Остановлено. В сейф перенесено: {done} из {records.Count}, остальное осталось на месте как было."
                : $"В сейф перенесено и сверено: {done} из {records.Count}. Открытые копии удалены.", details);
        app.History.Reload(app.HistoryVolumes);
        app.RefreshVolumes();
        Refresh(app);
    }

    public void CancelMigration() => migrationToken?.Cancel();
}
