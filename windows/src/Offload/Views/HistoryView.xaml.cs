using System.Windows.Controls;

namespace Offload;

public partial class HistoryView : UserControl
{
    readonly AppModel app;

    public HistoryView(AppModel app)
    {
        this.app = app;
        InitializeComponent();
        DataContext = app;
    }
}
