using System.Windows.Controls;

namespace Offload;

public partial class SpaceView : UserControl
{
    readonly AppModel app;

    public SpaceView(AppModel app)
    {
        this.app = app;
        InitializeComponent();
        DataContext = app;
    }
}
