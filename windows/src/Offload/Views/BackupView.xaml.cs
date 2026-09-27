using System.Windows.Controls;

namespace Offload;

public partial class BackupView : UserControl
{
    readonly AppModel app;

    public BackupView(AppModel app)
    {
        this.app = app;
        InitializeComponent();
        DataContext = app;
    }
}
