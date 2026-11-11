# Working on Takt

Use English commit messages. Keep each platform's source, tests, resources, and build tooling together.

- **macOS** — Open `apps/macos/Planner.xcodeproj` and select **Planner → My Mac**. Follow the [macOS build guide](apps/macos/README.md) for `build-for-testing`, the showcase build, and the DMG. Update `apps/macos/scripts/generate_project.py` along with Xcode build settings. Preserve the app identifier and existing SwiftData migrations when changing build paths. Use an isolated library and a fake calendar for tests that launch the app.
- **Android** — Open `apps/android/` in Android Studio. From that directory run `./gradlew :app:assembleDebug :app:testDebugUnitTest :app:lintDebug` (use `.\gradlew.bat` in PowerShell). See the [Android guide](apps/android/README.md) for SDK requirements and installation.
- **Windows** — See the [Windows project status](apps/windows/README.md).
- **Server** — Work from `server/` and follow the [server guide](server/README.md). The [OpenAPI contract](server/docs/openapi.json) is the source of truth for client sync. Preserve compatibility with released clients when changing the contract.

Report which checks actually ran. Compiling the macOS test sources with `build-for-testing` does not execute them.
