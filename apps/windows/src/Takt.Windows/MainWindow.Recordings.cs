using Microsoft.UI.Xaml;

namespace Takt.Windows;

public sealed partial class MainWindow
{
    private void UpdateGlobalRecording()
    {
        GlobalRecording.Visibility = NotesView.IsRecording ? Visibility.Visible : Visibility.Collapsed;
        GlobalRecordingStatus.Text = NotesView.RecordingSummary;
        GlobalRecordingPause.Content = NotesView.IsRecordingPaused ? "Resume" : "Pause";
    }
    private void GlobalRecordingPause_Click(object sender, RoutedEventArgs e)
    { NotesView.ToggleRecordingPause(); UpdateGlobalRecording(); }
    private async void GlobalRecordingStop_Click(object sender, RoutedEventArgs e) => await Guard(async () =>
    { await NotesView.StopRecordingAndSaveAsync(); UpdateGlobalRecording(); });
}
