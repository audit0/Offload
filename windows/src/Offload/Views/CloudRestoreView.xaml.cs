using System.Windows.Controls;

namespace Offload;

public partial class CloudRestoreView : UserControl
{
    readonly AppModel app;

    public CloudRestoreView(AppModel app)
    {
        this.app = app;
        InitializeComponent();
        DataContext = app;
    }
}
