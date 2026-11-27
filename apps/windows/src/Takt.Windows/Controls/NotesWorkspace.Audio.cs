using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using NAudio.Wave;
using Takt.Core.Notes;
using Takt.Windows.Services;
using global::Windows.Storage;
using global::Windows.Storage.Pickers;
using global::Windows.System;
using WinRT.Interop;

namespace Takt.Windows.Controls;

public sealed partial class NotesWorkspace
{
    private sealed record AudioContext(string Workspace, string NoteId, string Title);
    private readonly NoteAudioLibrary audio = new();
    private readonly NoteRecorder recorder = new();
    private readonly DispatcherTimer recordingClock = new() { Interval = TimeSpan.FromSeconds(1) };
    private CancellationTokenSource? transcribing;
    private AudioContext? transcriptionContext;
    private TaskCompletionSource? transcriptionFinished;
    private string? recordingWorkspace, recordingNoteId, recordingTitle;
    public bool IsRecordingPaused => recorder.IsPaused;
    public string RecordingSummary => (recorder.IsPaused ? "Paused" : "Recording") + " · " + recorder.Duration.ToString(@"mm\:ss") + " · " + (string.IsNullOrWhiteSpace(recordingTitle) ? "New note" : recordingTitle);
    public event EventHandler? RecordingChanged;
    public void ToggleRecordingPause()
    {
        recorder.TogglePause(); PauseRecording.Content = recorder.IsPaused ? "Resume" : "Pause";
        RecordingLabel.Text = RecordingSummary; RecordingChanged?.Invoke(this, EventArgs.Empty);
    }
    public Task StopRecordingAndSaveAsync() => SerializeAsync(StopRecordingAsync);
    private async Task StartRecordingAsync(bool call)
    {
        if (recorder.IsRecording) throw new InvalidOperationException("A recording is already running.");
        // Finish cleanup of a device failure before reusing the recorder.
        await StopRecordingAsync();
        await SaveCoreAsync(); if (draft is null) await CreateNoteCoreAsync();
        if (draft!.Document.DeletedAt is not null) throw new InvalidOperationException("Choose an editable note before recording.");
        if (call && !await Confirm("Record system audio and microphone?", "This captures sound from all applications on the current Windows output device, plus your microphone. The recording stays on this device until you explicitly send or export it.", "Start recording")) return;
        recordingWorkspace = library.Workspace; recordingNoteId = draft.Document.Id; recordingTitle = draft.Document.Title;
        recorder.Start(audio.NewPath(recordingWorkspace, recordingNoteId), call);
        RecordingCard.Visibility = Visibility.Visible; RecordingLabel.Text = RecordingSummary; PauseRecording.Content = "Pause";
        RecordNoteButton.IsEnabled = RecordCallButton.IsEnabled = false;
        recordingClock.Tick -= Recording_Tick; recordingClock.Tick += Recording_Tick; recordingClock.Start();
        RecordingChanged?.Invoke(this, EventArgs.Empty);
    }
    private async void Recording_Tick(object? sender, object e)
    {
        RecordingLabel.Text = RecordingSummary; RecordingChanged?.Invoke(this, EventArgs.Empty);
        if (!recorder.IsRecording) await Run(StopRecordingAsync);
    }
    private async Task StopRecordingAsync()
    {
        recordingClock.Stop(); await recorder.StopAsync(); RecordingCard.Visibility = Visibility.Collapsed;
        // Audio remains in the original workspace/note directory even after the
        // user selects another note, switches sections, or opens Tasks.
        if (draft is not null && library.Workspace == recordingWorkspace && draft.Document.Id == recordingNoteId)
            AudioClips.ItemsSource = audio.List(recordingWorkspace, recordingNoteId!);
        recordingWorkspace = recordingNoteId = recordingTitle = null;
        RecordNoteButton.IsEnabled = RecordCallButton.IsEnabled = draft is { Document.DeletedAt: null };
        RecordingChanged?.Invoke(this, EventArgs.Empty);
        if (recorder.Failure is not null) ShowProblem("Recording stopped", "Windows could not continue capturing audio. Any captured audio has been kept. Check microphone privacy settings and the selected devices.");
    }
    private async void RecordVoice_Click(object sender, RoutedEventArgs e) => await Run(() => StartRecordingAsync(false));
    private async void RecordCall_Click(object sender, RoutedEventArgs e) => await Run(() => StartRecordingAsync(true));
    private void PauseRecording_Click(object sender, RoutedEventArgs e) => ToggleRecordingPause();
    private async void StopRecording_Click(object sender, RoutedEventArgs e) => await Run(StopRecordingAsync);
    // Playback/settings/transcription dialogs must not hold the editor gate: a
    // button inside such a dialog can itself save, export, or append a transcript.
    private async Task RunAudioAsync(Func<Task> action)
    {
        try { await action(); }
        catch (OperationCanceledException) { ShowProblem("Transcription paused", "Completed segments and the preview are saved on this device. Choose Transcribe again to resume."); }
        catch (Exception error) { ShowProblem("Audio operation could not finish", error is ArgumentException or InvalidDataException or InvalidOperationException ? error.Message : "Your note, recording and saved transcription progress have been kept."); }
    }
    private async void Audio_ItemClick(object sender, ItemClickEventArgs e) => await RunAudioAsync(async () =>
    {
        if (e.ClickedItem is not NoteAudioClip clip || draft is not { } selected) return;
        var context = new AudioContext(library.Workspace, selected.Document.Id, selected.Document.Title);
        if (!string.Equals(Path.GetDirectoryName(clip.Path), audio.DirectoryFor(context.Workspace, context.NoteId), StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Select the recording again after the note finishes loading.");
        await SaveAsync();
        using var player = new WaveOutEvent(); using var input = new AudioFileReader(clip.Path); player.Init(input);
        var play = new Button { Content = "Play / pause" }; play.Click += async (_, _) => await RunAudioAsync(() => { if (player.PlaybackState == PlaybackState.Playing) player.Pause(); else player.Play(); return Task.CompletedTask; });
        var export = new Button { Content = "Export WAV" }; export.Click += async (_, _) => await RunAudioAsync(async () =>
        {
            var picker = new FileSavePicker { SuggestedFileName = "Takt-recording-" + clip.Id }; picker.FileTypeChoices.Add("WAV recording", new List<string> { ".wav" }); InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(owner));
            if (await picker.PickSaveFileAsync() is { } destination) await FileIO.WriteBytesAsync(destination, await File.ReadAllBytesAsync(clip.Path));
        });
        var reveal = new Button { Content = "Open file location" }; reveal.Click += async (_, _) => await RunAudioAsync(async () =>
        {
            var folder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(clip.Path)!);
            if (!await Launcher.LaunchFolderAsync(folder)) throw new InvalidOperationException("Windows could not open the recordings folder.");
        });
        bool editable = selected.Document.DeletedAt is null;
        var name = new TextBox { Header = "Recording name", Text = clip.Name, MaxLength = 120, IsReadOnly = !editable };
        var rename = new Button { Content = "Rename", IsEnabled = editable };
        rename.Click += async (_, _) => await RunAudioAsync(() => { audio.Rename(clip, name.Text); return Task.CompletedTask; });
        var transcribe = new Button { Content = "Transcribe / resume…" };
        var restart = new Button { Content = "Start a new transcription…" };
        var preview = new Button { Content = "Review saved transcript…", IsEnabled = NoteTranscription.HasPreview(clip) };
        var remove = new CheckBox { Content = "Delete this local recording when closing", IsEnabled = editable };
        var text = new TextBlock { Text = "Audio and saved transcription progress stay on this Windows device. Appending transcript text syncs it with the note.", TextWrapping = TextWrapping.Wrap };
        var panel = new StackPanel { Spacing = 12, Children = { text, name, rename, play, export, reveal, transcribe, preview, restart, remove } };
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Note recording", Content = new ScrollViewer { Content = panel }, CloseButtonText = "Close" };
        bool requested = false, reviewRequested = false, restartRequested = false;
        transcribe.Click += (_, _) => { requested = true; dialog.Hide(); };
        restart.Click += (_, _) => { restartRequested = true; dialog.Hide(); };
        preview.Click += (_, _) => { reviewRequested = true; dialog.Hide(); };
        await dialog.ShowAsync(); player.Stop();
        if (remove.IsChecked == true) audio.Delete(clip);
        else if (restartRequested)
        {
            if (await Confirm("Start a new transcription?", "Clear the saved segment progress for this recording? Its audio and existing transcript preview will be kept. Sending the audio again requires a separate confirmation.", "Clear progress"))
            { NoteTranscription.ResetProgress(clip); await TranscribeAsync(clip, context); }
        }
        else if (requested) await TranscribeAsync(clip, context);
        else if (reviewRequested) await ReviewTranscriptAsync(clip, context);
        if (library.Workspace == context.Workspace && draft?.Document.Id == context.NoteId) AudioClips.ItemsSource = audio.List(context.Workspace, context.NoteId);
    });
    private async Task TranscribeAsync(NoteAudioClip clip, AudioContext context)
    {
        if (transcribing is not null) throw new InvalidOperationException("A transcription is already running.");
        var settings = TranscriptionSettings.Read(); var endpoint = TranscriptionSettings.Address(settings.Endpoint);
        if (string.IsNullOrWhiteSpace(settings.Model)) throw new InvalidOperationException("Choose a model in Transcription settings first.");
        if (!await Confirm("Send recording for transcription?", $"Send unfinished audio segments to {endpoint.Host}, using model {settings.Model}? Completed segments are reused. Audio is sent only after this confirmation; the provider may charge for transcription.", "Send recording")) return;
        using var cancellation = new CancellationTokenSource(); transcribing = cancellation; transcriptionContext = context;
        var finished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); transcriptionFinished = finished;
        try
        {
            while (true)
            {
                var progress = new ProgressBar { IsIndeterminate = true, MinWidth = 260 };
                var status = new TextBlock { Text = "Preparing saved progress…", TextWrapping = TextWrapping.Wrap };
                var running = new ContentDialog { XamlRoot = XamlRoot, Title = "Transcribing recording", Content = new StackPanel { Spacing = 12, Children = { status, progress } }, CloseButtonText = "Pause transcription" };
                running.CloseButtonClick += (_, _) => cancellation.Cancel();
                var shown = running.ShowAsync(); TranscriptionSegmentException? failed = null;
                try
                {
                    await NoteTranscription.TranscribeAsync(clip, settings, cancellation.Token, new Progress<TranscriptionProgress>(p =>
                    {
                        status.Text = $"Segment {p.Current} of {p.Total} · {p.Completed} saved or skipped";
                        progress.IsIndeterminate = false; progress.Maximum = p.Total; progress.Value = p.Completed;
                    }));
                }
                catch (TranscriptionSegmentException error) { failed = error; }
                finally { running.Hide(); await shown; }
                if (failed is null) break;
                var retry = new ContentDialog { XamlRoot = XamlRoot, Title = "Segment could not be transcribed", Content = new TextBlock { Text = failed.Message, TextWrapping = TextWrapping.Wrap }, PrimaryButtonText = "Retry segment", SecondaryButtonText = "Skip segment", CloseButtonText = "Keep saved progress", DefaultButton = ContentDialogButton.Close };
                var choice = await retry.ShowAsync();
                if (choice == ContentDialogResult.None) return;
                if (choice == ContentDialogResult.Secondary) await NoteTranscription.SkipSegmentAsync(clip, settings, failed.Index, cancellation.Token);
            }
        }
        finally { transcribing = null; transcriptionContext = null; transcriptionFinished = null; finished.TrySetResult(); }
        await ReviewTranscriptAsync(clip, context);
    }
    private async Task ReviewTranscriptAsync(NoteAudioClip clip, AudioContext context)
    {
        var review = new TextBox { Text = NoteTranscription.ReadPreview(clip), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 240 };
        var result = new ContentDialog { XamlRoot = XamlRoot, Title = "Review transcript", Content = new ScrollViewer { Content = review }, PrimaryButtonText = "Append to original note", CloseButtonText = "Keep preview" };
        var choice = await result.ShowAsync();
        await NoteTranscription.SavePreviewAsync(clip, review.Text);
        if (choice != ContentDialogResult.Primary || string.IsNullOrWhiteSpace(review.Text)) return;
        await SerializeAsync(async () =>
        {
            if (context.Workspace != library.Workspace) throw new InvalidOperationException("Return to the recording's library before appending its transcript. The edited preview is saved.");
            await SaveCoreAsync(); NoteEditorScroll.IsEnabled = false;
            try
            {
                var original = await store.FindAsync(context.Workspace, context.NoteId) ?? throw new InvalidOperationException("The original note no longer exists. The transcript preview is saved.");
                if (original.Document.IsPurged || original.Document.Expired(NoteDocument.Now) || original.Document.DeletedAt is not null)
                    throw new InvalidOperationException("Restore the original note before appending its transcript. The preview is saved.");
                NoteCodec.Validate(original.Document);
                var normalized = NoteText.NormalizeNewlines(original.Document.Text, original.Document.RichText!);
                string transcript = review.Text.Replace("\r\n", "\n").Replace('\r', '\n');
                var note = original.Document with { Text = normalized.Item1 + (normalized.Item1.Length == 0 ? "" : "\n\n") + transcript, RichText = normalized.Item2, Document = "", UpdatedAt = NoteDocument.Now };
                NoteCodec.Validate(note);
                var saved = await store.SaveAsync(context.Workspace, original.Digest, note);
                if (saved.Document.Id != context.NoteId) { audio.Copy(context.Workspace, context.NoteId, saved.Document.Id); ShowProblem("Both versions kept", "The original note changed during insertion. The transcript was appended to a separate copy."); }
                section = "notes:all"; loading = true; NotesSearch.Text = ""; loading = false;
                await ShowAsync(saved); await RefreshCoreAsync(library); UpdateLayout();
                NoteBody.Document.GetText(TextGetOptions.AllowFinalEop, out string native);
                int end = Math.Max(0, native.Length - 1); NoteBody.Document.Selection.SetRange(end, end);
                NoteBody.Focus(FocusState.Programmatic); NoteBody.Document.Selection.ScrollIntoView(PointOptions.Start);
                Changed?.Invoke(this, EventArgs.Empty);
            }
            finally { NoteEditorScroll.IsEnabled = true; }
        });
    }
    private async void TranscriptionSettings_Click(object sender, RoutedEventArgs e) => await RunAudioAsync(async () =>
    {
        if (transcribing is not null) throw new InvalidOperationException("Pause the current transcription before changing settings.");
        var old = TranscriptionSettings.Read(); var endpoint = new TextBox { Header = "Audio/transcriptions HTTPS endpoint", Text = old.Endpoint, PlaceholderText = "https://provider.example/v1/audio/transcriptions" };
        var model = new TextBox { Header = "Model", Text = old.Model }; var key = new PasswordBox { Header = "API key (leave empty to keep the saved key)" };
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Transcription settings", Content = new StackPanel { Spacing = 12, Children = { endpoint, model, key, error } }, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
        dialog.PrimaryButtonClick += (_, args) =>
        {
            try
            {
                var uri = TranscriptionSettings.Address(endpoint.Text); string? credential = key.Password.Length == 0 && old.Endpoint == uri.AbsoluteUri ? old.Credential : null;
                if (key.Password.Length > 0) credential = new WindowsVault().Seal("transcription:" + uri.AbsoluteUri, key.Password);
                new TranscriptionSettings(uri.AbsoluteUri, model.Text.Trim(), credential).Save(); key.Password = "";
            }
            catch (Exception failure) { error.Text = failure is ArgumentException ? failure.Message : "The settings could not be saved. Check the local configuration directory."; args.Cancel = true; }
        };
        await dialog.ShowAsync(); key.Password = "";
    });
}
