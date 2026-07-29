# Правила изменения проекта

Перед изменением поведения прочитайте `ARCHITECTURE.md`.

## Приоритет

1. Не допустить crash, потери конфигурации, залипания ввода/PTT и ошибочного
   действия в ChatGPT.
2. Сохранять очевидные владельцы состояния и проверяемые контракты.
3. Минимизировать число мест, которые нужно менять для одной функции.

## Обязательные правила

- `AppModel` остаётся `@MainActor` фасадом; IOHID/POSIX/JSON детали выносите
  в существующие специализированные компоненты.
- Не добавляйте raw bridge action string. Используйте `BridgeAppAction` и
  синхронно обновляйте общий action manifest и contract tests.
- Специальное поведение Codex action задавайте metadata в
  `CodexActionCatalog`, без `if id == ...` в модели или UI.
- Постоянную конфигурацию публикуйте только после успешного atomic save.
  Momentary profile сохранять запрещено.
- Не добавляйте `@unchecked Sendable` без явного lock/queue owner и теста
  конкурентного доступа.
- Не ослабляйте build/version gates, preload allowlist, permissions или
  owner-marker проверки ради прохождения теста.
- Не изменяйте и не переподписывайте `/Applications/ChatGPT.app`.

## Проверка

- Для локальной итерации запускайте релевантные XCTest и Node regressions.
- Перед завершением запускайте `deep-test.sh --full --hardware-inventory`.
- Без отдельного разрешения не запускайте приложение, HID-only режим,
  hardware checklist или opt-in live ChatGPT E2E и не перезапускайте ChatGPT.
- Физический HID/LED/live результат не называйте проверенным по итогам
  автоматического runner.
