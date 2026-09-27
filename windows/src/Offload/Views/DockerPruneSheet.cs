using System.Windows;
using System.Windows.Controls;
using Offload.Core;

namespace Offload;

/// <summary>Очистка того, что Docker пересоздаст сам. Тома сюда не входят: в них данные.</summary>
public sealed class DockerPruneSheet : SheetWindow
{
    static readonly DockerPruneTarget[] Order = [DockerPruneTarget.BuildCache, DockerPruneTarget.DanglingImages, DockerPruneTarget.Images, DockerPruneTarget.Containers];

    readonly AppModel app;
    readonly DockerUsage usage;
    /// <summary>Сразу отмечено только то, что точно не нужно: кеш сборки и образы без имени. Все неиспользуемые
    /// образы — нет: собранный вами и никуда не отправленный образ не скачать. Остановленные
    /// контейнеры — тоже нет: в них могут быть данные без тома.</summary>
    readonly HashSet<DockerPruneTarget> targets = [DockerPruneTarget.BuildCache, DockerPruneTarget.DanglingImages];
    readonly NoticeView containersWarning;
    readonly Button prune;

    public static string Detail(DockerPruneTarget target) => target switch
    {
        DockerPruneTarget.BuildCache => "Промежуточные слои от docker build. Следующая сборка пойдёт дольше, пока кеш не наберётся заново.",
        DockerPruneTarget.DanglingImages => "Остатки пересборок с именем <none>: запустить их не по чему, ни один контейнер их не использует.",
        DockerPruneTarget.Images => "Образы, которые не нужны ни одному контейнеру. Docker скачает их заново, когда понадобятся; собранные вами и никуда не отправленные придётся собрать снова. Отмечайте сами.",
        _ => "Всё, что записано внутри контейнера, а не в томе, пропадёт вместе с ним. Образы удалённых контейнеров тоже освободятся.",
    };

    public DockerPruneSheet(AppModel app)
    {
        this.app = app;
        usage = app.Docker.Usage ?? new DockerUsage();
        Width = 580;
        Glyph = Glyphs.Package;
        Heading = "Освободить место в Docker";
        if (app.Docker.RawBytes is { } raw) Subtitle = $"Диск Docker (docker_data.vhdx) занимает на компьютере {Format.Bytes(raw)}";

        var rows = new StackPanel();
        foreach (var target in Order)
        {
            if (target != Order[0]) rows.Children.Add(new Separator { Style = (Style)FindResource("RowDivider"), Margin = new Thickness(44, 0, 0, 0) });
            rows.Children.Add(Row(target, usage.Part(target)));
        }
        var body = new StackPanel();
        body.Children.Add(new Card { Padding = new Thickness(0), Content = rows });
        containersWarning = new NoticeView
        {
            Kind = NoticeKind.Warning, Margin = new Thickness(0, 12, 0, 0),
            Text = "Отмечайте остановленные контейнеры, только если они точно не нужны: удалённый контейнер не вернуть.",
        };
        body.Children.Add(containersWarning);
        body.Children.Add(new NoticeView
        {
            Kind = NoticeKind.Info, Margin = new Thickness(0, 12, 0, 0),
            Text = "Тома не трогаются: в них данные баз и проектов. Ненужные тома можно упаковать на диск кнопкой «Архивировать на диск…».",
        });
        Content = body;

        var cancel = new Button { Content = "Отмена", IsCancel = true, Margin = new Thickness(0, 0, 8, 0) };
        cancel.Click += (_, _) => Close();
        prune = new Button { Style = (Style)FindResource("ProminentButton"), IsDefault = true };
        prune.Click += (_, _) =>
        {
            if (targets.Count == 0) return;
            app.Docker.Prune(targets.ToHashSet(), app);
            Close();
        };
        Actions = new StackPanel { Orientation = Orientation.Horizontal, Children = { cancel, prune } };
        Refresh();
    }

    FrameworkElement Row(DockerPruneTarget target, DockerUsage.PartInfo? part)
    {
        var grid = new Grid { Margin = new Thickness(14, 10, 14, 10) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var box = new CheckBox { IsChecked = targets.Contains(target), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 1, 14, 0) };
        box.Click += (_, _) =>
        {
            if (box.IsChecked == true) targets.Add(target);
            else targets.Remove(target);
            Refresh();
        };
        grid.Children.Add(box);

        var text = new StackPanel();
        var title = target == DockerPruneTarget.Containers ? $"{target.Title()} ({Math.Max(0, (part?.Count ?? 0) - (part?.Active ?? 0))})" : target.Title();
        text.Children.Add(new TextBlock { Text = title, Style = (Style)FindResource("Body") });
        text.Children.Add(new TextBlock { Text = Detail(target), Style = (Style)FindResource("Caption"), Margin = new Thickness(0, 2, 0, 0) });
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        var size = new TextBlock
        {
            Text = part is { } p ? Format.Bytes(p.Reclaimable) : "—", Style = (Style)FindResource("Body"), FontWeight = FontWeights.Medium,
            Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Top,
        };
        Grid.SetColumn(size, 2);
        grid.Children.Add(size);
        return grid;
    }

    void Refresh()
    {
        containersWarning.Visibility = targets.Contains(DockerPruneTarget.Containers) ? Visibility.Visible : Visibility.Collapsed;
        prune.Content = targets.Count == 0 ? "Освободить" : $"Освободить около {Format.Bytes(usage.ReclaimableFor(targets))}";
        prune.IsEnabled = targets.Count > 0 && app.Docker.Busy == null;
    }
}
