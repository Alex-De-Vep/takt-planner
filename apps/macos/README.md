# Takt для macOS

Нужны Mac с Apple Silicon, macOS 26+, Xcode 26 с поддержкой Swift 6.2 и Python 3. Для сборки с MLX установите Metal Toolchain через `xcodebuild -downloadComponent MetalToolchain`.

## Запуск

Откройте `Planner.xcodeproj` в этой папке, выберите **Planner → My Mac** и нажмите **⌘R**.

## Сборка и проверка

Выполняйте команды из корня репозитория. В чистой копии загрузите закреплённые Swift-зависимости в каталог, который использует сборка DMG:

```sh
xcodebuild -resolvePackageDependencies -project apps/macos/Planner.xcodeproj -scheme Planner \
  -clonedSourcePackagesDirPath apps/macos/.build/SourcePackages
```

Скомпилируйте приложение и тестовые исходники без запуска тестов:

```sh
xcodebuild -project apps/macos/Planner.xcodeproj -scheme Planner \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath apps/macos/.build/DerivedData \
  -clonedSourcePackagesDirPath apps/macos/.build/SourcePackages build-for-testing
```

Соберите демонстрационные приложения с вымышленными данными и установочный DMG:

```sh
python3 apps/macos/scripts/prepare_showcase.py
python3 apps/macos/scripts/build_release.py
```

Демонстрационные приложения появятся в `apps/macos/.build/showcase/`, а DMG для Apple Silicon и его SHA-256 — в корневом `dist/`. Эксперименты и тесты с реальной моделью используют тестовые веса в `apps/macos/.build/`.

[Устройство клиента](../../docs/development.md) · [Подготовка релиза](../../docs/releasing.md)
