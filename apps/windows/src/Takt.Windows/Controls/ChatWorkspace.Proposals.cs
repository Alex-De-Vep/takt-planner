using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Globalization;
using System.Text.Json;
using Takt.Core.Assistant;

namespace Takt.Windows.Controls;

public sealed partial class ChatWorkspace
{
    private readonly Dictionary<string, ChatContext> reviewContexts = [];
    private UIElement ProposalCard(ChatMessage message, ChatProposal proposal)
    {
        bool handled = message.Applied?.Contains(proposal.Id, StringComparer.OrdinalIgnoreCase) == true;
        bool dismissed = message.Dismissed?.Contains(proposal.Id, StringComparer.OrdinalIgnoreCase) == true;
        var panel = new StackPanel { Spacing = 8 };
        string kind = proposal.Kind switch { "task" => "New task", "taskEdit" => "Task changes", "note" => "New note", "noteEdit" => "Note changes", "event" => "New event", _ => "Proposal" };
        panel.Children.Add(new TextBlock { Text = kind + (proposal.Title is { } title ? " · " + title : ""), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        if (proposal.Text is { Length: > 0 } text) panel.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, MaxLines = 5, IsTextSelectionEnabled = true });
        if (proposal.Date is { } date) panel.Children.Add(new TextBlock { Text = "Deadline: " + date + (proposal.Time is null ? "" : " · " + proposal.Time) });
        if (proposal.Start is { } start) panel.Children.Add(new TextBlock { Text = "Starts: " + start, TextWrapping = TextWrapping.Wrap });
        if (handled || dismissed)
        {
            panel.Children.Add(new TextBlock
            {
                Text = dismissed ? "Dismissed" : proposalResults.GetValueOrDefault(proposal.Id, "Already handled — check the result in your library"),
                TextWrapping = TextWrapping.Wrap
            });
        }
        else
        {
            var review = new Button { Content = "Review change…", IsEnabled = !IsBusy };
            review.Click += async (_, _) => await Guard(() => RunHistoryAsync((scope, version) => ReviewProposalAsync(message.Id, proposal.Id, scope, version)));
            panel.Children.Add(review);
            if (message.Context is { } original && (original.Task is not null || original.Note is not null || original.Folder is not null))
            {
                var refresh = new Button { Content = "Refresh context…", IsEnabled = !IsBusy };
                refresh.Click += async (_, _) => await Guard(() => RunHistoryAsync((scope, version) => RefreshProposalContextAsync(message.Id, proposal.Id, scope, version)));
                panel.Children.Add(refresh);
            }
            var dismiss = new Button { Content = "Dismiss", IsEnabled = !IsBusy };
            dismiss.Click += async (_, _) => await Guard(() => RunHistoryAsync((_, _) => DismissProposalAsync(message.Id, proposal.Id)));
            panel.Children.Add(dismiss);
        }
        return new Border { Padding = new Thickness(10), CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1), BorderBrush = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"], Child = panel };
    }
    private (ChatMessage Message, ChatProposal Proposal) FindProposal(string messageId, string proposalId)
    {
        var message = thread?.Messages.FirstOrDefault(m => m.Id == messageId) ?? throw new ReviewFailure("This conversation changed. Open the proposal again.");
        var proposal = message.Proposals.FirstOrDefault(p => p.Id == proposalId) ?? throw new ReviewFailure("This proposal is no longer available.");
        if (message.Applied?.Contains(proposalId, StringComparer.OrdinalIgnoreCase) == true) throw new ReviewFailure("This action was already handled. Check its result before creating another proposal.");
        if (message.Dismissed?.Contains(proposalId, StringComparer.OrdinalIgnoreCase) == true)
            throw new ReviewFailure("This proposal was dismissed.");
        return (message, proposal);
    }
    private async Task DismissProposalAsync(string messageId, string proposalId)
    {
        FindProposal(messageId, proposalId);
        var before = thread!;
        thread = before with
        {
            UpdatedAt = DateTimeOffset.UtcNow,
            Messages = before.Messages.Select(message => message.Id == messageId
                ? message with { Dismissed = [..(message.Dismissed ?? []), proposalId] }
                : message).ToArray()
        };
        try { await SaveThreadAsync(); }
        catch { thread = before; throw; }
        reviewContexts.Remove(proposalId);
    }

    private async Task RefreshProposalContextAsync(string messageId, string proposalId, string scope, long version)
    {
        var original = FindProposal(messageId, proposalId);
        var previous = original.Message.Context ?? throw new ReviewFailure("This proposal has no captured context.");
        ChatContext context;
        try { context = await captureContext(previous); }
        catch (InvalidOperationException failure) { throw new ReviewFailure(failure.Message); }
        if (!SameHistoryScope(scope, version)) return;
        if (context.Workspace != scope) throw new ReviewFailure("The library changed while capturing context.");
        if (original.Proposal.Kind == "taskEdit" && context.Task is null ||
            original.Proposal.Kind == "noteEdit" && context.Note is not { Editable: true })
            throw new ReviewFailure("The original item is no longer available to edit.");
        string notice = "Review the generated text with the latest details from the original record.";
        if (previous.Folder is not null && context.Folder is null && original.Proposal.Kind is ("task" or "note"))
            notice += " The original folder is gone. The new item will go to Inbox.";
        var review = new ContentDialog { XamlRoot = XamlRoot, Title = "Review refreshed context", Content = new StackPanel { Spacing = 12, Children = {
            new TextBlock { Text = notice, TextWrapping = TextWrapping.Wrap },
            new TextBox { Text = ContextPreview(context), IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 380 } } }, PrimaryButtonText = "Use for next review", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        activeDialog = review; ContentDialogResult choice;
        try { choice = await review.ShowAsync(); }
        finally { if (ReferenceEquals(activeDialog, review)) activeDialog = null; }
        if (choice != ContentDialogResult.Primary || !SameHistoryScope(scope, version)) return;
        reviewContexts[proposalId] = context; Problem("Context refreshed", "The proposal is ready for another review. Its generated text has not been rewritten.");
    }
    private async Task ReviewProposalAsync(string messageId, string proposalId, string scope, long version)
    {
        var found = FindProposal(messageId, proposalId); var proposal = found.Proposal;
        var context = reviewContexts.GetValueOrDefault(proposalId) ?? found.Message.Context ?? throw new ReviewFailure("This proposal has no captured context.");
        if (context.Workspace != scope) throw new ReviewFailure("Return to this proposal's library before applying it.");
        var title = new TextBox { Header = "Title", Text = proposal.Title ?? "", MaxLength = 16000, TextWrapping = TextWrapping.Wrap };
        var body = new TextBox { Header = "Text", Text = proposal.Text ?? "", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 96, MaxHeight = 220, MaxLength = 128000 };
        var changeTitle = new CheckBox { Content = "Change title", IsChecked = proposal.Kind is "task" or "note" or "event" || proposal.Title is not null };
        var changeText = new CheckBox { Content = "Change text", IsChecked = proposal.Kind is "task" or "note" or "event" || proposal.Text is not null };
        title.IsEnabled = changeTitle.IsChecked == true; body.IsEnabled = changeText.IsChecked == true;
        changeTitle.Click += (_, _) => title.IsEnabled = changeTitle.IsChecked == true;
        changeText.Click += (_, _) => body.IsEnabled = changeText.IsChecked == true;
        var panel = new StackPanel { Spacing = 12, Children = { new TextBlock { Text = "Review every field before applying. Changes target the captured context shown here.", TextWrapping = TextWrapping.Wrap }, new TextBlock { Text = ContextPreview(context), TextWrapping = TextWrapping.Wrap, MaxLines = 8 }, changeTitle, title, changeText, body } };
        var subtasks = new TextBox { Header = "Subtasks (one per line)", Text = string.Join("\n", proposal.Subtasks ?? []), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 64, MaxHeight = 160, MaxLength = 32000 };
        var changeSubtasks = new CheckBox { Content = "Add subtasks", IsChecked = proposal.Subtasks is not null };
        var deadline = new CalendarDatePicker { Header = "Deadline date", Date = ParseDay(proposal.Date) };
        var includeTime = new CheckBox { Content = "Include deadline time", IsChecked = proposal.Time is not null };
        var time = new TimePicker { Header = "Deadline time", SelectedTime = ParseTime(proposal.Time), IsEnabled = proposal.Time is not null };
        includeTime.Click += (_, _) => time.IsEnabled = includeTime.IsChecked == true;
        var clearDate = new CheckBox { Content = "Remove deadline", IsChecked = proposal.ClearDate == true };
        var today = new CheckBox { Content = "Today plan (mixed means keep current value)", IsThreeState = true, IsChecked = proposal.Today };
        var completed = new CheckBox { Content = "Completed (mixed means keep current value)", IsThreeState = true, IsChecked = proposal.Completed };
        if (proposal.Kind is "task" or "taskEdit")
        {
            foreach (var item in new UIElement[] { changeSubtasks, subtasks, deadline, includeTime, time, clearDate, new TextBlock { Text = "Deadlines do not change Today, This Week or Month plans.", TextWrapping = TextWrapping.Wrap }, today, completed }) panel.Children.Add(item);
        }
        var noteMode = new ComboBox { Header = "How to apply text", ItemsSource = new[] { "Append to note", "Replace note text" }, SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        if (proposal.Kind == "noteEdit")
        {
            panel.Children.Add(noteMode);
            panel.Children.Add(new TextBlock { Text = "Append keeps the existing text, formatting and images. Replace changes the text and its formatting; existing images are kept at the end.", TextWrapping = TextWrapping.Wrap });
        }
        bool eventProposal = proposal.Kind == "event";
        var startDay = new CalendarDatePicker { Header = "Start date", Date = ParseEventDay(proposal.Start) };
        var endDay = new CalendarDatePicker { Header = "End date", Date = ParseEventDay(proposal.End) };
        var startTime = new TimePicker { Header = "Start time", SelectedTime = ParseEventTime(proposal.Start) };
        var endTime = new TimePicker { Header = "End time", SelectedTime = ParseEventTime(proposal.End) };
        var allDay = new CheckBox { Content = "All-day event", IsChecked = proposal.AllDay == true };
        var location = new TextBox { Header = "Location", Text = proposal.Location ?? "", MaxLength = 16000 };
        if (eventProposal)
        {
            startTime.IsEnabled = endTime.IsEnabled = proposal.AllDay != true;
            allDay.Click += (_, _) => startTime.IsEnabled = endTime.IsEnabled = allDay.IsChecked != true;
            foreach (var item in new UIElement[] { allDay, startDay, startTime, endDay, endTime, location, new TextBlock { Text = "Times use the captured local time zone: " + context.TimeZone, TextWrapping = TextWrapping.Wrap } }) panel.Children.Add(item);
        }
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap }; panel.Children.Add(error);
        ChatProposal? edited = null;
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Review proposed change", Content = new ScrollViewer { Content = panel, MaxHeight = 620 }, PrimaryButtonText = "Apply change", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        dialog.PrimaryButtonClick += (_, args) =>
        {
            try
            {
                bool task = proposal.Kind is "task" or "taskEdit";
                edited = proposal with
                {
                    Title = changeTitle.IsChecked == true ? title.Text.Trim() : null, Text = changeText.IsChecked == true ? body.Text : null,
                    Subtasks = task && changeSubtasks.IsChecked == true ? subtasks.Text.Split('\n').Select(t => t.Trim()).Where(t => t.Length > 0).ToArray() : null,
                    Date = task && clearDate.IsChecked != true ? deadline.Date?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) : null,
                    Time = task && clearDate.IsChecked != true && includeTime.IsChecked == true ? time.SelectedTime?.ToString(@"hh\:mm", CultureInfo.InvariantCulture) : null,
                    ClearDate = task && clearDate.IsChecked == true ? true : null, Today = task ? today.IsChecked : null, Completed = task ? completed.IsChecked : null,
                    Start = eventProposal ? EventValue(startDay.Date, startTime.SelectedTime, allDay.IsChecked == true) : null,
                    End = eventProposal ? EventValue(endDay.Date, endTime.SelectedTime, allDay.IsChecked == true) : null,
                    AllDay = eventProposal ? allDay.IsChecked == true : null, Location = eventProposal ? location.Text.Trim() : null
                };
                ChatRules.Proposal(edited, context);
                if (task && includeTime.IsChecked == true && clearDate.IsChecked != true && time.SelectedTime is null) throw new InvalidDataException("Choose a deadline time or turn off Include deadline time.");
                ChatRules.Text(ReviewAudit(edited), ChatRules.MaxTextBytes);
                if (!SameHistoryScope(scope, version)) throw new ReviewFailure("The library changed. Open this proposal again.");
            }
            catch (Exception failure) { args.Cancel = true; error.Text = failure is ReviewFailure or InvalidDataException or ArgumentException ? failure.Message : "Check the proposed dates and fields."; }
        };
        activeDialog = dialog; ContentDialogResult choice;
        try { choice = await dialog.ShowAsync(); }
        finally { if (ReferenceEquals(activeDialog, dialog)) activeDialog = null; }
        if (choice != ContentDialogResult.Primary || edited is null) return;
        if (!SameHistoryScope(scope, version)) return;
        var finished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); applying = finished.Task; UpdateControls(); RenderMessages();
        try
        {
            FindProposal(messageId, proposalId);
            // Keep generated messages immutable. The review records the actual
            // edited fields/context as audit text, without a second executable card.
            var audit = new ChatMessage(Guid.NewGuid().ToString("D"), "user", ReviewAudit(edited), DateTimeOffset.UtcNow, [], context);
            thread = thread! with { Messages = [..thread.Messages, audit], UpdatedAt = DateTimeOffset.UtcNow };
            await SaveThreadAsync();
            if (!SameHistoryScope(scope, version)) return;
            string status;
            try { status = await applyProposal(edited, context, proposal.Kind == "noteEdit" ? noteMode.SelectedIndex == 0 ? "append" : "replace" : "apply"); }
            catch (Exception failure) when (failure is ArgumentException or InvalidOperationException or InvalidDataException or FormatException or OverflowException)
            { throw new ReviewFailure(failure.Message + " Refresh context and review the generated text before trying again."); }
            catch
            {
                MarkHandled(messageId, proposalId, "Check result — the operation could not be confirmed"); await SaveThreadAsync();
                throw new ReviewFailure("The operation's result is uncertain. Check your library before creating another proposal; this card is disabled to avoid duplicates.");
            }
            MarkHandled(messageId, proposalId, status); await SaveThreadAsync(); Changed?.Invoke(this, EventArgs.Empty);
        }
        finally { applying = null; try { UpdateControls(); RenderMessages(); } finally { finished.TrySetResult(); } }
    }
    private static string ReviewAudit(ChatProposal proposal) => "Reviewed change for application:\n" + JsonSerializer.Serialize(new
    {
        proposal.Kind, proposal.Title, proposal.Text, proposal.Subtasks, proposal.Date, proposal.Time, proposal.ClearDate, proposal.Today,
        proposal.Completed, proposal.Start, proposal.End, proposal.AllDay, proposal.Location
    }, new JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
    private void MarkHandled(string messageId, string proposalId, string status)
    {
        proposalResults[proposalId] = status;
        thread = thread! with { Messages = thread.Messages.Select(m => m.Id == messageId ? m with { Applied = (m.Applied ?? []).Append(proposalId).Distinct(StringComparer.OrdinalIgnoreCase).ToArray() } : m).ToArray(), UpdatedAt = DateTimeOffset.UtcNow };
    }
    private static DateTimeOffset? ParseDay(string? value) => DateOnly.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var day) ? new DateTimeOffset(day.ToDateTime(TimeOnly.MinValue)) : null;
    private static TimeSpan? ParseTime(string? value) => TimeOnly.TryParseExact(value, "HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out var time) ? time.ToTimeSpan() : null;
    private static DateTimeOffset? ParseEventDay(string? value) => value is { Length: >= 10 } ? ParseDay(value[..10]) : null;
    private static TimeSpan? ParseEventTime(string? value) => value is { Length: >= 16 } ? ParseTime(value[11..16]) : null;
    private static string? EventValue(DateTimeOffset? day, TimeSpan? time, bool allDay)
    {
        if (day is null) return null;
        if (allDay) return day.Value.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        if (time is null) throw new InvalidDataException("Choose a time for the event.");
        return day.Value.Date.Add(time.Value).ToString("yyyy-MM-dd'T'HH:mm", CultureInfo.InvariantCulture);
    }
}
