using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace Offload;

public partial class SafeUnlockRow : UserControl
{
    AppModel App => Offload.App.Model;

    public SafeUnlockRow()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            App.Safe.PropertyChanged += Safe_Changed;
            Update();
        };
        Unloaded += (_, _) => App.Safe.PropertyChanged -= Safe_Changed;
    }

    public string Prompt { set => Password.Tag = value; }

    void Safe_Changed(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(SafeModel.Activity) or nameof(SafeModel.UnlockError) or "") Update();
    }

    void Update()
    {
        bool busy = App.Safe.Activity != null;
        Spinner.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        OpenButton.Visibility = busy ? Visibility.Collapsed : Visibility.Visible;
        ErrorRow.Visibility = App.Safe.UnlockError != null ? Visibility.Visible : Visibility.Collapsed;
        ErrorText.Text = App.Safe.UnlockError ?? "";
    }

    void Password_Changed(object sender, RoutedEventArgs e)
    {
        OpenButton.IsEnabled = Password.Password.Length > 0;
        if (Password.Password.Length > 0) App.Safe.UnlockError = null;
    }

    void Password_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) Open();
    }

    void Open_Click(object sender, RoutedEventArgs e) => Open();

    void Open()
    {
        if (Password.Password.Length == 0) return;
        App.Safe.Open(Password.Password, App);
        Password.Clear();
    }

    public void FocusPassword() => Password.Focus();
}
