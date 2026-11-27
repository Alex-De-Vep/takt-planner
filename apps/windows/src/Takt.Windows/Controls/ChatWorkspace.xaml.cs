using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using System.Text;
using System.Text.Json;
using Takt.Core.Assistant;
using Takt.Windows.Services;
using global::Windows.System;
using global::Windows.ApplicationModel.DataTransfer;
using global::Windows.UI.Core;

namespace Takt.Windows.Controls;

public sealed partial class ChatWorkspace : UserControl
{
    private readonly SemaphoreSlim stateGate = new(1, 1);
    private readonly ChatClient client = new(ChatClient.CreateHttpClient());
    private ChatStore store = null!;
    private string directory = "", workspace = "local";
    private ChatSettings settings = ChatSettings.Empty;
    private ChatThread? thread;
    private Func<ChatContext?, Task<ChatContext>> captureContext = null!;
    private Func<ChatProposal, ChatContext, string, Task<string>> applyProposal = null!;
    private CancellationTokenSource? cancellation;
    private Task? generation, applying, settingsRequest, historyOperation, settingsOperation;
    private CancellationTokenSource? settingsCancellation;
    private ContentDialog? activeDialog;
    private long workspaceVersion, requestVersion, stopVersion, historyStopVersion;
    private bool refreshingPickers, loadingWorkspace;
    private readonly Dictionary<string, string> proposalResults = [];
    private readonly Dictionary<string, TextBlock> messageTexts = [];
    public bool IsBusy => generation is { IsCompleted: false } || applying is { IsCompleted: false } || settingsRequest is { IsCompleted: false } || historyOperation is { IsCompleted: false } || settingsOperation is { IsCompleted: false } || loadingWorkspace;
    public event EventHandler? Changed;
    private sealed class InlineProgress<T>(Action<T> callback) : IProgress<T> { public void Report(T value) => callback(value); }
    private sealed class ReviewFailure(string message) : Exception(message);
    public ChatWorkspace() { InitializeComponent(); }
    public void Initialize(string directory, Window owner, Func<ChatContext?, Task<ChatContext>> captureContext, Func<ChatProposal, ChatContext, string, Task<string>> applyProposal)
    {
        if (store is not null) throw new InvalidOperationException("The chat workspace is already initialized.");
        this.directory = directory; this.captureContext = captureContext; this.applyProposal = applyProposal;
        store = new ChatStore(Path.Combine(directory, "assistant.db"));
        try { settings = ChatSettings.Read(directory); }
        catch (Exception) { Problem("Connections unavailable", "The saved connection settings could not be read. Open connection settings to add a new connection."); }
        RefreshPickers(); RenderMessages(); UpdateControls();
    }
    public async Task OpenWorkspaceAsync(string next)
    {
        if (workspace == next && thread?.Workspace == next) return;
        await StopAsync();
        await stateGate.WaitAsync();
        try
        {
            // Concurrent reloads may have opened this scope while this call waited.
            if (workspace == next && thread?.Workspace == next) return;
            loadingWorkspace = true; UpdateControls();
            workspace = next; ++workspaceVersion; thread = null; proposalResults.Clear(); reviewContexts.Clear(); Prompt.Text = "";
            RenderMessages();
            IncludeFolder.IsChecked = IncludeTask.IsChecked = IncludeNote.IsChecked = false;
            var history = await store.ListAsync(workspace);
            thread = history.FirstOrDefault() ?? NewThread(); RenderMessages(); UpdateControls();
        }
        finally { loadingWorkspace = false; try { UpdateControls(); RenderMessages(); } finally { stateGate.Release(); } }
    }
    public void Stop() { ++stopVersion; cancellation?.Cancel(); settingsCancellation?.Cancel(); activeDialog?.Hide(); }
    public async Task StopAsync()
    {
        Stop(); var reply = generation; var edit = applying; var catalog = settingsRequest; var history = historyOperation; var settingsDialog = settingsOperation;
        if (reply is not null) await reply;
        if (edit is not null) await edit;
        if (catalog is not null) await catalog;
        if (history is not null) await history;
        if (settingsDialog is not null) await settingsDialog;
        await SaveThreadAsync();
    }
    private ChatThread NewThread() => new(Guid.NewGuid().ToString("D"), workspace, "New conversation", DateTimeOffset.UtcNow, []);
    private async Task SaveThreadAsync()
    {
        var snapshot = thread; if (snapshot is null || snapshot.Messages.Length == 0 || store is null) return;
        await stateGate.WaitAsync();
        try { await store.SaveAsync(snapshot); }
        finally { stateGate.Release(); }
    }
    private void Problem(string title, string message) { ChatProblem.Title = title; ChatProblem.Message = message; ChatProblem.IsOpen = true; }
    private async Task Guard(Func<Task> action)
    {
        try { await action(); }
        catch (Exception error) { Problem("Chat action could not finish", error is ReviewFailure ? error.Message : "Your conversation was kept. Check the connection or local storage and try again."); }
    }
    private void UpdateControls()
    {
        bool busy = IsBusy;
        NewChatButton.IsEnabled = HistoryButton.IsEnabled = ChatSettingsButton.IsEnabled = !busy;
        ConnectionPicker.IsEnabled = ModelPicker.IsEnabled = IncludeFolder.IsEnabled = IncludeTask.IsEnabled = IncludeNote.IsEnabled = !busy;
        Prompt.IsReadOnly = busy;
        SendButton.Content = generation is { IsCompleted: false } ? "Stop" : applying is { IsCompleted: false } ? "Applying…" : "Send";
        SendButton.IsEnabled = !loadingWorkspace && settingsRequest is not { IsCompleted: false } && applying is not { IsCompleted: false } && historyOperation is not { IsCompleted: false } && settingsOperation is not { IsCompleted: false };
        ConversationTitle.Text = thread?.Title ?? "New conversation";
    }
    private void RefreshPickers()
    {
        refreshingPickers = true;
        try
        {
            ConnectionPicker.ItemsSource = settings.Connections;
            var selected = settings.Connections.FirstOrDefault(c => c.Id == settings.SelectedConnection) ?? settings.Connections.FirstOrDefault();
            ConnectionPicker.SelectedItem = selected;
            ModelPicker.ItemsSource = selected?.Models ?? [];
            ModelPicker.SelectedItem = selected?.Models.FirstOrDefault(m => m == settings.SelectedModel) ?? selected?.Models.FirstOrDefault();
        }
        finally { refreshingPickers = false; }
    }
    private void Connection_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (refreshingPickers || directory.Length == 0) return;
        if (ConnectionPicker.SelectedItem is not SavedChatConnection item) return;
        settings = settings with { SelectedConnection = item.Id, SelectedModel = item.Models.FirstOrDefault() };
        try { settings.Save(directory); RefreshPickers(); }
        catch (Exception) { Problem("Selection not saved", "The connection can be used now, but its selection could not be saved on this device."); }
    }
    private void Model_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (refreshingPickers || directory.Length == 0 || ModelPicker.SelectedItem is not string model) return;
        settings = settings with { SelectedModel = model };
        try { settings.Save(directory); }
        catch (Exception) { Problem("Selection not saved", "The model selection could not be saved on this device."); }
    }
    private async void Send_Click(object sender, RoutedEventArgs e)
    {
        if (generation is { IsCompleted: false }) { Stop(); return; }
        if (IsBusy) return;
        var finished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); generation = finished.Task;
        using var stop = new CancellationTokenSource(); cancellation = stop; UpdateControls();
        try { await GenerateAsync(stop.Token); }
        catch (OperationCanceledException) { Problem("Generation stopped", "Any partial reply has been saved in this conversation."); }
        catch (Exception error) { Problem("Reply could not finish", error is ReviewFailure ? error.Message : "Check the endpoint, model and provider access. Your conversation and any partial reply have been kept."); }
        finally { cancellation = null; generation = null; activeDialog = null; try { UpdateControls(); RenderMessages(); } finally { finished.TrySetResult(); } }
    }
    private async Task GenerateAsync(CancellationToken ct)
    {
        string prompt = Prompt.Text.Trim(); if (prompt.Length == 0) return;
        if (ConnectionPicker.SelectedItem is not SavedChatConnection saved || ModelPicker.SelectedItem is not string model)
            throw new ReviewFailure("Connect a provider and select a model before sending a message.");
        string scope = workspace; long version = workspaceVersion;
        var connection = saved.Connection with { Model = model };
        var captured = await captureContext(null); ct.ThrowIfCancellationRequested();
        if (version != workspaceVersion || captured.Workspace != scope) throw new ReviewFailure("The library changed. Review the context and send again.");
        var context = captured with { Folder = IncludeFolder.IsChecked == true ? captured.Folder : null, Task = IncludeTask.IsChecked == true ? captured.Task : null, Note = IncludeNote.IsChecked == true ? captured.Note : null };
        var preview = new TextBox { Text = ContextPreview(context), IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 380, MinWidth = 280 };
        activeDialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Review what will be sent", Content = new StackPanel { Spacing = 12, Children = { new TextBlock { Text = $"Send your message and this conversation's history to {ChatClient.Address(connection.Address).Host} with model {model}? Attached context is shown below.", TextWrapping = TextWrapping.Wrap }, preview } }, PrimaryButtonText = "Send message", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        var consent = await activeDialog.ShowAsync(); activeDialog = null;
        if (consent != ContentDialogResult.Primary) return;
        ct.ThrowIfCancellationRequested();
        if (scope != workspace || version != workspaceVersion) throw new ReviewFailure("The library changed before sending. Review your message again.");
        thread ??= NewThread();
        if (thread.Workspace != scope) throw new ReviewFailure("Wait for this library’s conversation to finish loading.");
        if (thread.Messages.Length >= 128) throw new ReviewFailure("Start a new conversation to continue. This conversation has reached its 128-message request limit.");
        var before = thread;
        var user = new ChatMessage(Guid.NewGuid().ToString("D"), "user", prompt, DateTimeOffset.UtcNow, [], context);
        thread = thread with { Title = thread.Messages.Length == 0 ? string.Concat(prompt.EnumerateRunes().Take(60).Select(r => r.ToString())).Replace('\n', ' ').Replace('\r', ' ') : thread.Title, Messages = [..thread.Messages, user], UpdatedAt = DateTimeOffset.UtcNow };
        try { await SaveThreadAsync(); }
        catch { thread = before; throw; }
        Prompt.Text = "";
        string assistantId = Guid.NewGuid().ToString("D"), partial = "";
        var requestHistory = thread.Messages;
        thread = thread with { Messages = [..thread.Messages, new ChatMessage(assistantId, "assistant", "", DateTimeOffset.UtcNow, [], context)] };
        RenderMessages(); long request = ++requestVersion; ChatReply? reply = null;
        try
        {
            reply = await client.CompleteAsync(connection, await ConnectionKeyAsync(saved, ct), requestHistory, context, ct, new InlineProgress<string>(value =>
            {
                Volatile.Write(ref partial, value);
                DispatcherQueue.TryEnqueue(() =>
                {
                if (requestVersion != request || workspace != scope) return;
                bool follow = ConversationScroll.VerticalOffset >= ConversationScroll.ScrollableHeight - 48;
                if (messageTexts.TryGetValue(assistantId, out var text)) text.Text = partial.Length == 0 ? "Thinking…" : partial;
                if (follow) ConversationScroll.ChangeView(null, ConversationScroll.ScrollableHeight, null, true);
                });
            }));
        }
        finally
        {
            ++requestVersion;
            var message = new ChatMessage(assistantId, "assistant", reply?.Text ?? (partial.Length > 0 ? Encoding.UTF8.GetString(Encoding.UTF8.GetBytes(Volatile.Read(ref partial))) : "Reply stopped before text was received."), DateTimeOffset.UtcNow, reply?.Proposals ?? [], context);
            thread = thread with { Messages = thread.Messages.Select(m => m.Id == assistantId ? message : m).ToArray(), UpdatedAt = DateTimeOffset.UtcNow };
            await SaveThreadAsync(); RenderMessages();
        }
    }
    private static string ContextPreview(ChatContext context)
    {
        StringBuilder text = new(); text.AppendLine($"Today: {context.Today:yyyy-MM-dd} · Time zone: {context.TimeZone}");
        if (context.Folder is { } folder) text.AppendLine("\nFolder: " + folder.Name);
        if (context.Task is { } task)
        {
            text.AppendLine("\nTask: " + task.Title); text.AppendLine(task.Text);
            foreach (var child in task.Checklist) text.AppendLine((child.Completed ? "☑ " : "☐ ") + child.Title);
            text.AppendLine($"Today plan: {(task.Focused ? "Yes" : "No")} · Completed: {(task.Completed ? "Yes" : "No")}");
            if (task.Deadline is not null) { var parts = task.Deadline.LocalParts(); text.AppendLine("Deadline: " + parts.Date.ToString("d", System.Globalization.CultureInfo.CurrentCulture) + (parts.Time is { } time ? " · " + time.ToString("t", System.Globalization.CultureInfo.CurrentCulture) : "")); }
        }
        if (context.Note is { } note) { text.AppendLine("\nNote: " + note.Title); text.AppendLine(note.Text); text.AppendLine(note.Editable ? "Note edits: available after review" : "Note edits: unavailable"); if (note.Truncated) text.AppendLine("[Only the displayed excerpt is attached.]"); }
        if (context.Folder is null && context.Task is null && context.Note is null) text.AppendLine("\nNo folder, task or note is attached.");
        return text.ToString();
    }
    private void Prompt_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter && (Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control) & CoreVirtualKeyStates.Down) != 0)
        { e.Handled = true; Send_Click(SendButton, new RoutedEventArgs()); }
    }
    private void RenderMessages()
    {
        MessagePanel.Children.Clear(); messageTexts.Clear();
        if (thread is null || thread.Messages.Length == 0)
        {
            MessagePanel.Children.Add(new TextBlock { Text = "Plan tasks, draft notes, or prepare events. Connect your provider to begin. Proposed changes are applied only after your review.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(8, 20, 8, 0) }); return;
        }
        foreach (var message in thread.Messages)
        {
            var body = new TextBlock { Text = message.Text.Length == 0 ? "Thinking…" : message.Text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
            messageTexts[message.Id] = body;
            var panel = new StackPanel { Spacing = 8 };
            panel.Children.Add(new TextBlock { Text = message.Role == "user" ? "You" : "Assistant", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }); panel.Children.Add(body);
            if (message.Context is { } attached && (attached.Task is not null || attached.Note is not null || attached.Folder is not null))
            {
                var context = new Button { Content = "View attached context", HorizontalAlignment = HorizontalAlignment.Left };
                context.Click += async (_, _) => await Guard(() => ShowContextAsync(attached)); panel.Children.Add(context);
            }
            foreach (var proposal in message.Proposals) panel.Children.Add(ProposalCard(message, proposal));
            var copy = new Button { Content = new SymbolIcon(Symbol.Copy), HorizontalAlignment = HorizontalAlignment.Right, IsEnabled = message.Text.Length > 0 };
            ToolTipService.SetToolTip(copy, "Copy full message text");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(copy, "Copy full message text");
            copy.Click += async (_, _) => await Guard(() =>
            {
                var data = new DataPackage(); data.SetText(message.Text); Clipboard.SetContent(data); return Task.CompletedTask;
            });
            panel.Children.Add(copy);
            MessagePanel.Children.Add(new Border { Padding = new Thickness(12), CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), BorderBrush = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"], Child = panel });
        }
        ConversationTitle.Text = thread.Title;
    }
    private Task ShowContextAsync(ChatContext context) => RunHistoryAsync(async (scope, version) =>
    {
        if (context.Workspace != scope || !SameHistoryScope(scope, version)) return;
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Attached context", Content = new TextBox { Text = ContextPreview(context), AcceptsReturn = true, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 420 }, CloseButtonText = "Close" };
        activeDialog = dialog;
        try { await dialog.ShowAsync(); }
        finally { if (ReferenceEquals(activeDialog, dialog)) activeDialog = null; }
    });
}
