using System.Windows.Controls;

namespace Offload;

public partial class SafeView : UserControl
{
    readonly AppModel app;

    public SafeView(AppModel app)
    {
        this.app = app;
        InitializeComponent();
        DataContext = app;
    }
}
