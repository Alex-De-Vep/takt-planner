# Иконка Takt для macOS

В [`TasksIcon.icon`](../../apps/macos/Planner/TasksIcon.icon) хранится нативная композиция Icon Composer. Для стандартного оформления используется кремовая подложка с фиолетовой галочкой, мятной строкой, синим кольцом и градиентом ИИ-чата. Знак хранится отдельным прозрачным слоем, а форму подложке задаёт macOS.

После изменения композиции запустите `python3 apps/macos/scripts/prepare_app_icon.py`. Скрипт экспортирует `tasks-icon.png`, уменьшенную версию `tasks-icon-preview.png` для README и стандартные размеры в `AppIcon.appiconset`. Для экспорта используется Icon Composer из выбранного Xcode.

Предыдущие исходники находятся в `archive/0.1.30` и `archive/0.1.31`.
