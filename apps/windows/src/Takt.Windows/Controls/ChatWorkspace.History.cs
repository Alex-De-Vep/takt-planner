using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Takt.Core.Assistant;

namespace Takt.Windows.Controls;

public sealed partial class ChatWorkspace
{
    // Own the entire history transition, including dialogs. Generation must not
    // replace its global thread while an older async history load is finishing.
    private async Task RunHistoryAsync(Func<string, long, Task> action)
    {
        if (IsBusy) return;
        string scope = workspace; long version = workspaceVersion; historyStopVersion = stopVersion;
        var finished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        historyOperation = finished.Task; UpdateControls(); RenderMessages();
        try { await action(scope, version); }
        finally
        {
            historyOperation = null;
            try { UpdateControls(); RenderMessages(); }
            finally { finished.TrySetResult(); }
        }
    }
    private bool SameHistoryScope(string scope, long version) => workspace == scope && workspaceVersion == version && stopVersion == historyStopVersion;
    private async void NewChat_Click(object sender, RoutedEventArgs e) => await Guard(() => RunHistoryAsync(async (scope, version) =>
    {
        await SaveThreadAsync(); if (!SameHistoryScope(scope, version)) return;
        thread = NewThread(); proposalResults.Clear(); reviewContexts.Clear(); Prompt.Text = "";
    }));
    private async Task<bool> ConfirmAsync(string title, string message, string primary)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = title, Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap }, PrimaryButtonText = primary,
            CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
        };
        activeDialog = dialog;
        try { return await dialog.ShowAsync() == ContentDialogResult.Primary; }
        finally { if (ReferenceEquals(activeDialog, dialog)) activeDialog = null; }
    }
    private async void History_Click(object sender, RoutedEventArgs e) => await Guard(() => RunHistoryAsync(async (scope, version) =>
    {
        await SaveThreadAsync(); if (!SameHistoryScope(scope, version)) return;
        var history = await store.ListAsync(scope); if (!SameHistoryScope(scope, version)) return;
        var list = new ListView { ItemsSource = history, DisplayMemberPath = "Title", SelectionMode = ListViewSelectionMode.Single, MinWidth = 280, MaxHeight = 380 };
        list.SelectedItem = history.FirstOrDefault(t => t.Id == thread?.Id);
        var clear = new Button { Content = "Clear this library's chat history", HorizontalAlignment = HorizontalAlignment.Left };
        bool clearRequested = false;
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Conversation history", Content = new StackPanel { Spacing = 12, Children = { list, clear } }, PrimaryButtonText = "Open", SecondaryButtonText = "Delete selected", CloseButtonText = "Close" };
        clear.Click += (_, _) => { clearRequested = true; dialog.Hide(); };
        activeDialog = dialog; ContentDialogResult choice;
        try { choice = await dialog.ShowAsync(); }
        finally { if (ReferenceEquals(activeDialog, dialog)) activeDialog = null; }
        if (!SameHistoryScope(scope, version)) return;
        if (clearRequested)
        {
            if (!await ConfirmAsync("Clear chat history?", "Remove every conversation in this library from this Windows device? Tasks, notes and events are kept.", "Clear history") || !SameHistoryScope(scope, version)) return;
            await store.ClearAsync(scope); if (workspace != scope || workspaceVersion != version) return;
            thread = NewThread();
        }
        else if (list.SelectedItem is ChatThread selected)
        {
            if (choice == ContentDialogResult.Primary)
            {
                await SaveThreadAsync(); if (!SameHistoryScope(scope, version)) return;
                thread = selected;
            }
            else if (choice == ContentDialogResult.Secondary)
            {
                if (!await ConfirmAsync("Delete this conversation?", "Remove this conversation from this Windows device? Its tasks, notes and events are kept.", "Delete conversation") || !SameHistoryScope(scope, version)) return;
                await store.DeleteAsync(scope, selected.Id); if (workspace != scope || workspaceVersion != version) return;
                if (thread?.Id == selected.Id) thread = NewThread();
            }
        }
        proposalResults.Clear(); reviewContexts.Clear();
    }));
}
