# Notes: Help parity and Windows acceptance

Source of truth: `apps/macos/Packages/PlannerLocalization/Sources/PlannerLocalization/Resources/en.lproj/Help.md`, **Notes**, **Recordings and transcripts**, **Backups**, and the server note API. This is a source audit, not evidence of an executed Windows application.

## Implemented in source

- All Notes, unfiled notes and notes inside a custom folder; shared sidebar layout.
- Create, edit, search title/body in the selected view, pin above other notes, move with the folder picker or drag to a folder.
- Current shared v1 text and style ranges, links, PNG images, UTF-16 boundaries, normalized newlines and native clipboard image handling.
- Delayed autosave, save on navigation, account-scoped SQLite cache, revision/digest-guarded sync and conflict copies.
- Deleted-folder notes remain available. Recently Deleted is read-only; restore and 30-day content cleanup are separate operations.
- Device-local microphone/system-output clips, pause/resume/stop, original-note association and recording controls outside the active editor.
- Confirmed transcription upload, segment progress and reviewed insertion into the original note. Recordings are not part of note cloud sync.
- JSON export/import validates all notes before committing copies; image data is included, audio export is separate.

No old-note/RTFD reader or migration is included.

## Required on Windows — not run

- [ ] Restore/build/type-check all targets and execute Core test sources in an isolated directory.
- [ ] Create two notes, type during an autosave, change selection repeatedly and verify no edit is lost.
- [ ] Change folders, sections and account while dirty; reopen the app and compare saved text.
- [ ] Round-trip emoji, CRLF, mixed font sizes, overlapping native formatting, links, pasted and inserted PNG images through macOS/Android/Windows.
- [ ] Download changed notes while editing; verify both conflict versions, retry after a lost upload acknowledgement and test 401/429/quota responses.
- [ ] Restore a recent deletion; expire a deleted note and verify text, images and local audio are removed.
- [ ] Record microphone plus system output, pause/resume, change notes, return to the original and inspect the saved clip.
- [ ] Close/change account during recording; verify the app asks to stop first.
- [ ] Rename, reveal, play and export multiple clips without using an external account.
- [ ] Use a dedicated transcription provider fixture: interrupted segment, resume, skip, reopen preview, insert once into the original note and inspect synchronized text.
- [ ] Verify keyboard navigation, focus, high contrast, Narrator, light/dark/system themes and narrow-window behavior.
- [ ] Reject malformed v1 documents and backups without modifying existing data.

## Platform differences and remaining scope

Windows recording captures an output device rather than the macOS Chrome-tab capture. Transcription is currently an explicitly configured compatible endpoint, not the full macOS provider catalog. The Windows library archive includes recordings and saved transcript previews. Provider credentials and unfinished transcription journals are excluded. These differences must stay visible in release documentation until implemented and verified.
