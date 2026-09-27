using System.Windows.Controls;

namespace Offload;

public partial class CleanupView : UserControl
{
    readonly AppModel app;

    public CleanupView(AppModel app)
    {
        this.app = app;
        InitializeComponent();
        DataContext = app;
    }
}
