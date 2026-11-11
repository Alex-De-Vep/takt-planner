<p align="center">
  <img src="Design/AppIcon/tasks-icon-preview.png" width="112" alt="Tasks app icon">
</p>
<h1 align="center">Takt</h1>
<p align="center">Your tasks, their next steps, and time to work on them.</p>
<p align="center"><strong>English</strong> · <a href="README.ru.md">Русский</a> · <a href="README.de.md">Deutsch</a> · <a href="README.fr.md">Français</a></p>

<p align="center">
  <strong><a href="#install">macOS</a></strong> 26+ · Apple Silicon
  &nbsp; | &nbsp;
  <strong><a href="#android">Android</a></strong> 8.0+ · test APK
</p>

Takt brings tasks, a focused daily list, and your calendar together on macOS and Android. On macOS, you can keep your task library on your device without an account. Enable cloud sync to pick up your tasks on Android.

[Features](#features) · [AI chat on macOS](#ai-chat-on-macos) · [Getting started](#getting-started) · [Build](#build)

![Tasks with folders, a task editor, subtasks and the calendar panel](docs/screenshots/workspace-light-en.png)

*An actual app screenshot using fictional demonstration data.*

## Features

- **Folders:** each task belongs to Inbox, This Week, Month or a custom folder. Today shows starred tasks; All Tasks shows the full library ordered by creation date.
- **Move tasks:** drag a task onto a sidebar folder, or use “Move to Folder” in its context menu or the toolbar “…” menu. Dropping onto Today adds a star and keeps the original folder.
- **Focus:** starred tasks stay in Today until you unstar them, without changing their order.
- **Descriptions and subtasks:** plain text with list continuation, plus a checklist with completion progress.
- **Deadlines:** choose a date and optionally a time, independently of calendar events. System notifications follow deadline edits and are canceled when a task is completed or deleted.
- **Review reminder:** enable “Time to review your tasks” in Settings, choose a local time and optionally weekdays only. Off by default.
- **Calendar sidebar:** a compact month and a day, three-day or weekly agenda, with vertical and horizontal layouts.
- **Time for tasks:** create standalone events or schedule multiple time blocks for a task. Edit writable one-off events, drag them between days and undo a move.
- **Search:** find tasks by title and description within the current section.
- **Native macOS:** light and dark appearances, glass sidebars, keyboard shortcuts and Russian/English localization.

## AI chat on macOS

![The macOS assistant beside the task editor, with a draft task and its checklist ready for review](docs/screenshots/macos-assistant-en.png)

*In this example, the assistant drafts a task with a checklist. You can review and edit it before adding it to Today.*

## Install

**macOS 26 or later and Apple Silicon.**

Source version **0.2.17 (build 67)** · [Release history](docs/releases).

Download the DMG from [**Releases**](https://github.com/Alex-De-Vep/takt-planner/releases), open it, drag **Tasks** into **Applications**, then eject the disk image. Quit the app before replacing an earlier version.

**Signing:** this build uses an ad-hoc signature. It is not Developer ID signed or notarized by Apple. Gatekeeper may restrict opening a download on another Mac. You can build the app in Xcode if macOS does not allow the downloaded package to open. The project does not require disabling system security.

## Android

The Android client runs on **Android 8.0 or later**. It includes task lists, subtasks, deadline reminders, a calendar, and an AI assistant. Sign in with the same account you use for cloud sync on macOS to see your tasks. After the first sync, Android queues edits while offline and sends them when you reconnect.

- **Task editing.** Add a description when needed, edit checklist items on a separate screen, and keep the active text field visible above the keyboard. Task and checklist drafts are saved together when you confirm the task.
- **Calendar events.** Choose a calendar for a new event, add a location or description, and delete writable one-off events with confirmation. Recurring events and read-only calendars are available for viewing.
- **AI connections.** Switch between saved models and providers in Chat. ChatGPT and OpenRouter support browser sign-in. GigaChat uses its bundled official root certificate for its HTTPS endpoints.
- **Appearance.** Choose light, dark or system appearance, and English, Russian or the device language in Settings.

<p align="center">
  <img src="docs/screenshots/android-today-en.png" width="200" alt="Today task list with a deadline">
  <img src="docs/screenshots/android-task-en.png" width="200" alt="Task details with a checklist">
  <img src="docs/screenshots/android-calendar-en.png" width="200" alt="Events agenda with three sample events">
  <img src="docs/screenshots/android-assistant-en.png" width="200" alt="Built-in AI chat with a task proposal and confirmation buttons">
</p>

*Android screenshots with sample data.*

Open [the Android project](apps/android/) in Android Studio or build a debug APK by running `./gradlew :app:assembleDebug` in `apps/android/`. See the [Android guide](apps/android/README.md) for build requirements, account setup, and calendar access.

## Getting started

Open **Help → Planner Help** in the app or read the [complete guide](apps/macos/Packages/PlannerLocalization/Sources/PlannerLocalization/Resources/en.lproj/Help.md).

Press **⌘N** to create a task. Enter its title, then press **Return** to move to the description. Star it for today, add subtasks with the checklist button, or open the calendar using the rightmost toolbar button.

A new task belongs to the open folder. Today creates it in Inbox with a star; All Tasks creates it in Inbox. This Week and Month are permanent folders: date changes do not move tasks. The header counts only active search results. Moving a task preserves its contents, deadlines, notifications and calendar links.

Switching folders clears the open task and collapses completed tasks. Select a task to open it. Creating a task or following a calendar or notification link opens the requested task directly. Deleting the open task clears selection without automatically opening a neighbor.

Click the text or free space in a task row to open it. Star and completion buttons act independently. Titles, descriptions and subtasks remain editable, including in completed tasks.

Calendar access is optional. Once connected, the app uses calendars already configured in macOS. **Schedule time for task** creates an event linked to the selected task.

Configure notifications in **⌘, → Notifications**. Timed deadlines notify at their due time; date-only deadlines use the selected hour (09:00 by default). macOS permission is requested after assigning a deadline or explicitly enabling notifications. **Test notification** schedules a message in 5 seconds. macOS delivers scheduled messages even when the app is closed.

Calendar events support multiple relative or absolute alerts. Editing or removing one alert preserves the others. The system Calendar handles event notifications.

**Settings** includes **Account** for sign-in and language, **Notifications** for reminders, **Calendar** for visible calendars and the default calendar, and **Assistant** for AI options. [Settings and notification behavior](docs/settings.md#english).

| Shortcut | Action |
|---|---|
| ⌘N | New task |
| ⇧⌘N | New folder |
| ⌘Return | Toggle task completion |
| Delete | Delete the selected task when the list has focus |
| ⌘, | Settings |

## Privacy and current limitations

Tasks are available on your device. When you enable cloud sync, the app server syncs the library. The app has no ads or analytics SDKs. Calendar events live in the system event store and may sync through your configured calendar provider. See the [privacy description](docs/privacy.md).

- Cloud task sync requires an account. On-device storage is available without registration.
- Descriptions are plain text, without bold or italic formatting.
- Recurring events, recurrence exceptions and read-only calendars can be viewed but not edited.
- Deleting a task keeps its calendar events. Event scheduling and task completion are independent.
- All future deadlines are submitted. If macOS limits pending requests, the nearest deadlines and repeating reminders take priority; the queue refills when the app launches, becomes active or tasks change. macOS permission and Focus settings control banner presentation.
- This is an evolving app. Keep a system backup before relying on it for important information.

## Build

[macOS](apps/macos/README.md) · [Android](apps/android/README.md) · [Windows (planned)](apps/windows/README.md)

Requires macOS 26+, Xcode 26 with Swift 6.2 support, Command Line Tools and Python 3 for helper scripts. The localization package is included. The build uses pinned MLX Swift packages.

Open `apps/macos/Planner.xcodeproj`, select **Planner → My Mac**, and run with **⌘R**.

Compile the app and test sources without running tests:

```sh
xcodebuild -project apps/macos/Planner.xcodeproj -scheme Planner \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath apps/macos/.build/DerivedData build-for-testing
```

Build a release DMG for Apple Silicon:

```sh
xcodebuild -resolvePackageDependencies -project apps/macos/Planner.xcodeproj -scheme Planner \
  -clonedSourcePackagesDirPath apps/macos/.build/SourcePackages
python3 apps/macos/scripts/build_release.py
```

Artifacts are written to `dist/`. [Development guide](docs/development.md) · [Release guide](docs/releasing.md).

## Contributing

Bug reports and suggestions are welcome in [**Issues**](https://github.com/Alex-De-Vep/takt-planner/issues). Please read [CONTRIBUTING.md](CONTRIBUTING.md). Do not attach personal task libraries, calendar information, tokens or signing keys.

Compiling tests does not mean they have passed. Check the release notes for the validation performed.

## License

Licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attribution.

Created by [Alex-De-Vep](https://github.com/Alex-De-Vep).
