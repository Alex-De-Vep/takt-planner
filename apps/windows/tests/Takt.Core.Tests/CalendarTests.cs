using System.Text;
using Takt.Core.Calendar;
using Xunit;

namespace Takt.Core.Tests;

public sealed class CalendarTests : IAsyncLifetime
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "takt-calendar-test-" + Guid.NewGuid());
    private LocalCalendarProvider store = null!;
    public Task InitializeAsync() { store = new(Path.Combine(directory, "calendar.sqlite")); return Task.CompletedTask; }
    public async Task DisposeAsync() { await store.DisposeAsync(); if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    private static CalendarEntry Event(string title = "Design review") => CalendarEntry.Create("local", title, new(2026, 11, 27), "task-1") with { Zone = "UTC", Start = new(2026, 11, 27, 9, 0, 0, TimeSpan.Zero), End = new(2026, 11, 27, 10, 0, 0, TimeSpan.Zero) };
    [Fact] public async Task LocalEventsAreWorkspaceScopedAndDoNotNeedTaskEntities()
    {
        var saved = await store.SaveAsync("local", Event());
        Assert.Empty((await store.ReadAsync("account|library")).Events);
        Assert.Equal(saved.Id, (await store.ReadAsync("local")).Events.Single().Id);
        await store.DetachMissingTaskLinksAsync("local", new HashSet<string>());
        var detached = (await store.ReadAsync("local")).Events.Single();
        Assert.Null(detached.TaskId); Assert.Equal(saved.Start, detached.Start); Assert.Equal(saved.Title, detached.Title);
        Assert.NotNull(await store.GetEventAsync("local", saved.Id));
    }
    [Fact] public async Task DeletedLinkedTaskKeepsCalendarEventAndItsAlerts()
    {
        var original = Event() with { Alerts = [new("relative", -15), new("absolute", null, new(2026, 11, 26, 12, 0, 0, TimeSpan.Zero))] };
        var saved = await store.SaveAsync("local", original);
        await store.DetachMissingTaskLinksAsync("local", new HashSet<string>());
        var current = (await store.GetEventAsync("local", saved.Id))!;
        Assert.Null(current.TaskId); Assert.Equal(saved.Alarms, current.Alarms); Assert.Equal(saved.End, current.End);
    }
    [Fact] public async Task UnrelatedEditsMergeAndSameFieldConflicts()
    {
        var original = await store.SaveAsync("local", Event());
        await store.SaveAsync("local", original with { Notes = "Edited in another window" }, original);
        var merged = await store.SaveAsync("local", original with { Title = "Updated title" }, original);
        Assert.Equal("Edited in another window", merged.Notes);
        await Assert.ThrowsAsync<CalendarConflictException>(() => store.SaveAsync("local", original with { Title = "Conflicting title" }, original));
        await Assert.ThrowsAsync<CalendarConflictException>(() => store.DeleteAsync("local", original));
    }
    [Fact] public async Task MoveAndUndoKeepFreshMetadataAndAbsoluteAlertInstant()
    {
        var original = await store.SaveAsync("local", Event() with { Alerts = [new("absolute", null, new(2026, 11, 26, 12, 0, 0, TimeSpan.Zero)), new("relative", -15)] });
        var fresh = await store.SaveAsync("local", original with { Notes = "Fresh notes" }, original);
        var move = await store.MoveAsync("local", original, new(2026, 11, 27), new(2026, 11, 29), "UTC");
        Assert.Equal("Fresh notes", move.After.Notes); Assert.Equal(original.Alarms[0].Due(original), move.After.Alarms[0].Due(move.After));
        Assert.Equal(original.Alarms[1].Due(original).AddDays(2), move.After.Alarms[1].Due(move.After));
        await store.SaveAsync("local", move.After with { Location = "New room" }, move.After);
        var restored = await store.UndoMoveAsync("local", move);
        Assert.Equal(original.Start, restored.Start); Assert.Equal("New room", restored.Location); Assert.Equal(fresh.Notes, restored.Notes);
    }
    [Fact] public async Task StaleDragAndUndoNeverOverwriteAnotherReschedule()
    {
        var original = await store.SaveAsync("local", Event());
        var moved = await store.MoveAsync("local", original, new(2026, 11, 27), new(2026, 11, 28), "UTC");
        await Assert.ThrowsAsync<CalendarConflictException>(() => store.MoveAsync("local", original, new(2026, 11, 27), new(2026, 11, 29), "UTC"));
        await store.MoveAsync("local", moved.After, new(2026, 11, 28), new(2026, 11, 30), "UTC");
        await Assert.ThrowsAsync<CalendarConflictException>(() => store.UndoMoveAsync("local", moved));
    }
    [Fact] public void AllDayExclusiveEndNeverLeaksIntoNextDayOrChangesWithDisplayZone()
    {
        var first = new DateOnly(2026, 11, 27); var exclusive = first.AddDays(2);
        var entry = Event() with { AllDay = true, StartDate = first, EndDateExclusive = exclusive, Start = CalendarDates.Resolve(first.ToDateTime(TimeOnly.MinValue), "UTC"), End = CalendarDates.Resolve(exclusive.ToDateTime(TimeOnly.MinValue), "UTC") };
        entry.Validate();
        Assert.True(CalendarDates.OccursOn(entry, first.AddDays(1), "Pacific/Honolulu"));
        Assert.False(CalendarDates.OccursOn(entry, exclusive, "Pacific/Kiritimati"));
        var moved = CalendarDates.Move(entry, first.AddDays(1), first.AddDays(4), "UTC");
        Assert.Equal(first.AddDays(3), moved.StartDate); Assert.Equal(exclusive.AddDays(3), moved.EndDateExclusive);
    }
    [Fact] public void TimedMoveAcrossDstKeepsWallMinutesAndElapsedDuration()
    {
        string zone = "America/New_York";
        var start = CalendarDates.Resolve(new(2026, 3, 7, 2, 30, 0), zone);
        var entry = Event() with { Start = start, End = start.AddHours(2), Zone = zone };
        var moved = CalendarDates.Move(entry, new(2026, 3, 7), new(2026, 3, 8), zone);
        Assert.Equal(new TimeOnly(3, 30), TimeOnly.FromDateTime(TimeZoneInfo.ConvertTime(moved.Start, CalendarDates.TimeZone(zone)).DateTime));
        Assert.Equal(TimeSpan.FromHours(2), moved.End - moved.Start);
        var repeated = CalendarDates.Resolve(new(2026, 11, 1, 1, 30, 0), zone);
        Assert.Equal(TimeSpan.FromHours(-4), repeated.Offset);
    }
    [Fact] public async Task IcsSnapshotsStayReadOnlyAndOriginalTextSurvivesExport()
    {
        const string source = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Fixture//EN\r\nBEGIN:VEVENT\r\nUID:test-1\r\nDTSTART:20261127T090000Z\r\nDTEND:20261127T100000Z\r\nSUMMARY:Imported review\r\nX-CUSTOM:keep me\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
        var imported = await store.ImportAsync("local", "Team calendar", source);
        var events = await store.QueryAsync("local", new(2026, 11, 27), new(2026, 11, 28), "UTC");
        var entry = Assert.Single(events); Assert.True(entry.ReadOnly); Assert.False(entry.CanEdit);
        Assert.Equal(entry.Id, (await store.GetEventAsync("local", entry.Id))!.Id);
        await Assert.ThrowsAsync<InvalidOperationException>(() => store.SaveAsync("local", entry with { Title = "Must not change" }, entry));
        Assert.Equal(source, await store.ExportAsync("local", imported.Id));
    }
    [Fact] public async Task SubscriptionRefreshKeepsIdentityAndVisibilityAndCannotReviveRemovedCalendar()
    {
        const string workspace = "calendar-subscription";
        string id = Guid.NewGuid().ToString("D");
        const string first = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Fixture//EN\r\nBEGIN:VEVENT\r\nUID:meeting\r\nDTSTART:20261127T090000Z\r\nDTEND:20261127T100000Z\r\nSUMMARY:Original\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
        var feed = new CalendarFeed("protected-address-fixture", DateTimeOffset.UtcNow, "\"one\"");
        var initial = await store.SubscribeAsync(workspace, id, "Team", first, feed);
        var start = new DateOnly(2026, 11, 27);
        var original = Assert.Single(await store.QueryAsync(workspace, start, start.AddDays(1), "UTC"));
        await store.ConfigureAsync(workspace, ["local"], "local");
        var revised = feed with { ETag = "\"two\"" };
        Assert.True(await store.UpdateSubscriptionAsync(workspace, initial, first.Replace("Original", "Updated"), revised));
        Assert.False(await store.UpdateSubscriptionAsync(workspace, initial, first, feed));
        Assert.Empty(await store.QueryAsync(workspace, start, start.AddDays(1), "UTC"));
        var updated = Assert.IsType<CalendarEntry>(await store.GetEventAsync(workspace, original.Id));
        Assert.Equal("Updated", updated.Title);
        var saved = Assert.Single((await store.ReadAsync(workspace)).Calendars, item => item.Id == id);
        await store.RemoveSnapshotAsync(workspace, id);
        Assert.False(await store.UpdateSubscriptionAsync(workspace, saved, first, revised));
        Assert.Null(await store.GetEventAsync(workspace, original.Id));
    }

    [Fact] public async Task RecurrenceExclusionsAndOverridesAreExpandedByPinnedParser()
    {
        const string source = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Fixture//EN\r\nBEGIN:VEVENT\r\nUID:daily\r\nDTSTART:20261127T090000Z\r\nDTEND:20261127T100000Z\r\nRRULE:FREQ=DAILY;COUNT=4\r\nEXDATE:20261128T090000Z\r\nSUMMARY:Daily\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:daily\r\nRECURRENCE-ID:20261129T090000Z\r\nDTSTART:20261129T140000Z\r\nDTEND:20261129T150000Z\r\nSUMMARY:Moved occurrence\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
        await store.ImportAsync("local", "Recurring", source);
        var events = await store.QueryAsync("local", new(2026, 11, 27), new(2026, 12, 1), "UTC");
        Assert.Equal(3, events.Count); Assert.All(events, e => Assert.True(e.Recurring && !e.CanEdit));
        Assert.Equal(14, events.Single(e => e.Title == "Moved occurrence").Start.Hour);
        Assert.DoesNotContain(events, e => e.Start.Day == 28);
    }
    [Fact] public async Task ExportEscapesTextFoldsUtf8AndKeepsAllDayExclusiveEnd()
    {
        var entry = Event("Review, release; " + new string('界', 60)) with { Notes = "First line\nSecond line\\path", Alerts = [new("alert", -15)] };
        await store.SaveAsync("local", entry);
        string output = await store.ExportAsync("local", "local");
        Assert.All(output.Split("\r\n"), line => Assert.True(Encoding.UTF8.GetByteCount(line) <= 75));
        var imported = new CalendarDefinition("fixture", "Fixture", false, SnapshotIcs: output);
        var roundTrip = Assert.Single(CalendarIcs.Expand(imported, new(2026, 11, 27), new(2026, 11, 28), "UTC"));
        Assert.Equal(entry.Title, roundTrip.Title); Assert.Equal(entry.Notes, roundTrip.Notes);
        Assert.DoesNotContain("task-1", output, StringComparison.Ordinal);
    }
    [Fact] public async Task InvisibleCalendarKeepsEventsAvailableByIdentity()
    {
        var entry = await store.SaveAsync("local", Event());
        await store.ConfigureAsync("local", [], "local");
        Assert.Empty(await store.QueryAsync("local", new(2026, 11, 27), new(2026, 11, 28), "UTC"));
        Assert.NotNull(await store.GetEventAsync("local", entry.Id));
    }
    [Fact] public async Task InvalidEventDoesNotLeavePartialWrite()
    {
        var invalid = Event() with { End = Event().Start.AddMinutes(-1) };
        await Assert.ThrowsAsync<InvalidDataException>(() => store.SaveAsync("local", invalid));
        Assert.Empty((await store.ReadAsync("local")).Events);
    }
    [Fact] public async Task TimedEventsEndingAtMidnightAreExcludedFromTheNextDay()
    {
        await store.SaveAsync("local", Event() with { Start = new(2026, 11, 26, 23, 0, 0, TimeSpan.Zero), End = new(2026, 11, 27, 0, 0, 0, TimeSpan.Zero) });
        Assert.Empty(await store.QueryAsync("local", new(2026, 11, 27), new(2026, 11, 28), "UTC"));
    }
    [Fact] public async Task IcsAllDayIdsRemainStableAcrossViewerZonesAndEndsAreExclusive()
    {
        const string source = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Fixture//EN\r\nBEGIN:VEVENT\r\nUID:all-day\r\nDTSTART;VALUE=DATE:20261127\r\nDTEND;VALUE=DATE:20261129\r\nSUMMARY:Two days\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
        await store.ImportAsync("local", "Dates", source);
        var utc = Assert.Single(await store.QueryAsync("local", new(2026, 11, 27), new(2026, 11, 28), "UTC"));
        var pacific = Assert.Single(await store.QueryAsync("local", new(2026, 11, 28), new(2026, 11, 29), "Pacific/Honolulu"));
        Assert.Equal(utc.Id, pacific.Id); Assert.Equal(new DateOnly(2026, 11, 29), utc.EndDateExclusive);
        Assert.Empty(await store.QueryAsync("local", new(2026, 11, 29), new(2026, 11, 30), "Pacific/Kiritimati"));
    }

    [Fact] public async Task CancelledIcsOverrideSuppressesTheOriginalOccurrence()
    {
        const string source = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Fixture//EN\r\nBEGIN:VEVENT\r\nUID:review\r\nDTSTART:20261127T090000Z\r\nDTEND:20261127T100000Z\r\nRRULE:FREQ=DAILY;COUNT=2\r\nSUMMARY:Review\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:review\r\nRECURRENCE-ID:20261128T090000Z\r\nDTSTART:20261128T090000Z\r\nDTEND:20261128T100000Z\r\nSTATUS:CANCELLED\r\nSUMMARY:Cancelled review\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
        await store.ImportAsync("local", "Cancelled fixture", source);
        var events = await store.QueryAsync("local", new(2026, 11, 27), new(2026, 11, 29), "UTC");
        Assert.Empty(events.Warnings); Assert.Equal(27, Assert.Single(events).Start.Day);
    }

}
