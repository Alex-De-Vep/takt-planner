# Takt for Windows guide

Takt brings tasks, notes, a local calendar and AI chat into one workspace. Use the navigation on the left, the list in the middle and the editor beside it. Calendar and AI chat open in the right panel.

## Getting started

- Choose Inbox to create a task, or open All Notes to write a note.
- Use custom folders to organize related work. A custom folder can show its tasks or notes.
- Open Calendar to plan events or time blocks. Open AI chat when you want help drafting or reviewing work.
- The app menu includes Welcome and Guide. Open Welcome again whenever you want a starting point.
- The welcome screen opens sections without adding sample content. Get started closes it and leaves your current library in place.

You can work in the local library without signing in. A Takt account can synchronize tasks and current shared-format notes. Windows calendar events, audio files and AI conversation history remain on this device.

## Tasks and planning lists

Create a task with the new-task button or Ctrl+N. Select it to edit its title, description, folder and subtasks. Text saves after a typing pause and before navigation. Ctrl+S saves explicitly.

- Inbox contains tasks that have not been placed in a custom folder.
- Today is your focus list. Use a task's star to add or remove it.
- This Week and Month are planning lists. Assign tasks through the app's planning controls or by dragging them onto a planning section.
- All Tasks shows tasks across folders. Search matches titles and descriptions within the selected section.
- The checkmark completes a task. Completed tasks appear in their expandable group and can be reopened and edited.
- Add subtasks in the task editor. Complete or reorder them independently; the task shows their progress.

Use the folder picker or drag a task onto a custom folder to move it. Deleting a custom folder moves its tasks to Inbox. Dropping a task on Today changes its focus star without changing its folder.

Delete in the task list immediately removes the selected task without another confirmation. The toolbar delete command asks for confirmation. Task deletion is separate from the notes' Recently Deleted section; check the selected task before using Delete.

## Deadlines and reminders

The clock button in the task toolbar opens Task deadline. Choose a date, optionally enable a time, and save. A task with a deadline shows it in the list. Remove the deadline from the same control when it is no longer needed.

A deadline is independent of Today, This Week and Month. Setting or changing a deadline does not move a task into those planning lists or change its star. A calendar time block is also separate from the deadline.

- A date-only deadline keeps its calendar date without an hour.
- A timed deadline also records its time zone and exact instant.
- A time skipped or repeated during a daylight-saving clock change needs a different time; Takt does not guess which instant you meant.
- Enable deadline notifications or a daily review reminder in Settings. Date-only deadlines use your chosen reminder hour. Choose Test notification in Settings to schedule a test after five seconds.

Windows notifications must be enabled for Takt. The app refreshes a limited schedule of upcoming reminders while it is open or activated. This Windows version does not run a permanent background reminder service. A notification for another library requires opening the matching library before its task can be shown.

## Notes

Open All Notes, Unfiled Notes or the Notes view of a custom folder. Create a note with the new-note button or Ctrl+N, then edit its title and body. Notes save after a pause and before you switch to another note. Ctrl+S also saves the open editor.

- Use the formatting toolbar for bold, italic, underline, headings, lists and checklists.
- Add links with the link button. Insert image accepts common image files and saves a bounded PNG representation.
- Pasted text adopts the note font and size. Supported emphasis and list markers are kept in the shared representation. An unsupported paste is undone rather than leaving content that cannot be saved.
- Pin a note to keep it above other notes in the current list.
- Search within the current note section. Use the folder picker or drag a note to a folder to move it.
- If concurrent changes cannot be saved as one version, Takt keeps a conflict copy instead of silently replacing your edits.

This Windows version supports only the current shared note format, version 1, including inline images. It does not open or convert old note formats. Notes that use another format require a compatible current client; there is no legacy-note migration in Windows.

## Recently Deleted notes

Move a note to Recently Deleted with the trash button. Deleted notes are read-only until restored. Restore brings the note back for editing.

After 30 days, the note's retained text, images and local recording content are permanently cleared. This is different from deleting an ordinary task. Export anything you need to keep before it expires.

## Recording and transcription

Choose an editable note and start a voice recording from its toolbar. Pause, resume and stop controls show the elapsed time. You can switch notes or open tasks while recording; the recording stays attached to its original note. The app also keeps recording controls available outside that note.

Record system audio and microphone captures your microphone plus sound from applications on the current Windows output device. It is not limited to one browser tab. Takt asks for confirmation before this broader recording starts. Windows microphone privacy settings and available devices determine what can be captured.

- You can keep several recordings with one note. Each recording is limited to 30 minutes.
- Open a saved recording to play it, rename it, export WAV or open its folder in File Explorer.
- Audio files remain on this Windows device. They are not included in task or note synchronization.
- Stop recording before changing libraries or closing Takt.

For transcription, configure a compatible transcription endpoint, model and API key in the notes menu. Starting transcription asks you to confirm the destination and upload. A provider may charge for the request.

Long recordings are processed in segments. Finished segments are saved locally. After a failure, retry the unfinished segment, skip it, or keep the saved progress for later. A skipped segment is marked in the preview. Starting a new transcription clears segment progress only after confirmation; the recording and saved preview are kept.

Review or edit the saved transcript before appending it. The text goes to the recording's original note, even if another note was selected. The original note must still exist and be editable. Appended text can synchronize with the note; the audio and local progress files do not. Pause transcription before switching libraries.

The Windows transcription connection currently supports OpenAI-compatible audio/transcriptions endpoints. It does not yet share every chat provider's transcription support or browser account sign-in.

## Calendar and time blocks

Open Calendar from the top bar. Select a day in the month view, then choose Day, 3 days or Week. Columns switches between a list agenda and day columns. The arrows move through agenda periods; Today returns to the current day.

- Use + Event to create an event. Set its title, start and end, optional all-day dates, location, notes and alerts.
- Select an existing local event to edit it. Events can also be moved to another day by dragging; use Undo after a move when needed.
- Choose a task and use Plan time or the calendar's For task button to create a linked time block.
- One task can have several time blocks. Its editor lists them even when the calendar panel is hidden.
- Deleting a task keeps its events; their task links are removed after the deletion is confirmed.

Windows events and links are local to the current library on this device. They do not synchronize with macOS or Android calendars. Read-only external subscriptions appear beside local events. Provider account sign-in and remote editing are separate integrations.

Creating, moving or removing an event does not change a task's deadline, Today star, This Week plan or Month plan.

## Calendar files and alerts

Open Calendar settings from the calendar panel or from Settings. Use Subscribe by link with an HTTPS or webcal iCal address from Google Calendar, Outlook or another calendar provider. A subscription is read-only and refreshes while the calendar panel is open. Choose Refresh subscriptions to check immediately. If the provider is unavailable, the previous contents stay visible. Keep private links secret.

Choose Import ICS snapshot for a one-time copy. To disconnect a subscription or remove an import, select it in Calendar settings and choose Remove selected calendar.

Takt can show supported recurring events from a snapshot within bounded date ranges. Unsupported or problematic content produces a warning while your local events remain available. Exporting a snapshot preserves its original file.

Local event alerts use Windows notifications and a limited upcoming schedule. The external provider manages alerts for imported and subscribed events. Keep Windows notifications enabled and review the event's alert settings if a reminder is missing.

## AI connections and models

Open AI chat from the top bar, then open its connection settings. Settings also provides access to AI connections.

- Choose Continue with ChatGPT and authorize plan usage in your browser. Pick the models you want to use. Select an existing ChatGPT connection and choose Renew selected ChatGPT account to sign in again.
- Choose Continue with OpenRouter and authorize in your browser. Pick accessible models and save the connection.
- For GitHub Copilot, install Node.js 22.12 or later. Select GitHub Copilot, choose Copy Copilot launch command, paste it in PowerShell, and sign in if prompted. Paste the local connection code and load its models. Keep the terminal open while chatting.
- Select OpenAI API, Claude, Gemini, DeepSeek, Mistral, Grok, GLM, MiniMax API or MiniMax M Plan to enter the corresponding key. Select your region for QwenCloud or Kimi. LiteLLM and Custom API also accept a server address.
- For YandexGPT Pro, enter the Cloud folder ID and its API key. The model catalog button offers the model in that folder. For GigaChat, enter the Authorization Key and choose the correct API edition. Windows must trust the provider’s certificate.
- Load a catalog or enter model IDs supported by your account, then choose a model in the chat panel.

Keys and tokens are protected for the current Windows user. Changing a connection’s provider, server, region or authentication settings requires entering the appropriate key. Model access depends on your provider and plan.

## Sending messages and context

Write a message and select Send, or press Ctrl+Enter while the message field has focus. Send becomes Stop during generation. Stopping keeps any partial reply in the conversation. Use Copy on a message for its complete text, or select and copy just a fragment.

Folder, Task and Note context start unchecked. Check only the context you want to attach to your next message. Before sending, Takt shows the captured content, the destination provider and the selected model. Confirm Send message to proceed, or cancel to keep your draft.

The provider receives your message, conversation history and chosen context. Earlier context remains part of that conversation's history even if you uncheck it for a later message. Start a new conversation when you want a fresh history.

AI messages are selectable text. Use New conversation to start another thread, or open Conversation history to return to a previous one. Deleting a conversation or clearing history affects only that library's local Windows chat history; it does not remove tasks, notes or events.

## Reviewing AI proposals

The assistant can propose tasks, task changes, notes, note changes and local calendar events. A proposal card is a draft, not an executed action.

- Open Review change to inspect and edit the proposed fields before applying them.
- Task deadlines remain independent of Today planning. Proposed subtasks are added to the task.
- Note changes offer Append and Replace. Append keeps existing text, formatting and images. Replace changes the text and formatting while keeping existing images at the end.
- Event proposals create events in the local Windows calendar.
- Cancel leaves your library unchanged. Dismiss records your decision in conversation history. Refresh context reloads the original attached record so you can review the proposal against its latest content.

Edits target the captured task or note. If it changed, refresh the proposal context and review the generated text again. Refreshing context does not rewrite the proposal for you. Only apply it after checking that the text still fits the newly captured record.

Handled proposals are disabled to prevent repeat application. If the result cannot be confirmed, check your library before creating another proposal. Incomplete or malformed tool responses never become executable changes.

## Accounts and synchronization

Open the account controls to sign in, create an account, verify your email or reset your password. Enter the eight-digit email code in Takt. If a code expires, request another one. Sign in with the new password after a reset. Your server address is an editable HTTPS origin.

The local library stays separate from an account library. Signing in does not replace cloud data with local data. Creating a cloud library or including local tasks requires an explicit choice. Notes have a separate command to copy local notes into an account as new copies.

Tasks and current-format notes synchronize after edits, on activation, on manual retry and periodically while the app is open. On compatible servers, live change signals also trigger a refresh. Cached data and pending edits remain available when the network is unavailable. A sync warning does not mean you should delete your local cache.

Signing out returns to the local library. The account's cache and pending operations remain separate and are restored when you sign in to that same server and library. A session problem may require signing in again.

Calendar events and links, recording files, transcription progress, connection settings and AI conversation history are not part of task and note synchronization.

## Backups and local files

Open Settings → Library backup to save the open library as one .taktbackup file. It includes tasks and subtasks, current-format notes with inline images, recordings and saved transcript previews, local events and their task links, imported ICS files, and AI conversation history. Keep the unencrypted file private. Takt for Windows reads this archive format.

Restore into a separate library, then restart Takt. To switch back or open a different restored library, use Choose library for next launch in the same menu. The restored library opens locally. Reconnect any cloud account, AI provider or external calendar subscription separately.

Task-only and note-only JSON export/import remain available. Those commands import copies into the local library. Recording uploads that are still in progress and credentials are excluded from library backups.

Windows stores its local caches and settings under %LOCALAPPDATA%\Takt\Windows\. Treat exported task and note files as private content. Exported backups do not contain your saved API keys or account session credentials.

## Contact support

Open Contact support from Help or Settings and sign in if prompted. Your message includes the Takt version, Windows version and the current time on your device with its UTC offset. You can add a subject and a reply address. When you use the account address, leave the reply field empty.

Copy the receipt code after sending. If the request is interrupted, open the form again and send the saved request unchanged to recover the same receipt.

## Windows shortcuts and layout

- Ctrl+N: create a task in Tasks, or a note in Notes.
- Ctrl+Shift+N: create a custom folder.
- Ctrl+F: focus search in the current task or note section.
- Ctrl+S: save the open editor.
- Ctrl+Enter in the task workspace: complete or reopen the selected task.
- Ctrl+Shift+S in the task workspace: add or remove the task from Today.
- Ctrl+Enter in the chat message field: send a message or stop generation.
- Delete in a task or note list: delete the selected task or move the selected note to Recently Deleted.
- Enter in the subtask field: add a subtask. Shift+Enter keeps a line break.
- Ctrl+C after selecting message or guide text: copy it. The task editor also has Copy whole task.

Drag a panel boundary to resize the list, editor or right panel. Its grab area is an invisible 16-DIP target; it does not add a visible stripe or hover highlight. Focus the resize control with the keyboard, then use Left or Right to resize, or Home to restore its default width.

Narrow windows show the list or editor at a time and provide a Back button. Choose light, dark or system appearance in Settings. Application labels and this guide currently use English; native date and time controls follow Windows preferences.

## When something needs attention

- If a draft cannot be saved, keep it open and check the warning. A remotely removed task or note may offer recovery as a new copy.
- If synchronization fails, check the account and server address, then retry. Cached edits stay local while waiting to synchronize.
- If a microphone recording fails, review Windows microphone privacy settings and the input and output devices.
- If a model catalog or AI reply fails, check the API address, format, key, selected model and provider access. Catalog loading and sending are separate explicit requests.
- If a proposal is stale, refresh its context and review the unchanged generated text before applying again.
- If a notification is missing, check Windows notification settings and the corresponding task or local event alert.
- If an imported calendar shows a warning, keep using your local calendar and review the original ICS file separately.

When reporting a problem, include your Windows version and the action that failed. Keep API keys, passwords, exported backups and private task or note content out of public reports.
