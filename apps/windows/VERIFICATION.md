# Source verification — 27 November 2026

Implementation host: macOS / Apple Silicon. The owner requested **no Windows build**. This report separates source inspection, prototype checks and unexecuted Windows acceptance.

## Latest completed source checks

- Parsed all 86 C# files with tree-sitter C#: no syntax errors.
- Parsed 6 XAML files, project files, Directory.Build.props, solution and application manifest as XML.
- Checked project references, the bundled Help content path and **106** unique XAML event-handler declarations across partial classes.
- Checked the task layout preview's JavaScript syntax, unique element IDs, static element references and offline-only behavior.
- Parsed Copilot bridge JavaScript with Node, checked its four packaged resource paths and confirmed the shared lockfile contains the pinned Windows x64 and ARM64 binaries.
- Matched the Calendar settings, Library backup and AI provider guide to the Windows dialogs, and reviewed refresh, restore and credential handling against those entry points.
- Checked trailing whitespace across Windows source/docs, including untracked files: zero findings. `git diff --check -- apps/windows` also passed.
- Performed repeated independent source reviews against the English app Help and existing server/mobile/macOS contracts. Confirmed data/scope/lifecycle findings were fixed and reread; see DEVELOPMENT-AUDIT.md.
- Checked seven server endpoint paths and request fields against the repository OpenAPI contract for account challenges, support and live change signals.
- Compared relevant WinUI APIs with Microsoft documentation, Ical.Net with pinned v5.2.4 sources, and AI/OAuth wire behavior with primary provider documentation.

Command actually run (using an isolated temporary Python environment):

```sh
python apps/windows/scripts/check_sources.py --csharp
```

The script does not invoke .NET, NuGet, MSBuild or a native application.

## Regression sources — not executed

There are **140 test methods / 191 cases** in source (129 Facts, 11 Theories, 62 InlineData rows):

| Area | Source cases | Main coverage |
| --- | ---: | --- |
| Tasks, storage and sync | 28 | Planning/deadline independence, transactions, backup IDs, protocol bounds, refresh recovery and live change frames |
| Current-format notes | 48 | v1/UTF-16/images, digests, conflicts, revision acknowledgement, import and expiry |
| Calendar | 16 | Field merge, stale moves/Undo, time zones, all-day ends, ICS and refresh identity/removal |
| Atomic reviewed task edits | 11 | Stale text/items, metadata acknowledgements, account isolation, identifier reuse, rollback |
| Chat client/history | 38 | Bounded SSE/JSON, cancellation, context privacy, proposal validation, immutable history and persistent dismissal |
| OpenRouter OAuth | 41 | PKCE/state/nonce/Host, malformed callbacks, cancellation/drain, exchange bounds and redaction |
| Calendar and AI transport | 4 | iCal ETag and redirects, ChatGPT Responses completion, Yandex model and folder binding |
| Google Calendar and Outlook | 5 | Exclusive all-day ends, conditional mutation, Outlook field preservation, safe paging, token renewal |

These counts describe authored test cases. No test result is implied.

## Earlier task prototype inspection

The separate browser layout prototype was inspected in isolated Chromium in light/dark appearances. Navigation, starring, text edits, deadline changes, subtask creation, search and narrow-screen back navigation were exercised without script errors. Root/outer horizontal overflow was checked at viewport widths 1024, 736, 390 and 320 pixels: none observed.

That prototype uses fictional data. It does not execute XAML, render WinUI, connect accounts or validate the new native note/calendar/chat/welcome controls. No native Windows screenshot has been produced.

## Not performed

- NuGet restore, C# semantic/type checking, MSBuild, XAML compilation or package compatibility validation.
- .NET/Core test execution, SQLite execution for this client, native WinUI launch, real clipboard/audio/DPAPI/focus/accessibility testing, or actual notification registration/delivery/activation.
- External iCal network requests, Google Calendar or Outlook account authorization or API requests, recovery of an archive on Windows, PowerShell or Copilot CLI execution, AI authorization or requests, Takt account login, live-server sync or cross-device acceptance.
- Windows package generation, signing, publication, GitHub Actions, a release, commits or pushes for this implementation pass.

Source parsing cannot prove native API compatibility or correct runtime behavior. The pending scenarios are in TASKS-ACCEPTANCE.md, NOTES-ACCEPTANCE.md, CALENDAR-ACCEPTANCE.md, AI-ACCEPTANCE.md and OPENROUTER-OAUTH.md. Provider app registration and real-calendar acceptance, delegated Outlook mailboxes and series editing, remaining AI features outside chat provider connections, localization and distribution remain product and release gaps.
