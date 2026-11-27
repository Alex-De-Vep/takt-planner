# Конфиденциальность / Privacy

Обновлено: 21 ноября 2026 года. Применяется к приложению Takt в этом репозитории.

## Что хранится на устройстве

Названия задач и папок, описания, подзадачи, сроки, отметки выполнения и связи с событиями сохраняются в локальной библиотеке SwiftData внутри sandbox-контейнера приложения. Заметки и их вложения сохраняются рядом с библиотекой. Совместимый сервер получает заметки при синхронизации облачной библиотеки. Язык, размеры панелей и выбор календарей сохраняются локально в настройках.

Режим «Только на устройстве» доступен без аккаунта. В облачном режиме сервер приложения получает адрес электронной почты и данные синхронизируемой библиотеки. Обмен идёт по HTTPS, токены входа хранятся в Связке ключей macOS. В приложении нет рекламы и аналитических SDK.

## ИИ-помощник

При отправке сообщения Takt передаёт его и выбранный контекст подключённому ИИ-провайдеру. История разговоров хранится на Mac. Токены входа и ключи провайдеров хранятся в Связке ключей macOS. При подтверждении расшифровки приложение отправляет аудио провайдеру выбранной модели. Если в меню контекста включено «Использовать заметку», заголовок и текст открытой заметки отправляются выбранному провайдеру вместе с сообщением.

## Доступ к календарю

Доступ запрашивается после действия «Подключить календарь». Он нужен для просмотра событий и создания или редактирования событий по вашему действию. Отказ не мешает работе с задачами.

События сохраняются через EventKit в системном календаре. Если выбранный календарь связан с iCloud, Google, Exchange или другим провайдером, синхронизация выполняется системой и соответствующим сервисом по его условиям. Нельзя считать такие события исключительно локальными данными.

Приложение хранит локальные идентификаторы связанных событий и последние известные название и дату, чтобы показывать связь с задачей.

## Уведомления

С разрешения пользователя приложение передаёт macOS название задачи, её локальный идентификатор и срок, чтобы система доставила локальное уведомление. Эти данные не отправляются разработчику. Показ текста на заблокированном экране определяется настройками уведомлений macOS. Время и включение ежедневного напоминания хранятся в локальных настройках. Разрешение можно изменить в **Системные настройки → Уведомления → Takt**.

## Удаление и разрешения

Задачи и события можно удалить через интерфейс. Удаление задачи удаляет её локальные связи и подзадачи, но сохраняет события календаря. Удаление события не удаляет задачу.

Отозвать доступ можно в настройках macOS: **Конфиденциальность и безопасность → Календари**. Отзыв доступа не удаляет ранее созданные события. Локальная библиотека сохраняется между перезапусками; удаление самого `.app` не следует считать гарантированным удалением данных. Резервные копии системы могут содержать прежние данные.

## Обращения к разработчику

Когда вы отправляете обращение через **Настройки → Поддержка → Написать нам** на Android, сервер передаёт в ящик поддержки тему, описание, указанный вами адрес для ответа, версию и сборку Takt, версию ОС и время устройства с часовым поясом. По умолчанию форма подставляет почту аккаунта. Сервер присваивает код обращения и фиксирует время приёма. Данные из библиотеки и история чата автоматически не прикладываются.

Проект поддерживает [Alex-De-Vep](https://github.com/Alex-De-Vep). Сообщения в публичных [Issues](https://github.com/Alex-De-Vep/takt-planner/issues) видны другим пользователям. Не публикуйте там содержимое своей библиотеки или личных событий. Использование сайта GitHub регулируется его собственной политикой конфиденциальности.

## English

Takt stores task content, folders, subtasks, deadlines and event links in a local SwiftData library inside its app sandbox. Notes and their attachments are stored with the library. A compatible server receives notes when the cloud library syncs. Preferences are stored locally. On-device mode requires no account. In cloud mode, the app server receives your email address and the library data you sync. The app connects over HTTPS and keeps sign-in tokens in the macOS Keychain. There are no ads or analytics SDKs.

When you send a message, Takt sends it and the selected context to the connected AI provider. Chat history is stored on your Mac. Sign-in tokens and provider API keys are stored in the macOS Keychain. When you confirm transcription, the app sends the audio to the provider of your selected transcription model. When Use note is enabled in the context menu, the app sends the open note’s title and text to the selected provider with your message.

Calendar access is requested only after you choose to connect calendars. EventKit reads and writes the system calendar. Events may sync via iCloud or another calendar provider configured in macOS; that provider's privacy terms apply. Declining calendar access does not prevent task management.

With notification permission, Takt passes the task title, local ID and deadline to macOS for local notification delivery. No notification content is sent to the developer. Lock-screen previews follow macOS notification settings. Reminder preferences stay local. Change permission in System Settings → Notifications → Takt.

Deleting a task removes its local subtasks and links but keeps calendar events. Deleting an event keeps the task. Revoke access in macOS Privacy & Security → Calendars. Revoking permission does not delete existing events. Removing the app bundle alone does not guarantee deletion of the local library; system backups may retain earlier data.

Public GitHub issues are visible to others. Do not include personal tasks or events in reports. The maintainer is [Alex-De-Vep](https://github.com/Alex-De-Vep).

When you submit a request via **Settings → Support → Contact us** on Android, the server sends your subject, description, selected reply email, Takt version and build, OS version, and device time with offset to the support inbox. The form pre-fills your account email. The server assigns a request code and records when it received the request. Library data and chat history are not attached automatically.
