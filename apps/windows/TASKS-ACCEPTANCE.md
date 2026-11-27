# Task milestone acceptance

Source exists for the workflows below. None of these runtime checks is marked as passed: the owner requested no Windows build yet. Notes, calendar and AI source work follow the task implementation. Every native acceptance item remains pending until the separately authorized Windows validation stage.

## Source and Windows tools

- [ ] Restore pinned packages, compile Core and WinUI, and resolve every XAML/native API issue on Windows 11.
- [ ] Execute Core regression tests using isolated temporary SQLite databases.
- [ ] Check English labels, Windows localization requirements, UI Automation names, Narrator and keyboard navigation.
- [ ] Verify system, light, dark and high-contrast themes at 100%, 150% and 200% scaling.
- [ ] Verify x64 and ARM64 separately; do not infer runtime compatibility from project declarations.

## Local task parity

- [ ] First launch has an empty local library, no sample tasks and no server requests.
- [ ] All standard sections and custom folders show the correct active-task counts.
- [ ] Today contains starred tasks independently of deadlines and folder membership.
- [ ] Create, rename, reorder and delete folders; tasks move to Inbox after folder deletion.
- [ ] Create a task from each section. Today stars an Inbox task; All Tasks creates an Inbox task.
- [ ] Complete, reopen, star and unstar tasks from the list and editor without unintended selection changes.
- [ ] Search title and description in the current section, including completed tasks.
- [ ] Save text after a typing pause and before navigation and closing. Failed saves keep the window and draft open.
- [ ] Create, rename, complete, reorder and delete subtasks; verify progress and restart persistence.
- [ ] Move active and completed tasks by the folder picker; drag tasks onto sidebar sections.
- [ ] Select date-only and timed deadlines; clear them; verify folder/Today membership remains unchanged.
- [ ] Preserve a synced deadline's zone until the user edits it; test a DST gap, repeated time, midnight and zone changes.
- [ ] Delete the open task and its checklist without opening a neighboring task.
- [ ] Resize panels with the invisible 16-DIP target; narrow the window, edit and return to the task list.
- [ ] Export/import a local task backup without credentials; verify parent remapping, Unicode and invalid backup rejection.
- [ ] Export one library archive, restore separately, restart and switch back. Verify IDs linking events, notes, folders, recordings and conversations. Reject oversized, duplicate and unsafe archive entries without changing the active library.

## Account and offline behavior

- [ ] Use a dedicated test account. Test registration, verification resend and password reset, including invalid and expired codes. Sign in with the new password and confirm that the local library remains available.
- [ ] Test sign-in, empty-library confirmation and optional explicit local import.
- [ ] On a server advertising live task and note signals, receive changes from another device, reconnect after a dropped stream and sign out with a read pending. Verify older servers keep polling.
- [ ] Submit a support request with test content, lose the response, reopen the saved draft and verify the same receipt is returned. Verify the draft is isolated by account.
- [ ] Sign-in never overwrites an existing cloud library. Cancelled or failed sign-in leaves local tasks intact.
- [ ] Edit simultaneously on Windows and macOS/Android; unrelated fields merge and deletions remain deleted.
- [ ] Disconnect networking, edit, restart, reconnect and observe the same outgoing operation IDs.
- [ ] Lose a mutation response after server commit; retry without duplicating tasks or edits.
- [ ] Expire a cursor; replace confirmed data without losing local pending edits.
- [ ] Lose a recoverable refresh response, restart, and reuse the persisted operation ID.
- [ ] Check a legacy server's uncertain refresh requires sign-in rather than replaying a used token.
- [ ] Revoke a session; keep cached tasks/queue, request sign-in and resume on the same library.
- [ ] Sign out and back in; account and guest tasks remain separate. Open a second process and verify one sync owner.
- [ ] Test HTTP 429/backoff, 503, certificate errors, clock skew and rejected operations without discarding data.
- [ ] Delete the task on another device while typing; preserve and explicitly recover the local draft.

## Windows integration

- [ ] Schedule a test notification and verify delivery after five seconds, replacement of an earlier pending test, and behavior when Windows blocks notifications.
- [ ] Enable deadline reminders explicitly; verify timed and date-only delivery while the app is closed.
- [ ] Edit, complete or delete a task and verify its pending reminder is replaced/cancelled.
- [ ] Enable daily review and weekdays-only behavior; verify nearest-reminder replenishment and system-time changes.
- [ ] Verify notifications are scoped to the active library and old account reminders are cancelled on switching.
- [ ] Test cold/warm notification activation alongside single-instance redirection and select the intended task.
- [ ] Verify offline reminders, restart, Windows Focus settings, blocked notifications and scheduling limits.
- [ ] Decide and test the final MSIX identity/signing/update route before distribution.

## Related module acceptance

- [Current shared notes v1](NOTES-ACCEPTANCE.md), including UTF-16 formatting and local recording differences.
- [Calendar events](CALENDAR-ACCEPTANCE.md), including the local provider and pending account adapters.
- [AI chat](AI-ACCEPTANCE.md) and [OpenRouter browser authorization](OPENROUTER-OAUTH.md).

Their source implementation does not replace the Windows acceptance above.
