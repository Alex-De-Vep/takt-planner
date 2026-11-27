using System.Text.Json;
using Takt.Core.Models;
using Takt.Core.Storage;
using Takt.Core.Sync;
using Xunit;

namespace Takt.Core.Tests;

public sealed class TaskRulesTests
{
    internal const string LibraryId = "11111111-1111-4111-8111-111111111111";
    internal const string TaskId = "22222222-2222-4222-8222-222222222222";
    internal static readonly Profile Profile = new("https://example.com", "person@example.com", LibraryId);
    internal static Entity TaskEntity(string section = "inbox", string revision = "1")
    {
        var edit = TaskRules.CreateTask("Review the release", section);
        return new(TaskId, "task", edit.Fields!, [], Revision: revision);
    }
    [Fact] public void TodayDoesNotChangePlacement()
    {
        var task = TaskEntity("week"); var library = new Library("local", null, [task], []);
        var move = TaskRules.Move(library, [task.Id], "today").Single();
        Assert.Equal("9999-12-31", move.Fields!["focusDay"].GetString());
        Assert.False(move.Fields.ContainsKey("placement"));
        Assert.Equal("week", task.Placement);
    }
    [Fact] public void DeadlineDoesNotSelectAPlanningFolder()
    {
        var task = TaskEntity("month");
        var edit = TaskRules.Update(task, "deadline", Wire.Value(new Deadline("UTC", false, "2026-12-04")));
        TaskRules.Validate(edit);
        Assert.Single(edit.Fields!); Assert.False(edit.Fields!.ContainsKey("planning"));
        Assert.False(edit.Fields.ContainsKey("placement"));
    }
    [Fact] public void AllTasksAndTodayCreateInInbox()
    {
        Assert.Equal("inbox", TaskRules.CreateTask("Task", "all").Fields!["placement"].GetProperty("kind").GetString());
        var today = TaskRules.CreateTask("Task", "today");
        Assert.Equal("inbox", today.Fields!["placement"].GetProperty("kind").GetString());
        Assert.Equal("9999-12-31", today.Fields["focusDay"].GetString());
    }
    [Fact] public void DateOnlyAndTimedDeadlineUseDistinctWireShapes()
    {
        var day = new DateOnly(2026, 12, 4);
        var date = Wire.Value(Deadline.FromLocal(day, null, TimeZoneInfo.Utc));
        Assert.True(date.TryGetProperty("date", out _)); Assert.False(date.TryGetProperty("instant", out _));
        var timed = Wire.Value(Deadline.FromLocal(day, new TimeOnly(12, 30), TimeZoneInfo.Utc));
        Assert.False(timed.TryGetProperty("date", out _)); Assert.Equal("2026-12-04T12:30:00.000Z", timed.GetProperty("instant").GetString());
    }
    [Fact] public void InvalidAndAmbiguousDaylightSavingTimesAreNotSilentlyChanged()
    {
        var zone = TimeZoneInfo.FindSystemTimeZoneById("America/New_York");
        Assert.Throws<ArgumentException>(() => Deadline.FromLocal(new(2026, 3, 8), new(2, 30), zone));
        Assert.Throws<ArgumentException>(() => Deadline.FromLocal(new(2026, 11, 1), new(1, 30), zone));
    }
    [Fact] public void RemovingFolderMovesTasksWithoutChangingTheirDeadlineOrFocus()
    {
        var folder = new Entity(Wire.Id(), "folder", new() { ["name"] = Wire.Value("Work"), ["sortOrder"] = Wire.Value(0) }, []);
        var task = TaskEntity(folder.Id); var library = new Library("local", null, [folder, task], []);
        var edits = TaskRules.DeleteFolder(library, folder);
        Assert.Equal("placement", edits[0].Fields!.Single().Key); Assert.Equal("delete", edits[^1].Kind);
    }
    [Fact] public void DeleteTaskIncludesItsChildrenOnly()
    {
        var task = TaskEntity();
        var child = new Entity(Wire.Id(), "checklistItem", new() { ["taskId"] = Wire.Value(task.Id) }, []);
        var other = new Entity(Wire.Id(), "checklistItem", new() { ["taskId"] = Wire.Value(Wire.Id()) }, []);
        var edits = TaskRules.DeleteTask(new("local", null, [task, child, other], []), task);
        Assert.Equal(2, edits.Count); Assert.DoesNotContain(edits, e => e.Id == other.Id);
    }
    [Theory] [InlineData("http://example.com")] [InlineData("https://example.com/path")] [InlineData("https://user@example.com")] [InlineData("https://example.com/?q=1")]
    public void CredentialsCannotGoToAnUnscopedOrigin(string origin) => Assert.Throws<ArgumentException>(() => ApiClient.NormalizeOrigin(origin));
    [Fact] public void TextLimitsUseUtf8AndRejectNullCharacters()
    {
        Assert.Throws<ArgumentException>(() => TaskRules.Text(new string('я', 8193), 16384));
        Assert.Throws<ArgumentException>(() => TaskRules.CreateTask("one\0two", "inbox"));
        Assert.Throws<ArgumentException>(() => TaskRules.CreateFolder(new string('x', 81), 0));
    }
    [Fact] public void OverlayKeepsUnknownFieldsAndLosesToNewerConfirmedEdits()
    {
        var task = TaskEntity();
        task.Fields["planning"] = Wire.Value(new { kind = "week", anchor = "2026-12-04T10:00:00.000Z" });
        var newest = new Stamp(300, 0, Wire.Id(), Wire.Id()); task.Versions["title"] = newest;
        var mutation = new Mutation(Wire.Id(), LibraryId, Wire.Id(), task.Id, "task", "update", new()
        { ["title"] = new(Wire.Value("Old edit"), newest with { PhysicalMillis = 200 }) });
        var result = mutation.Overlay(task)!;
        Assert.Equal(task.Text("title"), result.Text("title")); Assert.True(result.Fields.ContainsKey("planning"));
        Assert.Equal("Review the release", task.Text("title"));
    }
    [Fact] public void DeletedTaskCannotBeResurrectedByPendingCreate()
    {
        var task = TaskEntity() with { Deleted = true };
        var mutation = new Mutation(Wire.Id(), LibraryId, Wire.Id(), task.Id, "task", "create", []);
        Assert.True(mutation.Overlay(task)!.Deleted);
    }
    [Fact] public void InvalidSyncResponseCannotAcknowledgeTheQueue()
    {
        var mutation = new Mutation(Wire.Id(), LibraryId, Wire.Id(), TaskId, "task", "delete", DeleteVersion: new(1, 0, Wire.Id(), Wire.Id()));
        Assert.Throws<InvalidDataException>(() => SyncValidation.Results([mutation], [new(Wire.Id(), "deleted", TaskEntity(), null)]));
        Assert.Throws<InvalidDataException>(() => SyncValidation.Results([mutation], []));
    }
    [Fact] public void PagingMustAdvanceAndStayInTheSameLibrary()
    {
        Assert.Throws<InvalidDataException>(() => SyncValidation.Page(new(LibraryId, [], "4", true), Profile, "4"));
        Assert.Throws<InvalidDataException>(() => SyncValidation.Page(new(Wire.Id(), [], "5", false), Profile, "4"));
        Assert.Throws<InvalidDataException>(() => SyncValidation.Snapshot(new(1, LibraryId, "0", true, [TaskEntity()]), Profile));
    }
    [Fact] public void MutationBatchHonorsCountAndEncodedByteLimits()
    {
        var fields = new Dictionary<string, FieldChange> { ["description"] = new(Wire.Value(new string('я', 900)), new(1, 0, Wire.Id(), Wire.Id())) };
        var queue = Enumerable.Range(0, 20).Select(_ => new Mutation(Wire.Id(), LibraryId, Wire.Id(), TaskId, "task", "update", fields)).ToList();
        var batch = SyncValidation.Batch(queue, new(3, 4194304)); Assert.Equal(3, batch.Count);
        batch = SyncValidation.Batch(queue, new(100, 4096));
        Assert.True(batch.Count < queue.Count); Assert.True(JsonSerializer.SerializeToUtf8Bytes(new { mutations = batch }, Wire.Json).Length <= 4096);
    }
    [Fact] public void BackupContainsNoCredentialsAndRemapsParentIdentifiers()
    {
        var task = TaskEntity(); var item = TaskRules.CreateItem(task.Id, "Verify", 0);
        var child = new Entity(item.Id, item.Type, item.Fields!, []);
        var source = new Library(Profile.Workspace, Profile, [task, child], []);
        string backup = TaskBackup.Export(source);
        Assert.DoesNotContain(Profile.Email, backup); Assert.DoesNotContain(Profile.Origin, backup);
        var edits = TaskBackup.Import(backup, Library.Empty);
        Assert.NotEqual(task.Id, edits[0].Id); Assert.Equal(edits[0].Id, edits[1].Fields!["taskId"].GetString());
        Assert.Throws<InvalidOperationException>(() => TaskBackup.Import(backup, source));
    }
}
