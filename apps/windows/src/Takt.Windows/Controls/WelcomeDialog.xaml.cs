using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Takt.Windows.Controls;

public sealed partial class WelcomeDialog : ContentDialog
{
    public string? Destination { get; private set; }
    public WelcomeDialog()
    {
        InitializeComponent();
        Opened += (_, _) => Destination = null;
    }
    private void Destination_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string choice } || choice is not ("task" or "note" or "calendar" or "chat")) return;
        Destination = choice;
        Hide();
    }
}
