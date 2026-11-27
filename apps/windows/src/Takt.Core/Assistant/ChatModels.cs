using System.Globalization;
using System.Text;
using System.Text.Json.Serialization;
using Takt.Core.Models;

namespace Takt.Core.Assistant;

public sealed record ChatFolderContext([property: JsonRequired] string Id, [property: JsonRequired] string Name);
public sealed record ChatChecklistItem([property: JsonRequired] string Title, [property: JsonRequired] bool Completed);
public sealed record ChatTaskContext([property: JsonRequired] string Id, [property: JsonRequired] string Title,
    [property: JsonRequired] string Text, [property: JsonRequired] string Fingerprint,
    [property: JsonRequired] ChatChecklistItem[] Checklist, Deadline? Deadline, bool Focused, bool Completed);
public sealed record ChatNoteContext([property: JsonRequired] string Id, [property: JsonRequired] string Title,
    [property: JsonRequired] string Text, [property: JsonRequired] string Digest, bool Editable, bool Truncated);
public sealed record ChatContext([property: JsonRequired] string Workspace, ChatFolderContext? Folder,
    ChatTaskContext? Task, ChatNoteContext? Note, [property: JsonRequired] DateOnly Today, [property: JsonRequired] string TimeZone);
public sealed record ChatProposal([property: JsonRequired] string Id, [property: JsonRequired] string Kind,
    string? Title = null, string? Text = null, string[]? Subtasks = null, string? Date = null, string? Time = null,
    bool? ClearDate = null, bool? Today = null, bool? Completed = null, string? Start = null, string? End = null,
    bool? AllDay = null, string? Location = null);
public sealed record ChatMessage([property: JsonRequired] string Id, [property: JsonRequired] string Role,
    [property: JsonRequired] string Text, [property: JsonRequired] DateTimeOffset CreatedAt,
    [property: JsonRequired] ChatProposal[] Proposals, ChatContext? Context = null, string[]? Applied = null, string[]? Dismissed = null);
public sealed record ChatThread([property: JsonRequired] string Id, [property: JsonRequired] string Workspace,
    [property: JsonRequired] string Title, [property: JsonRequired] DateTimeOffset UpdatedAt, [property: JsonRequired] ChatMessage[] Messages);
// Credentials deliberately do not belong to connection settings, context, or persisted history.
public sealed record ChatConnection(string Name, string Address, string Model, bool Tools = true, string Protocol = "openai", string Provider = "custom", string? ProviderOption = null);
public sealed record ChatReply(string Text, ChatProposal[] Proposals);

public static class ChatRules
{
    public const int MaxTextBytes = 256 * 1024;
    public const int MaxProposals = 20;
    public const int MaxThreadBytes = 8 * 1024 * 1024;
    public static void Text(string? value, int limit, bool required = false)
    {
        if (value is null || value.Contains('\0') || required && string.IsNullOrWhiteSpace(value) || Encoding.UTF8.GetByteCount(value) > limit)
            throw new InvalidDataException("Chat text is missing or exceeds the supported size.");
        for (int i = 0; i < value.Length; ++i)
            if (char.IsHighSurrogate(value[i]) && (i + 1 == value.Length || !char.IsLowSurrogate(value[i + 1])) ||
                char.IsLowSurrogate(value[i]) && (i == 0 || !char.IsHighSurrogate(value[i - 1]))) throw new InvalidDataException("Invalid Unicode chat text.");
    }
    public static void Workspace(string value) => Text(value, 2048, true);
    public static string Id(string value) => Guid.TryParseExact(value, "D", out var id) ? id.ToString("D") : throw new InvalidDataException("Invalid chat identifier.");
    public static void Context(ChatContext context)
    {
        if (context is null) throw new InvalidDataException("Missing chat context.");
        Workspace(context.Workspace); Text(context.TimeZone, 256, true);
        try { _ = TimeZoneInfo.FindSystemTimeZoneById(context.TimeZone); }
        catch (Exception error) when (error is TimeZoneNotFoundException or InvalidTimeZoneException) { throw new InvalidDataException("Unknown chat time zone.", error); }
        if (context.Folder is { } folder) { Text(folder.Id, 256, true); Text(folder.Name, 320); }
        if (context.Task is { } task)
        {
            _ = Id(task.Id); Text(task.Title, 16384); Text(task.Text, MaxTextBytes); Text(task.Fingerprint, 256, true);
            if (task.Checklist is null || task.Checklist.Length > 4096) throw new InvalidDataException("Too many task subtasks in chat context.");
            foreach (var item in task.Checklist) { if (item is null) throw new InvalidDataException("Invalid task checklist context."); Text(item.Title, 16384); }
            if (task.Deadline is { } deadline) _ = deadline.LocalParts();
        }
        if (context.Note is { } note)
        {
            _ = Id(note.Id); Text(note.Title, 16384); Text(note.Text, MaxTextBytes); Text(note.Digest, 256, true);
            if (note.Editable && note.Truncated) throw new InvalidDataException("A truncated note cannot be edited by chat.");
        }
    }
    public static void Proposal(ChatProposal proposal, ChatContext? context)
    {
        if (proposal is null) throw new InvalidDataException("Missing chat proposal.");
        _ = Id(proposal.Id);
        if (proposal.Kind is not ("task" or "taskEdit" or "note" or "noteEdit" or "event")) throw new InvalidDataException("Unsupported proposal kind.");
        if (proposal.Title is { } title) Text(title, 16384, true);
        if (proposal.Text is { } text) Text(text, MaxTextBytes);
        if (proposal.Subtasks is { } items)
        {
            if (items.Length > 128) throw new InvalidDataException("Too many proposed subtasks.");
            foreach (var item in items) Text(item, 16384, true);
        }
        if (proposal.Date is { } day && !DateOnly.TryParseExact(day, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out _)) throw new InvalidDataException("Use YYYY-MM-DD for proposed deadlines.");
        if (proposal.Time is { } time && (!TimeOnly.TryParseExact(time, "HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out _) || proposal.Date is null)) throw new InvalidDataException("A proposed time requires a date and HH:mm format.");
        if (proposal.ClearDate == true && (proposal.Date is not null || proposal.Time is not null)) throw new InvalidDataException("A deadline cannot be cleared and set together.");
        bool taskFields = proposal.Subtasks is not null || proposal.Date is not null || proposal.Time is not null || proposal.ClearDate is not null || proposal.Today is not null || proposal.Completed is not null;
        bool eventFields = proposal.Start is not null || proposal.End is not null || proposal.AllDay is not null || proposal.Location is not null;
        switch (proposal.Kind)
        {
            case "task":
                if (proposal.Title is null || eventFields) throw new InvalidDataException("A task proposal requires a title and task fields.");
                break;
            case "taskEdit":
                if (context?.Task is null || eventFields || proposal.Title is null && proposal.Text is null && !taskFields) throw new InvalidDataException("Task edits require an attached task and changed fields.");
                break;
            case "note":
                if (proposal.Title is null || taskFields || eventFields) throw new InvalidDataException("A note proposal requires a title and note text.");
                break;
            case "noteEdit":
                if (context?.Note is not { Editable: true, Truncated: false } || taskFields || eventFields || proposal.Title is null && proposal.Text is null) throw new InvalidDataException("Note edits require a complete editable attached note.");
                break;
            case "event":
                if (proposal.Title is null || taskFields || proposal.Start is null) throw new InvalidDataException("An event proposal requires a title and start.");
                string format = proposal.AllDay == true ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm";
                if (!DateTime.TryParseExact(proposal.Start, format, CultureInfo.InvariantCulture, DateTimeStyles.None, out var start) ||
                    proposal.End is { } end && (!DateTime.TryParseExact(end, format, CultureInfo.InvariantCulture, DateTimeStyles.None, out var finish) || finish < start || proposal.AllDay != true && finish == start))
                    throw new InvalidDataException("Invalid event dates. Use local dates/times and an end after the start.");
                if (proposal.Location is { } location) Text(location, 16384);
                break;
        }
    }
    public static void Thread(ChatThread thread)
    {
        if (thread is null) throw new InvalidDataException("Missing chat thread.");
        _ = Id(thread.Id); Workspace(thread.Workspace); Text(thread.Title, 1024);
        if (thread.Messages is null || thread.Messages.Length > 512) throw new InvalidDataException("Too many chat messages.");
        HashSet<string> messageIds = []; HashSet<string> proposalIds = [];
        foreach (var message in thread.Messages)
        {
            if (message is null || !messageIds.Add(Id(message.Id)) || message.Role is not ("user" or "assistant")) throw new InvalidDataException("Invalid or duplicate chat message.");
            Text(message.Text, MaxTextBytes);
            if (message.Context is { } context) { Context(context); if (context.Workspace != thread.Workspace) throw new InvalidDataException("A chat context belongs to another workspace."); }
            if (message.Proposals is null || message.Proposals.Length > MaxProposals || message.Role == "user" && message.Proposals.Length > 0) throw new InvalidDataException("Invalid chat proposals.");
            foreach (var proposal in message.Proposals) { Proposal(proposal, message.Context); if (!proposalIds.Add(Id(proposal.Id))) throw new InvalidDataException("Duplicate chat proposal."); }
            var states = (message.Applied ?? []).Concat(message.Dismissed ?? []).ToArray();
            if (states.Length > message.Proposals.Length || states.Distinct(StringComparer.OrdinalIgnoreCase).Count() != states.Length ||
                states.Any(id => !message.Proposals.Any(p => string.Equals(p.Id, id, StringComparison.OrdinalIgnoreCase))))
                throw new InvalidDataException("Proposal states must identify distinct proposals in this message.");
        }
    }
}
