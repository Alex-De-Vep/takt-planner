# Участие в разработке / Contributing

Спасибо за интерес к «Задачам». Небольшие, сфокусированные изменения проще проверить и включить в релиз.

## Ошибки и предложения

Создайте Issue с версией приложения, платформой и версией ОС, шагами воспроизведения, ожидаемым и фактическим результатом. Для визуальных ошибок полезен снимок окна; используйте вымышленные данные. Не прикладывайте реальную библиотеку задач, календарные события, токены или ключи подписи.

Крупную функцию лучше сначала обсудить в Issue, чтобы согласовать поведение и объём работы.

## Изменения кода

Клиенты находятся в `apps/`, сервер и контракт API — в `server/`. Сообщения коммитов пишите на английском.

### macOS

- Используйте существующие SwiftUI/AppKit-компоненты и системные API.
- Новые пользовательские строки добавляйте на русском и английском в `apps/macos/Packages/PlannerLocalization`.
- Комментарии пишите по-русски. Имена Swift-типов и методов сохраняйте в стиле проекта.
- Схемы SwiftData V1–V5 не изменяйте задним числом: изменения хранения требуют следующей версии и миграции.
- Не включайте личные данные, результаты сборки и настройки Xcode в pull request.
- При изменении настроек Xcode обновляйте также `apps/macos/scripts/generate_project.py`.

### Android

Откройте `apps/android/` в Android Studio. Сборка и проверки описаны в [руководстве Android](apps/android/README.md#сборка).

## Проверка macOS

По принятому процессу базовая проверка — `build-for-testing` без запуска приложения и тестов. Команда приведена в [руководстве разработчика](docs/development.md).

Для PR укажите, что действительно проверено: сборка, ручные сценарии, выполненные тесты. Не называйте скомпилированные тесты пройденными. UI-тесты отключены в общей схеме; их запуск требует отдельной подготовки. Календарные проверки должны использовать подменяемое хранилище, а не личные календари.

## English

Please open an issue with the app version, platform and OS version, reproduction steps and expected behavior. Use fictional data in screenshots. Keep pull requests focused, update both translations and document exactly what you verified. Source comments are in Russian. Use English commit messages. The default macOS verification step compiles the app and test sources without executing tests. Never use personal calendars for automated checks.
