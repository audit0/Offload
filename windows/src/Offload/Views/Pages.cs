using System.Windows;
using System.Windows.Controls;

namespace Offload;

/// <summary>Страницы разделов. Каждая создаётся при первом открытии и дальше живёт вместе с окном.</summary>
public static class Pages
{
    public static FrameworkElement Create(SidebarSection section, AppModel app) => section switch
    {
        SidebarSection.Overview => new OverviewView(app),
        SidebarSection.Cleanup => new CleanupView(app),
        SidebarSection.Assistant => new AssistantView(app),
        SidebarSection.Safe => new SafeView(app),
        SidebarSection.Space => new SpaceView(app),
        SidebarSection.History => new HistoryView(app),
        SidebarSection.Backup => new BackupView(app),
        SidebarSection.ICloud => new CloudRestoreView(app),
        _ => new DockerView(app),
    };

    /// <summary>Страница-колонка: прокрутка, поля и предельная ширина, по центру окна.</summary>
    public static ScrollViewer Scroll(UIElement content) => new()
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        Focusable = false,
        Content = new Border
        {
            Padding = new Thickness(Theme.PagePadding),
            MaxWidth = Theme.ContentWidth + Theme.PagePadding * 2,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Child = content,
        },
    };
}
