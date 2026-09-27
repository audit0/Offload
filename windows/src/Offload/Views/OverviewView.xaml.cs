using System.Windows.Controls;

namespace Offload;

public partial class OverviewView : UserControl
{
    readonly AppModel app;

    public OverviewView(AppModel app)
    {
        this.app = app;
        InitializeComponent();
        DataContext = app;
    }
}
