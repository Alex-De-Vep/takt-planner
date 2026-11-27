using Microsoft.UI.Xaml;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Takt.Core.Assistant;
using Takt.Core.Calendar;
using Takt.Core.Models;
using Takt.Core.Notes;
using Takt.Core.Storage;
using Takt.Windows.Services;

namespace Takt.Windows;

public sealed partial class MainWindow
{
    private bool chatVisible;
    private string? chatWorkspace;
    private readonly SemaphoreSlim proposalGate = new(1, 1);

    private void UpdateSidePanelVisibility()
    {
        bool visible = calendarVisible || chatVisible;
        if (calendarVisible) panelWidth = Math.Max(336, panelWidth);
        CalendarView.Visibility = calendarVisible ? Visibility.Visible : Visibility.Collapsed;
        ChatView.Visibility = chatVisible ? Visibility.Visible : Visibility.Collapsed;
        PanelResize.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        PanelSplitterColumn.Width = new(visible ? 16 : 0);
        RightPanelColumn.Width = new(visible ? panelWidth : 0);
        CalendarToggle.IsChecked = calendarVisible; ChatToggle.IsChecked = chatVisible;
        AdjustLayout();
    }
    private async void ChatToggle_Click(object sender, RoutedEventArgs e) => await Guard(async () =>
    {
        if (!ready) { ChatToggle.IsChecked = false; return; }
        chatVisible = ChatToggle.IsChecked == true;
        if (chatVisible) calendarVisible = false;
        UpdateSidePanelVisibility();
        if (chatVisible) await RefreshChatWorkspaceAsync();
    });
    private async Task RefreshChatWorkspaceAsync()
    {
        if (chatWorkspace == library.Workspace) return;
        if (!chatVisible && chatWorkspace is null) return;
        for (int attempt = 0; attempt < 3; ++attempt)
        {
            string scope = library.Workspace;
            await ChatView.OpenWorkspaceAsync(scope);
            if (scope == library.Workspace) { chatWorkspace = scope; return; }
        }
        chatWorkspace = null; ChatView.Stop();
        throw new InvalidOperationException("The library changed while opening chat. Open the chat panel again.");
    }
    private async Task<ChatContext> CaptureChatContextAsync(ChatContext? previous)
    {
        await SaveEditorAsync();
        var current = await store.ReadAsync();
        if (current.Workspace != library.Workspace) throw new InvalidOperationException("The active library changed. Open the document again before attaching context.");
        if (previous is not null && previous.Workspace != current.Workspace)
            throw new InvalidOperationException("Return to the original library before refreshing this proposal.");
        string? folderId = previous is null ? section : previous.Folder?.Id;
        string? taskId = previous is null ? (showingNotes ? null : draft?.Id) : previous.Task?.Id;
        string? noteId = previous is null ? (showingNotes ? NotesView.SelectedNoteId : null) : previous.Note?.Id;
        var selectedFolder = current.Folders.FirstOrDefault(value => value.Id == folderId);
        ChatFolderContext? folder = selectedFolder is null ? null : new(selectedFolder.Id, selectedFolder.Text("name") ?? "Folder");
        ChatTaskContext? task = null;
        ChatNoteContext? note = null;
        if (taskId is not null && current.Tasks.FirstOrDefault(value => value.Id == taskId) is { } t &&
            Encoding.UTF8.GetByteCount(t.Text("description") ?? "") <= 128 * 1024)
        {
            var items = current.Items(t.Id).ToArray();
            task = new(t.Id, t.Text("title") ?? "", t.Text("description") ?? "", PlannerStore.TaskFingerprint(t, items),
                items.Select(i => new ChatChecklistItem(i.Text("title") ?? "", i.Flag("isCompleted"))).ToArray(), t.Deadline, t.Focused(currentDay), t.Completed);
        }
        if (notesReady && noteId is not null && await notes.FindAsync(current.Workspace, noteId) is { } saved)
        {
            var document = saved.Document; string text = document.Text.Replace("\uFFFC", "");
            bool truncated = text.Length > 12000;
            if (truncated)
            {
                int length = 12000; if (char.IsHighSurrogate(text[length - 1])) --length;
                text = text[..length];
            }
            note = new(document.Id, document.Title, text, saved.Digest,
                !truncated && document.DeletedAt is null && !document.IsPurged && !document.Expired(NoteDocument.Now), truncated);
        }
        return new(current.Workspace, folder, task, note, DateOnly.FromDateTime(DateTime.Today), previous?.TimeZone ?? TimeZoneInfo.Local.Id);
    }
    private async Task<string> ApplyChatProposalAsync(ChatProposal proposal, ChatContext context, string mode)
    {
        await proposalGate.WaitAsync();
        try
        {
            await SaveEditorAsync();
            var current = await store.ReadAsync();
            if (context.Workspace != current.Workspace || current.Workspace != library.Workspace)
                throw new InvalidOperationException("This proposal belongs to another library. Switch back before applying it.");
            string location = "inbox";
            if (proposal.Kind is ("task" or "note") && context.Folder is { } folder)
            {
                if (!current.Folders.Any(f => f.Id == folder.Id)) throw new InvalidOperationException("The attached folder was deleted. Refresh the context before applying this proposal.");
                location = folder.Id;
            }
            if (!Guid.TryParseExact(proposal.Id, "D", out _)) throw new InvalidDataException("Invalid proposal identity.");
            long offset = current.Profile is null ? 0 : sync.ClockOffset;
            switch (proposal.Kind)
            {
                case "task":
                {
                    // Stable IDs make retrying an already committed creation harmless.
                    if (current.Entities.Any(t => t.Id == proposal.Id)) return "This task was already added.";
                    var created = TaskRules.CreateTask(RequiredTitle(proposal), location) with { Id = proposal.Id };
                    if (proposal.Text is not null) created.Fields!["description"] = Wire.Value(proposal.Text);
                    ApplyProposalTaskFields(created.Fields!, proposal, context);
                    List<Edit> edits = [created];
                    AddProposedSubtasks(edits, proposal.Id, proposal, 0);
                    await store.EditAsync(current.Workspace, edits, offset);
                    return "Task added.";
                }
                case "taskEdit":
                {
                    var target = context.Task ?? throw new InvalidOperationException("This proposal has no attached task.");
                    var original = current.Tasks.FirstOrDefault(t => t.Id == target.Id) ?? throw new InvalidOperationException("The attached task was deleted.");
                    Dictionary<string, System.Text.Json.JsonElement> fields = [];
                    if (proposal.Title is not null) fields["title"] = Wire.Value(RequiredTitle(proposal));
                    if (proposal.Text is not null) fields["description"] = Wire.Value(proposal.Text);
                    ApplyProposalTaskFields(fields, proposal, context);
                    List<Edit> edits = [];
                    if (fields.Count > 0) edits.Add(new(target.Id, "task", "update", fields));
                    int next = current.Items(target.Id).Select(i => i.Number("sortOrder")).DefaultIfEmpty(-1).Max();
                    AddProposedSubtasks(edits, target.Id, proposal, checked(next + 1));
                    if (edits.Count == 0) throw new InvalidOperationException("There are no changes to apply.");
                    await store.EditTaskIfUnchangedAsync(current.Workspace, target.Id, target.Fingerprint, edits, offset);
                    return "Task changes applied.";
                }
                case "note":
                {
                    if (!notesReady) throw new InvalidOperationException("The notes cache is unavailable.");
                    if (await notes.FindAsync(current.Workspace, proposal.Id) is not null) return "This note was already added.";
                    var document = NoteDocument.Create(NoteDocument.FolderKey(location)) with
                    { Id = proposal.Id, Title = RequiredTitle(proposal), Text = PlainProposalText(proposal.Text ?? "") };
                    await notes.SaveAsync(current.Workspace, null, document);
                    return "Note added.";
                }
                case "noteEdit":
                {
                    var target = context.Note ?? throw new InvalidOperationException("This proposal has no attached note.");
                    if (!target.Editable || target.Truncated || mode is not ("replace" or "append")) throw new InvalidOperationException("The attached note cannot be edited with this proposal.");
                    var saved = await notes.FindAsync(current.Workspace, target.Id) ?? throw new InvalidOperationException("The attached note was deleted.");
                    if (saved.Digest != target.Digest || saved.Document.DeletedAt is not null || saved.Document.IsPurged || saved.Document.Expired(NoteDocument.Now))
                        throw new InvalidOperationException("The note changed after this proposal was prepared. Refresh its context and review the proposal again.");
                    var document = ApplyProposedNoteText(saved.Document, proposal, mode);
                    var result = await notes.SaveAsync(current.Workspace, target.Digest, document);
                    return result.ConflictOf is not null && result.Document.Id != target.Id ? "The note changed during saving; your reviewed text was saved as a conflict copy." : "Note changes applied.";
                }
                case "event":
                {
                    if (await calendar.GetEventAsync(current.Workspace, proposal.Id) is not null) return "This event was already added.";
                    var state = await calendar.ReadAsync(current.Workspace);
                    var entry = ProposedEvent(proposal, context, state.DefaultCalendarId);
                    await calendar.SaveAsync(current.Workspace, entry);
                    calendarContext = null;
                    return "Event added to the local Windows calendar.";
                }
                default: throw new InvalidDataException("Unsupported proposal type.");
            }
        }
        finally { proposalGate.Release(); }
    }
    private static string RequiredTitle(ChatProposal proposal)
    {
        string title = proposal.Title?.Trim() ?? ""; TaskRules.Text(title, 16384, true); return title;
    }
    private static string PlainProposalText(string text)
    {
        SharedNoteText.ValidateUnicode(text);
        if (text.Contains('\0') || text.Contains('\uFFFC') || text.Length > 262144) throw new InvalidDataException("Use plain text within the proposal size limit.");
        return text.Replace("\r\n", "\n").Replace('\r', '\n');
    }
    private static void ApplyProposalTaskFields(Dictionary<string, System.Text.Json.JsonElement> fields, ChatProposal proposal, ChatContext context)
    {
        if (proposal.ClearDate == true)
        {
            if (proposal.Date is not null || proposal.Time is not null) throw new InvalidDataException("Choose a date or clear the deadline.");
            fields["deadline"] = Wire.Null;
        }
        else if (proposal.Date is not null)
        {
            var date = DateOnly.ParseExact(proposal.Date, "yyyy-MM-dd", CultureInfo.InvariantCulture);
            TimeOnly? time = proposal.Time is null ? null : TimeOnly.ParseExact(proposal.Time, "HH:mm", CultureInfo.InvariantCulture);
            fields["deadline"] = Wire.Value(Deadline.FromLocal(date, time, TimeZoneInfo.FindSystemTimeZoneById(context.TimeZone)));
        }
        else if (proposal.Time is not null) throw new InvalidDataException("A deadline time needs a date.");
        if (proposal.Today is { } focus) fields["focusDay"] = focus ? Wire.Value("9999-12-31") : Wire.Null;
        if (proposal.Completed is { } completed) fields["completedAt"] = completed ? Wire.Value(Wire.Time()) : Wire.Null;
    }
    private static void AddProposedSubtasks(List<Edit> edits, string taskId, ChatProposal proposal, int first)
    {
        if (proposal.Subtasks is not { } items) return;
        if (items.Length > 128) throw new InvalidDataException("Use at most 128 proposed subtasks.");
        for (int i = 0; i < items.Length; ++i)
        {
            TaskRules.Text(items[i], 16384, true);
            string id = new Guid(SHA256.HashData(Encoding.UTF8.GetBytes(proposal.Id + "|" + i.ToString(CultureInfo.InvariantCulture))).AsSpan(0, 16)).ToString("D");
            edits.Add(TaskRules.CreateItem(taskId, items[i], checked(first + i)) with { Id = id });
        }
    }
    private static NoteDocument ApplyProposedNoteText(NoteDocument original, ChatProposal proposal, string mode)
    {
        string title = proposal.Title is null ? original.Title : RequiredTitle(proposal);
        if (proposal.Text is null) return original with { Title = title, UpdatedAt = NoteDocument.Now };
        string body = PlainProposalText(proposal.Text);
        List<NoteSpan> spans; string text;
        if (mode == "append")
        {
            text = original.Text + (original.Text.Length == 0 || original.Text.EndsWith('\n') ? "" : "\n") + body;
            spans = original.RichText!.Spans.ToList();
        }
        else
        {
            text = body; spans = [];
            foreach (var image in original.RichText!.Spans.Where(s => s.Image is not null).OrderBy(s => s.Start))
            {
                text += "\n\uFFFC";
                spans.Add(image with { Start = text.Length - 1, End = text.Length });
            }
        }
        var result = original with { Title = title, Text = text, RichText = new(1, spans), UpdatedAt = NoteDocument.Now };
        NoteCodec.Validate(result); return result;
    }
    private static CalendarEntry ProposedEvent(ChatProposal proposal, ChatContext context, string calendarId)
    {
        string start = proposal.Start ?? throw new InvalidDataException("Choose a start date for the event.");
        bool allDay = proposal.AllDay == true;
        var zone = CalendarDates.TimeZone(context.TimeZone);
        DateTimeOffset Resolve(DateTime wall)
        {
            if (zone.IsInvalidTime(DateTime.SpecifyKind(wall, DateTimeKind.Unspecified))) throw new InvalidDataException("The event time falls in a daylight-saving gap. Choose another time.");
            return CalendarDates.Resolve(wall, context.TimeZone);
        }
        if (allDay)
        {
            var first = DateOnly.ParseExact(start, "yyyy-MM-dd", CultureInfo.InvariantCulture);
            var last = proposal.End is null ? first : DateOnly.ParseExact(proposal.End, "yyyy-MM-dd", CultureInfo.InvariantCulture);
            var exclusive = last.AddDays(1);
            var entry = new CalendarEntry(proposal.Id, calendarId, RequiredTitle(proposal), Resolve(first.ToDateTime(TimeOnly.MinValue)), Resolve(exclusive.ToDateTime(TimeOnly.MinValue)), context.TimeZone,
                true, first, exclusive, PlainProposalText(proposal.Text ?? ""), proposal.Location ?? "");
            entry.Validate(); return entry;
        }
        var begin = Resolve(DateTime.ParseExact(start, "yyyy-MM-dd'T'HH:mm", CultureInfo.InvariantCulture));
        var finish = proposal.End is null ? begin.AddHours(1) : Resolve(DateTime.ParseExact(proposal.End, "yyyy-MM-dd'T'HH:mm", CultureInfo.InvariantCulture));
        var timed = new CalendarEntry(proposal.Id, calendarId, RequiredTitle(proposal), begin, finish, context.TimeZone, Notes: PlainProposalText(proposal.Text ?? ""), Location: proposal.Location ?? "");
        timed.Validate(); return timed;
    }
}
