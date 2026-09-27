using System.IO;
using Offload.Core;

namespace Offload;

/// <summary>Порядок разделов — это и есть сценарий: посмотреть, что с компьютером; завести сейф;
/// освободить место переносом в него; видеть и возвращать перенесённое; бэкапить.</summary>
public enum SidebarSection { Overview, Cleanup, Safe, Space, History, Backup, ICloud, Docker }

public static class SidebarSections
{
    public static readonly SidebarSection[] All = Enum.GetValues<SidebarSection>();

    public static string Title(this SidebarSection section) => section switch
    {
        SidebarSection.Overview => "Обзор",
        SidebarSection.Cleanup => "Разобрать",
        SidebarSection.Safe => "Сейф",
        SidebarSection.Space => "Освободить место",
        SidebarSection.History => "Перенесённое",
        SidebarSection.Backup => "Бэкап",
        SidebarSection.ICloud => "Из iCloud",
        _ => "Docker",
    };

    /// <summary>Значок из шрифта Segoe Fluent Icons.</summary>
    public static string Glyph(this SidebarSection section) => section switch
    {
        SidebarSection.Overview => Glyphs.Gauge,
        SidebarSection.Cleanup => Glyphs.Sparkle,
        SidebarSection.Safe => Glyphs.Shield,
        SidebarSection.Space => Glyphs.Chart,
        SidebarSection.History => Glyphs.History,
        SidebarSection.Backup => Glyphs.Backup,
        SidebarSection.ICloud => Glyphs.CloudDownload,
        _ => Glyphs.Package,
    };

    /// <summary>Имя раздела для снимков: OFFLOAD_SNAPSHOT_SECTIONS=overview,safe.</summary>
    public static string Key(this SidebarSection section) => section == SidebarSection.ICloud ? "icloud" : section.ToString().ToLowerInvariant();
}

/// <summary>Куда класть: в сейф (зашифровано) или открытой папкой на диск.</summary>
public enum StoreMode { Safe, Open }

public sealed class AppModel : Observable
{
    SidebarSection section = SidebarSection.Overview;
    public SidebarSection Section { get => section; set => Set(ref section, value); }

    List<VolumeInfo> mountedVolumes = [];
    /// <summary>Внешние диски. Открытый сейф — тоже том, но не отдельный диск: его здесь нет.</summary>
    public List<VolumeInfo> Volumes => mountedVolumes.Where(v => !Safe.EncryptedMounts.Contains(v.MountPoint)).ToList();

    string? destinationId;
    public string? DestinationId
    {
        get => destinationId;
        set
        {
            if (!Set(ref destinationId, value)) return;
            RaiseDerived();
            Safe.Refresh(this);
        }
    }

    public SafetyRules Rules { get; } = new();
    public SafeModel Safe { get; } = new();
    public OverviewModel Overview { get; } = new();
    public SpaceModel Space { get; } = new();
    public HistoryModel History { get; } = new();
    public BackupModel Backup { get; } = new();
    public DockerModel Docker { get; } = new();
    public CleanupModel Cleanup { get; } = new();
    public CloudRestoreModel Cloud { get; } = new();

    /// <summary>Только что подключённый внешний диск: «Обзор» предлагает разобрать компьютер одной кнопкой.</summary>
    string? connectedPrompt;
    public string? ConnectedPrompt { get => connectedPrompt; set => Set(ref connectedPrompt, value); }

    readonly Dictionary<Guid, Action> cancellers = [];
    int runningOperations;
    /// <summary>Сколько операций прямо сейчас копируют данные: пока они идут, выход из программы
    /// оставил бы на диске незаконченную копию, поэтому он спрашивает подтверждение.</summary>
    public int RunningOperations { get => runningOperations; private set { Set(ref runningOperations, value); Raise(nameof(IsBusy)); } }
    public bool IsBusy => RunningOperations > 0;

    public VolumeInfo? Destination => Volumes.FirstOrDefault(v => v.Id == DestinationId);

    StoreMode storeMode = Settings.Get<string>("storeMode") == "open" ? StoreMode.Open : StoreMode.Safe;
    /// <summary>По умолчанию — в сейф: на внешнем диске, который можно потерять, открытыми лежать должны
    /// только те данные, для которых человек сам так решил.</summary>
    public StoreMode StoreMode
    {
        get => storeMode;
        set
        {
            if (!Set(ref storeMode, value)) return;
            Settings.Set("storeMode", value == StoreMode.Open ? "open" : "safe");
            RaiseDerived();
        }
    }

    /// <summary>Открытый сейф на выбранном диске как место назначения.</summary>
    public VolumeInfo? SafeVolume => Safe.Volume(Destination);

    /// <summary>Куда пойдут перенос, бэкап и тома Docker: сейф или сам диск — как выбрано.</summary>
    public VolumeInfo? Target => StoreMode == StoreMode.Safe ? SafeVolume : Destination;

    /// <summary>Почему класть некуда — одной фразой, с тем, что сделать.</summary>
    public string? TargetProblem
    {
        get
        {
            if (Destination == null) return "Подключите внешний диск.";
            if (StoreMode != StoreMode.Safe || SafeVolume != null) return null;
            return Safe.Exists ? "Сейф закрыт — откройте его паролем." : "На диске нет сейфа — создайте его в разделе «Сейф».";
        }
    }

    /// <summary>Где искать журналы переносов: подключённые диски и открытый сейф.</summary>
    public List<VolumeInfo> HistoryVolumes => [.. Volumes, .. SafeVolume is { } safe ? [safe] : Array.Empty<VolumeInfo>()];

    /// <summary>Перенесённое, что лежит на выбранном диске открыто: его прочтёт любой, у кого диск.</summary>
    public List<MoveRecord> PlainRecords
    {
        get
        {
            if (Destination is not { } host) return [];
            if (Demo.IsOn) return History.Records.Where(r => !r.IsEncrypted && !r.Restored).ToList();
            return History.Records.Where(r => !r.IsEncrypted && Paths.IsInside(r.ArchivedPath, host.MountPoint) && FileSystem.Exists(r.ArchivedPath)).ToList();
        }
    }

    /// <summary>Идентификатор заводится на каждый запуск свой: один общий на модель снимал бы учёт обоих запусков
    /// по концу первого, и выход из программы переставал бы спрашивать посреди копирования.</summary>
    public Guid BeginOperation(Action cancel)
    {
        var id = Guid.NewGuid();
        cancellers[id] = cancel;
        RunningOperations++;
        Safe.NoteUse();
        return id;
    }

    public void EndOperation(Guid id)
    {
        if (!cancellers.Remove(id)) return;
        RunningOperations = Math.Max(0, RunningOperations - 1);
        // Закрытие сейфа, отложенное ради копирования (сон, блокировка экрана, команда), — сейчас.
        if (RunningOperations == 0) Safe.OperationsFinished(this);
    }

    public void CancelEverything()
    {
        foreach (var cancel in cancellers.Values.ToList()) cancel();
    }

    public AppModel()
    {
        RefreshVolumes();
        Safe.StartGuards(this);
        Safe.Refresh(this);
        _ = Safe.ReloadEncryptedMounts(this);
    }

    /// <summary>Подключили или отключили том (Windows сообщает об этом окну). Сейф — тоже том: его открытие
    /// и закрытие приходят сюда же, в том числе если его открыли или закрыли в обход Offload.</summary>
    public async void VolumesChanged(bool arrived)
    {
        var known = Volumes.Select(v => v.Id).ToHashSet(Paths.Comparer);
        bool opening = Safe.Activity != null;
        // Сначала — какие из томов открытые сейфы: иначе сейф на миг попал бы в список дисков.
        await Safe.ReloadEncryptedMounts(this);
        RefreshVolumes();
        Safe.Refresh(this);
        if (arrived && !opening && Volumes.FirstOrDefault(v => !known.Contains(v.Id) && v.Name != SecretsVault.SafeVolumeName) is { } added)
            ConnectedPrompt = added.Name;
    }

    /// <summary>Список внешних дисков и свободное место на них меняются после каждой операции.</summary>
    public void RefreshVolumes()
    {
        if (Demo.IsOn)
        {
            mountedVolumes = [Demo.Disk];
            destinationId = Demo.Disk.Id;
            RaiseDerived();
            return;
        }
        mountedVolumes = Offload.Core.Volumes.External();
        if (Destination == null) destinationId = Volumes.FirstOrDefault()?.Id;
        RaiseDerived();
    }

    /// <summary>Свойства, которые считаются из дисков, сейфа и режима.</summary>
    public void RaiseDerived() => Raise(nameof(Volumes), nameof(DestinationId), nameof(Destination), nameof(SafeVolume), nameof(Target),
                                        nameof(TargetProblem), nameof(HistoryVolumes), nameof(PlainRecords), nameof(StoreMode));
}
