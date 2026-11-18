# Подготовка релиза

## Перед сборкой

1. Зафиксируйте изменения и проверьте состав коммита: без личных данных, ключей, логов и каталогов сборки.
2. Проверьте версию и номер сборки в Xcode-проекте и `apps/macos/scripts/generate_project.py`.
3. Обновите описание выпуска в `docs/releases/`, требования и ограничения в README.
4. Соберите приложение и тестовые исходники. Отдельно укажите, какие проверки действительно запускались.

## Сборка пакета

Из корня репозитория:

```sh
xcodebuild -resolvePackageDependencies -project apps/macos/Planner.xcodeproj -scheme Planner \
  -clonedSourcePackagesDirPath apps/macos/.build/SourcePackages
PLANNER_RELEASE_SIGNING_IDENTITY='<certificate fingerprint>' python3 apps/macos/scripts/build_release.py
```

Скрипт собирает Release для Apple Silicon (`arm64`), проверяет локализованные имена, ресурсы ИИ-помощника, сертификат GigaChat, подпись и разрешения. Затем он упаковывает DMG и проверяет его содержимое после монтирования только для чтения. Тесты и приложение не запускаются.

В образ и в ресурсы приложения включаются `LICENSE` и `NOTICE`. Демонстрационные данные не входят в Release. Результаты находятся в `dist/`.

Сборка с виджетом «Сегодня» требует сертификат Apple. Для тестового обновления на Mac задайте `PLANNER_RELEASE_SIGNING_IDENTITY` с отпечатком сертификата Apple Development из `security find-identity -v -p codesigning`. Используйте ту же команду разработчика и идентификатор приложения, чтобы macOS узнавала приложение при обращении к Связке ключей. Для локальной подписи ad-hoc соберите приложение с `--without-widget`. Для публичного распространения применяйте Developer ID и нотариализацию.

## GitHub Release

В [Releases](https://github.com/Alex-De-Vep/takt-planner/releases) создайте черновик с тегом версии на проверенном коммите. Для подготовленного выпуска используйте `v0.3.27`, отметку **pre-release** и заголовок «Takt 0.3.27». Проверьте список файлов перед публикацией.

Вложите только:

- `Takt-0.3.27-macOS-arm64.dmg`
- `Takt-0.3.27-macOS-arm64.dmg.sha256`
- `Takt-0.1.2-Android-debug.apk`
- `Takt-0.1.2-Android-debug.apk.sha256`
- `TaktServer-0.1.6-source.tar.gz`
- `TaktServer-0.1.6-source.tar.gz.sha256`

Android APK — тестовая сборка с debug-подписью для установки из файла. Для Google Play или другого магазина подготовьте release-сборку с постоянным ключом владельца. Существующий тестовый APK обновляется только APK с той же подписью.

Android собирается из папки `apps/android/` командой `./gradlew :app:assembleDebug :app:testDebugUnitTest :app:lintDebug`. Результат находится в `app/build/outputs/apk/debug/app-debug.apk`. Проверьте подпись через `apksigner verify --verbose --print-certs` и сохраните SHA-256 рядом с установщиком.

Текст этого выпуска находится в [docs/releases/v0.3.27.md](releases/v0.3.27.md). Исходные архивы GitHub создаст из тега. Бинарные сборки хранятся во вложениях релиза. Для исправлений опубликованного выпуска используйте новую версию и новый тег.

## Проверка загрузки

После скачивания DMG и файла контрольной суммы в одну папку:

```sh
shasum -a 256 -c Takt-0.3.27-macOS-arm64.dmg.sha256
shasum -a 256 -c Takt-0.1.2-Android-debug.apk.sha256
shasum -a 256 -c TaktServer-0.1.6-source.tar.gz.sha256
```

Контрольная сумма проверяет целостность файла, но не заменяет подпись Developer ID или нотариализацию.

Архив сервера содержит исходники и миграции версии 0.1.6. Он предназначен для администратора сервера. Это отдельная поставка от будущего Windows-клиента.
