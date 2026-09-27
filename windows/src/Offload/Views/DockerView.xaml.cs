using System.Windows.Controls;

namespace Offload;

public partial class DockerView : UserControl
{
    readonly AppModel app;

    public DockerView(AppModel app)
    {
        this.app = app;
        InitializeComponent();
        DataContext = app;
    }
}
