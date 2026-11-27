# Windows calendar milestone

**Status: source implementation only. No Windows build, restore, .NET test execution, native launch, notification delivery, account connection or live-server verification has been performed.**

## Provider and storage

Windows does not supply macOS EventKit to this application. The initial real provider is `LocalCalendarProvider`: an independent SQLite database with a writable **Takt on this device** calendar, plus explicitly imported read-only ICS snapshots. The local calendar works offline. Explicitly added subscriptions use a separate HTTPS fetcher.

Events, calendar visibility/defaults, alerts and local task links are scoped to the active local/server-library workspace. They are not task entities, deadlines, Today/This Week/Month membership, or part of Takt's task/notes synchronization protocol. Other devices do not receive these events. Signing out retains the previous workspace's calendar locally, independently of the guest workspace. A calendar OAuth/CalDAV/Graph adapter and cross-device link synchronization are future work, not implied by this milestone.

The database is `%LOCALAPPDATA%\Takt\Windows\calendar.sqlite`. Event mutations re-read the latest document in an immediate SQLite transaction. Editing merges only changed fields, rejects conflicting edits to the same fields, preserves concurrent unrelated metadata and cannot recreate a deleted event. Deleting requires the opened event revision to remain current. Drag and Undo compare event dates and preserve fresh unrelated metadata.

ICS import creates an additional **snapshot**. The separate Subscribe by link action saves a DPAPI-protected HTTPS/webcal URL and updates the same cached calendar without duplicating events. Reimporting creates another independent snapshot; remove the old snapshot explicitly if desired. The original ICS text is retained and exported unchanged, including recurrence rules, exceptions, VTIMEZONE definitions, unknown properties and opaque alarms. Imported and subscribed events and recurrence/exception occurrences are view-only. Takt does not deliver imported snapshot alarms. No event, calendar URL or imported attachment launches an external application automatically.

`Ical.Net` **5.2.4** expands bounded recurrence queries and exceptions. The v5 API accepts a start, not an end; the adapter bounds enumeration, accounts for continuing multi-day events, limits unmatched recurrence evaluation and reports unavailable snapshots without hiding the local calendar. Limits: 8 MiB UTF-8 per input, 10,000 event components, 20,000 occurrences per queried period, at most 32 calendars and about 32 MiB of stored ICS text. Event durations above 100 years are unavailable. Unrecognized or pathological calendar data remains available for original-file export/removal; the UI shows an explicit warning.

Local calendar export produces RFC 5545 text with UTF-8-aware line folding, escaped text, UTC timed events, exclusive date-only ends and display alarms. It deliberately excludes local task IDs. Export/import is an interchange copy, not a full-fidelity local database backup: imported copies become read-only, and task links are not restored.

## Interface and parity

The extra calendar panel follows macOS placement with native WinUI/Fluent controls: month above agenda; Today and period arrows; Day, 3 days and Week; vertical agenda or horizontally scrolling day columns; Event and For task actions at the bottom. Native month navigation retains agenda selection until a day is chosen. Event density marks are refreshed for realized months.

- Create/edit/delete standalone local events; a separate Confirm delete action is required. Cancelling retains the editor and draft until it is closed explicitly.
- Title, location, notes, start/end, time zone, all-day, and multiple relative or absolute alerts.
- The all-day editor's last day is inclusive; persisted/exported end is the following exclusive day. All-day date occupancy is independent of the viewer's time zone.
- Timed events keep instants and their selected zone. Explicitly entered spring-gap times are rejected; repeated autumn times select the earlier instant. Drag preserves local wall-clock minutes and elapsed duration, advancing through a spring gap by its offset change. Absolute alerts retain their instant.
- Drag a writable one-off event onto another day in 3-day/Week views, including a continuation day of a multi-day event. Undo restores dates only if it was not rescheduled again.
- For task creates multiple independent local blocks. The linked-task action returns to the task. Deleting a task removes links after reconciliation, retaining events and alerts; deleting an event retains its task.
- Visible calendars and the default writable calendar are native settings. Hidden events remain addressable by event ID. Removing a snapshot never changes the original file or external calendar.

The panel does not yet have a day/hour time-grid with overlap layout; columns contain native event cards. Calendar settings are available from the panel and the main Settings dialog. English labels and locale-native date/time formatting need the release localization pass.

## Notifications

`CalendarReminders` schedules the nearest **32** future local event alarms as native Windows scheduled toasts; the task scheduler must reserve its own 32 slots, keeping the combined budget within 64. Calendar group prefix `cale` is disjoint from task prefix `takt`. On workspace switching, old calendar groups are cancelled, while task reminders are untouched.

The parent window must refill on edits, activation and its existing timer. Already scheduled toasts may survive process exit, subject to Windows settings; replenishment does not run continuously while Takt is closed. Blocked notifications, process lifetime, cold/warm activation, capacity limits, clock/time-zone changes, unpackaged registration, x64 and ARM64 require Windows testing. Saving an alert is not proof of delivered notifications.

## Integration contract

Core dependency: `<PackageReference Include="Ical.Net" Version="5.2.4" />`. `Microsoft.Data.Sqlite` is already a Core dependency.

```csharp
var calendar = new LocalCalendarProvider(Path.Combine(Preferences.DirectoryPath, "calendar.sqlite"));
CalendarView.Initialize(calendar, this); // no separate InitializeAsync needed
await CalendarView.OpenWorkspaceAsync(library.Workspace, selectedTask?.Id, selectedTask?.Text("title"));
await CalendarView.ScheduleTaskAsync(task.Id, task.Text("title") ?? "Task");
await CalendarView.OpenEventAsync(eventId);
await calendar.DetachMissingTaskLinksAsync(library.Workspace, allNonDeletedTaskIds);
await calendarReminders.UpdateAsync(calendar, library.Workspace);
```

- `OpenWorkspaceAsync` refreshes the task context; repeated calls in the same workspace preserve chosen day, month and agenda mode.
- `RefreshAsync` refreshes calendar data explicitly.
- `Changed` signals a committed event/settings mutation. Refresh task-linked block lists and reminder scheduling.
- `TaskRequested` provides `CalendarTaskRequestedEventArgs.Workspace` and `.TaskId`; reject a stale workspace before navigating.
- The task editor's scheduled blocks should use `ReadAsync(workspace).Events.Where(e => e.TaskId == selectedTask.Id)`, sorted by start, with a button calling `OpenEventAsync(id)`. Calendar visibility must not hide the task's existing blocks.
- Call `DetachMissingTaskLinksAsync` with the **complete** set of active plus completed, non-deleted task IDs after a full library read; never use a filtered task list. It only removes links, not events.
- Calendar toast activation arguments: `calendarEventId` and `calendarScope`. Compare the latter with `CalendarReminders.Scope(currentWorkspace)` before opening the event. Task toast arguments remain unchanged.
- Dispose the provider on shutdown after outstanding operations finish. Account transitions while a dialog/file picker is open cannot apply a stale dialog to the new workspace.

## Source checks actually performed

- Parsed project/XAML XML and checked handler references using `apps/windows/scripts/check_sources.py`.
- Parsed C# grammar with tree-sitter using an isolated temporary Python environment.
- `git diff --check` reported no whitespace errors at the time of the calendar pass.
- Reviewed the pinned Ical.Net v5.2.4 sources/API and native WinUI control documentation. These source checks do **not** prove .NET semantics, NuGet compatibility, XAML compilation, runtime access, accessibility or notification delivery.

`CalendarTests.cs` contains isolated SQLite regression scenarios for workspace isolation, retained events after task removal, field merge and CAS, stale drag/Undo, all-day exclusive ends, DST, read-only ICS, recurrence exclusions/overrides, UTF-8 export, visibility and rollback. They have not been executed.

## External subscriptions

Takt checks a saved iCal link every 15 minutes while the calendar panel is open. Refresh subscriptions checks immediately. Conditional requests use the provider ETag when supplied. Removal disconnects the feed, and malformed/failed responses keep the last valid calendar. The feed sends no Takt credentials. The transport accepts HTTPS and same-origin redirects.

Google or Outlook may offer private or published iCal links. Direct calendar account sign-in, CalDAV write access and remote event edits are future provider integrations.

## Windows acceptance — all pending

- [ ] Subscribe with an authorized iCal link, test conditional refresh, invalid response, cancellation and removal, and verify stable event identity and scope across refreshes.

- [ ] Restore/compile pinned Core and WinUI on Windows 11; execute all Core tests in isolated temporary databases.
- [ ] Create/edit all-day and timed events around midnight, spring/fall transitions, unusual offsets and locale week starts.
- [ ] Check all-day inclusive editor/exclusive ICS ends, multi-day continuation drag, stale-editor merge and Undo after independent metadata changes.
- [ ] Verify standalone and task-linked events never alter task deadline, folder or Today/This Week/Month membership.
- [ ] Switch between tasks and verify that Scheduled shows the selected task’s blocks. Delete tasks locally and remotely with the calendar closed, including completed tasks. Verify their events and alerts persist with links removed after confirmed deletion.
- [ ] View/import/export real ICS fixtures with IANA/custom VTIMEZONE, floating times, RRULE/RDATE/EXDATE, overrides, RANGE exceptions, zero-duration events and unknown alarms; verify unsupported snapshots show warnings while local events remain usable.
- [ ] Verify account isolation while editor, confirmation, export/import picker and notification activation are pending.
- [ ] Verify density marks when browsing months without choosing a date, selection retention after refresh and empty/hidden calendar behavior.
- [ ] Verify keyboard/Narrator/high contrast, themes, 100–200% scaling, narrow panel and long titles/notes; test native drag with touch/mouse.
- [ ] Verify multiple relative/absolute alerts, edit/delete cancellation, combined 64-slot budget, clock/time-zone changes, restart, disabled Windows notifications and cold/warm toast activation.
- [ ] Decide calendar account integration and distribution/update identity separately before claiming cross-device calendar sync or releasing.

Primary API references: [Ical.Net v5.2.4 source](https://github.com/ical-org/ical.net/tree/v5.2.4), [Ical.Net v5 migration](https://github.com/ical-org/ical.net/wiki/API-Changes-v4-to-v5), [WinUI CalendarView](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/calendar-view), [native density marks](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.calendarviewdayitem.setdensitycolors), [WinUI desktop file picker interop](https://learn.microsoft.com/en-us/windows/apps/develop/interop/), [Google Calendar iCal links](https://support.google.com/calendar/answer/37648), [Outlook iCal subscriptions](https://support.microsoft.com/en-us/outlook/add-a-calendar-in-outlook-com-or-outlook-on-the-web).
