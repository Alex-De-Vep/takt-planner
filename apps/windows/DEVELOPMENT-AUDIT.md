# Windows development audit

The audit runs against the current English app Help, the server OpenAPI contract and each platform's implementation. A source pass does not establish a working Windows build. Builds, .NET tests, live accounts, CI and releases are outside the currently authorized phase.

## Repeated review procedure

1. Compare the next module with Help and record explicit platform differences.
2. Implement domain behavior and native WinUI controls, using macOS only for panel arrangement.
3. Review data boundaries: workspace, persistent identifiers, concurrent edits, deletion and cancellation.
4. Parse C#, XAML and project references; inspect changes and add regression scenarios for significant data risks.
5. Run a second independent source review, fix findings, then repeat the checks for changed code.
6. Leave runtime acceptance items unchecked until executed on Windows with an isolated library.

Progress is driven by concrete findings, rather than unrelated changes made to keep the loop busy. User-requested stages are tasks, current v1 notes, calendar, then AI chat.

## Review findings addressed so far

- Reject malformed shared notes before changing the local cache, including required metadata, style ranges, Unicode and embedded image encoding.
- Normalize incoming UUIDs before conflict handling; compare acknowledgements with the bytes actually uploaded.
- Preserve local edits made during an asynchronous note save, and serialize note navigation/save actions.
- Keep recording tied to the original note and library; show recording controls when another document view is active.
- Save transcription progress per segment, including skipped parts; reopen and review text before insertion.
- Audit task draft baselines and note section selection during background reload/account changes.
- Isolate calendar cache/notification failures from tasks and notes.
- Give task and event notification schedules separate ownership and a combined bounded capacity.

See module acceptance files and VERIFICATION.md for the actual checks and remaining Windows verification. A pending review item or unchecked native scenario must not be described as completed functionality in a release.

## Later independent passes

- Rechecked original task Help: added delayed autosave, explicit whole-task copy, editor subtask progress, multiline subtask input and focus-scoped completion shortcuts.
- Corrected cancellation of deletion so it resumes autosave, bound Add subtask to the originally clicked task and used an atomic parent/content check before insertion.
- Rechecked chat lifecycle: clear previous-library history before a failed scope load, serialize history/settings operations, and drain modal operations during Stop/account changes/closing.
- Rechecked review application: canonical nested JSON fingerprints ignore transport acknowledgements; reject duplicate/reused checklist IDs and preserve note images.
- Rechecked calendar navigation after awaits: task planning and notification actions cannot target a newly switched library.
- Added native Welcome and bundled Guide, then checked guidance against the actual Windows controls. New data is never seeded automatically.
- Added OpenRouter browser authorization and reviewed PKCE/state/nonce/Host, bounds, cancellation, key protection and explicit model saving independently.
- Disabled implicit cookies/credentials in the shared AI transport and prevented a failed native progress dialog from starting browser authorization.
- Checked native resize API declarations: Thumb is sealed; the resize cursor belongs to a supported Grid subclass inside the existing invisible Thumb template.

## Follow-up against the app Help

- Implemented email challenge forms for registration, verification and password reset using the existing server routes.
- Added test notifications and support receipts. An interrupted support request reuses its original payload and identifier on an unchanged retry.
- Added advertised live task and note change signals to the existing sync loop, with cancellation by account and periodic fallback.
- Routed Calendar settings through the main Settings dialog. Rechecked selection and link cleanup with the panel closed.
- Bound refreshed chat proposals to the original task or note, saved dismissals, and serialized proposal review with history changes.
- Re-ran static source checks after each implementation group. The test acceptance lists mark the new workflows for Windows verification.

The latest source-only pass and test-source inventory are recorded in VERIFICATION.md. Remaining runtime and product gaps are explicit in the module acceptance files; no Windows acceptance item has been marked passed.

## External calendars, archive and provider pass

- Added read-only iCal subscriptions alongside the writable local calendar. Verified conditional refresh, stable calendar identity, bounded downloads and protected URLs.
- Added a Windows library archive with recordings and saved transcript previews. Restore stages separate databases and keeps IDs needed for note folders, task calendar blocks and chat context.
- Added named AI provider forms with region, folder and edition controls. Added ChatGPT browser authorization and Responses, plus an explicit PowerShell launch path for the existing Copilot bridge.
- Compared the UI paths with Help after each step. The source review followed provider contracts without real sign-in or service calls.
