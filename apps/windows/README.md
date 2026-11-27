# Takt for Windows

The Windows client is being implemented in **C# / WinUI 3**, with the **Windows App SDK** and native Fluent controls. Its panel arrangement follows the macOS app: navigation on the left, task list in the middle, task editor on the right. Windows owns the typography, controls, selection, focus, dialogs, date/time pickers, theme resources, and Mica backdrop.

**Status: source implementation, not a verified Windows build.** No restore, build, .NET test execution, installer generation, Windows launch, or live-server test was performed for this implementation. The interactive preview is a layout prototype with fictional tasks; it does not execute XAML or connect to the server.

## Delivery order

1. Tasks and synchronization.
2. Current shared notes v1, recording and transcription.
3. Calendar events and scheduling.
4. AI chat and individually reviewed proposals.

All four stages now have source implementations. A native first-run Welcome and bundled English Guide describe the Windows workflows without adding sample data. Repeated Help-based reviews are recorded in [DEVELOPMENT-AUDIT.md](DEVELOPMENT-AUDIT.md). The module checklists describe platform differences and pending native acceptance; source presence does not establish release readiness.

## Task source implementation

- Inbox, Today, This Week, Month, All Tasks, and custom folders with active-task counts.
- Create, rename, reorder, and delete custom folders. Deleting a folder moves its tasks to Inbox.
- Create, edit, complete, reopen, and delete tasks; edit completed tasks as well.
- Independent completion and star buttons in each task row. Today is a focus list, not a deadline query.
- Search title and description inside the selected section; completed results stay in an expandable group.
- Task description with simple list continuation; editable, reorderable subtasks with completion progress.
- Move tasks with the folder picker or drag them onto sidebar sections. Dropping on Today stars the task without changing its folder.
- Date-only deadlines or deadlines with a time. IANA time zones and UTC instants match the existing protocol. DST gaps and ambiguous local times require a different time.
- Local SQLite storage, local task backup export/import, and a distinct cached workspace per server/account.
- Optional deadline notifications, daily review reminders and a five-second test notification use native Windows scheduled toasts. Nearest 32 task reminders are refilled on changes, activation and the 30-second timer; this is not a continuously running background service. Delivery and activation need Windows acceptance testing.
- Native light/dark/system appearance; adaptive narrow-window editor; a 16-DIP invisible list/editor resize target.
- Keyboard shortcuts: Ctrl+N new task, Ctrl+Shift+N new folder, Ctrl+F search, Ctrl+S save, Ctrl+Enter completion, Ctrl+Shift+S Today, Delete in the task list. The editor has an explicit Copy whole task command.
- Text saves after a typing pause and before task/folder navigation and window closing. A dirty draft of a remotely deleted task can be recovered as a new task.

Application labels currently use English; native date/time presentation follows Windows. Localization into Russian and other languages is a separate release-readiness item. Windows-only notification registration, activation, focus behavior, accessibility and XAML API compatibility are source work pending a real Windows run.

## Notes source implementation

- All Notes, Unfiled Notes, Recently Deleted, and the Notes view inside custom folders.
- Native rich-text editing, shared v1 formatting, links, PNG images, search, pinning, folder selection and drag to folders.
- Delayed autosave and save before navigation; concurrent remote changes preserve a local conflict copy.
- Shared cloud notes use the existing `/v1/notes` API, conditional revisions and exact document digests. Failed downloads cannot authorize overwriting remote content.
- Recently Deleted is read-only until restored. After 30 days, retained text, images and local recording content are cleared.
- Microphone and optional system-output recordings stay on this device. Recording controls remain available while changing notes or opening tasks. System output captures the selected Windows output device, rather than an isolated browser tab.
- Optional transcription uses an explicitly configured compatible endpoint and protected key. Uploads require confirmation; reviewed transcripts can be inserted into the original note. Audio and transcription need a dedicated Windows acceptance pass.
- Note-only JSON and individual WAV export are available alongside full-library backups.

Only current shared notes **version 1** are supported. There is no legacy-note loading, RTFD support, conversion or migration. Clipboard image extraction from native RichEdit content is part of the current editor, not legacy-note support.

See [NOTES-ACCEPTANCE.md](NOTES-ACCEPTANCE.md) for the Help audit and outstanding runtime checks.

## Calendar source implementation

- An additional right panel with a native month calendar and Day / 3 days / Week agendas; list and column layouts.
- Local one-off events, all-day events, notes, location, multiple relative or absolute alerts, drag to another day and Undo.
- Several calendar blocks can link to one task. They appear in its editor even when the calendar is hidden. Deleting a task keeps its events; links are removed after confirmed deletion.
- A writable SQLite calendar on this device and read-only ICS snapshots, including bounded recurrence expansion and original-file export. A problematic snapshot shows a warning while local events remain available.
- Nearest 32 local event alerts use a separate native notification schedule from the 32 task reminders.

Events and links are local to the current Windows workspace. External iCal links can be subscribed to for live read-only updates. Direct provider account sign-in and remote edits remain open. Alerts from imported or subscribed events stay with their calendar provider. None of these events changes a task deadline, Today star or planning folder. See [CALENDAR-ACCEPTANCE.md](CALENDAR-ACCEPTANCE.md).

## AI chat source implementation

- A native right panel, selected connection/model, new conversations, scoped local history, copyable messages and streaming Send / Stop.
- Browser authorization for ChatGPT and OpenRouter, a local GitHub Copilot bridge, and named API connections for OpenAI, Claude, Gemini, DeepSeek, Mistral, Grok, GLM, MiniMax, QwenCloud, Kimi, YandexGPT, GigaChat and LiteLLM; configurable base addresses, model catalogs or manual model IDs. HTTPS is required except for a literal loopback/localhost gateway.
- Keys protected with Windows DPAPI and bound to the connection address and protocol. Opening the application makes no AI requests.
- Folder/task/note context starts unchecked. Before sending, a review shows attached content and identifies the provider receiving the conversation history.
- Task, note and local event proposals require individual review. Dismissals stay in local history, and refreshing a proposal loads the original item. Task edits check current content atomically; note edits check their captured digest and preserve concurrent versions. Stable creation IDs prevent duplicate creation on retries.
- Note append retains existing formatting and images. Replacing text keeps existing images at the end. Partial or malformed tool calls never become executable proposal cards.

History is local to this Windows device and library. Reasoning controls, usage reporting, Markdown rendering, chat attachments and broader transcription provider support remain separate work. See [AI-ACCEPTANCE.md](AI-ACCEPTANCE.md) and the [OpenRouter OAuth review](OPENROUTER-OAUTH.md).

## Storage and synchronization

`Takt.Core` contains task and note rules, SQLite stores, HTTP client, response validation and synchronization engines; it does not depend on WinUI. `Takt.Windows` supplies the UI, credential protection, native reminders and file pickers.

- Separate task, note and calendar SQLite caches and preferences live under `%LOCALAPPDATA%\Takt\Windows\`.
- Local entities, pending operations, acknowledged changes and cursors use explicit transactions. Snapshots replace confirmed data while preserving the outgoing queue.
- Only edited fields are sent. Stable operation IDs support safe mutation retries, and version stamps implement protocol 1's field ordering.
- Revision/cursor bounds, library identity, entity identity, acknowledgement order, UTF-8 limits and serialized batch size are checked.
- Refresh credentials are protected with DPAPI for the current Windows user and bound to the server/library scope. Access tokens stay in memory. Passwords are not saved.
- Servers advertising `refreshOperationVersion: 1` use a persisted refresh operation ID across uncertain responses. For older servers an interrupted rotation requires sign-in; the library and pending edits remain cached.
- Sign-in uses the current Takt server by default, with an editable HTTPS origin. Redirects are not followed. Registration, email verification and password reset use the server’s existing email challenges.
- Signing in preserves the local library. Creating a cloud library and including local tasks require separate explicit choices. Existing cloud data is never replaced by the local library.
- Synchronization runs after edits, on activation, on manual retry and every 30 seconds while the client is open. Failed edits remain visible for explicit review/discard. HTTP 429 respects Retry-After.
- Compatible servers send live task and note change signals. The client groups nearby signals, catches up after reconnecting and continues periodic sync during outages.
- Sign-out switches back to the local library, retaining the account cache and queue. Signing in to the same server/library restores them.
- Contact support with a signed-in account. An interrupted submission keeps a Windows-user-protected draft so retrying the same request can recover its receipt.
- Settings → Library backup exports one Windows archive with tasks, notes, recordings, saved transcripts, local events and links, ICS imports and chat history. Restore prepares a separate local library for the next launch. The archive is unencrypted and excludes sessions, provider keys and live subscription links. Task-only and note-only JSON remain available for copying individual sets of content.

Source of truth: [OpenAPI](../../server/docs/openapi.json), [protocol guide](../../server/docs/API.md). The server does not need a separate Windows-specific task API.

## Project layout

```text
src/Takt.Core/           Portable domain rules, wire records, SQLite and sync
src/Takt.Windows/        Native WinUI window and Windows adapters
tests/Takt.Core.Tests/   Regression scenarios (not executed yet)
design/                 Interactive layout prototype, sample data only
scripts/                Source checks that do not build the application
*-ACCEPTANCE.md          Per-module Help parity and Windows acceptance
```

Open `Takt.slnx` with a .NET 10 capable editor. Dependencies are pinned in the project files. The initial development app is unpackaged and self-contained; MSIX identity, signing, distribution and update behavior need a separate packaging pass.

## Source-only checks

From the repository root:

```sh
python3 apps/windows/scripts/check_sources.py
# Optional C# grammar parsing, using tools installed in your own environment:
python3 apps/windows/scripts/check_sources.py --csharp
```

The optional parser needs `tree-sitter` and `tree-sitter-c-sharp`. JavaScript syntax checking uses Node.js when available. These checks parse source and XML and check references; they do **not** validate WinUI compilation, native API availability, NuGet compatibility, or runtime behavior.

## Future Windows verification — not run

Use Windows 11, .NET 10, Windows SDK 10.0.26100, and WinUI development tools. The following are commands for the later validation stage, not a record of successful execution:

```powershell
dotnet test apps/windows/tests/Takt.Core.Tests/Takt.Core.Tests.csproj
dotnet build apps/windows/src/Takt.Windows/Takt.Windows.csproj -p:Platform=x64
# ARM64 target, once x64 has been verified:
dotnet build apps/windows/src/Takt.Windows/Takt.Windows.csproj -p:Platform=ARM64
```

No GitHub Actions workflow was added, so this change does not trigger a Windows build automatically. Before release, follow all module acceptance checklists, verify behavior on real Windows, and test with a dedicated account and isolated database. Never point automated tests at a personal task library.

[Project overview](../../README.md) · [WinUI 3](https://learn.microsoft.com/en-us/windows/apps/winui) · [Windows design guidance](https://learn.microsoft.com/en-us/windows/apps/design/)
