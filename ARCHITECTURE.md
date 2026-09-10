# Архитектура Nostromo Codex

## Цели

Приоритет решений: стабильность → поддерживаемость → низкая стоимость
дальнейшего вайбкодинга. Приложение остаётся локальной single-user утилитой;
лишние слои и распределённое UI-состояние не добавляются без измеримой пользы.

## Поток данных

```text
Razer Nostromo
  → NostromoHIDManager (собственная serial queue)
  → AppModel (@MainActor, единый UI-фасад)
  → Project2077Engine / typed BridgeAppAction
  → UnixSocketBridge (protocol v2)
  → chatgpt-preload.cjs
  → проверенные API установленного ChatGPT
```

Обратный поток передаёт host reports, capabilities, runtime state и task
slots через `BridgeWireCodec` в `AppModel`, после чего обновляются UI и
подсветка.

## Владельцы состояния

- `NostromoInstanceLock` получает process lease до создания `AppModel`.
  Второй экземпляр приложения не открывает HID и не читает recovery marker.
  Lock снимается ядром при завершении процесса, файл не удаляется.
- `AppModel` координирует UI и сервисы на MainActor. Он не должен содержать
  POSIX, IOHID или JSON-framing детали.
- `ProfileRuntimeState` владеет persistent profile ID и transient
  momentary-стеком. Momentary‑выбор виден в UI, но не сохраняется.
- Постоянная конфигурация изменяется candidate-first: сначала валидация и
  atomic save, затем публикация и побочные эффекты.
- `NostromoHIDManager` владеет HID manager/device state только на своей
  serial queue. Callback-и передают immutable события.
- `NostromoKeyboardSuppressor` владеет per-service `UserKeyMapping` и
  recovery marker. Marker всей партии атомарно сохраняется до первой записи;
  применение, rollback и восстановление считаются успешными только после
  read-back. `AppModel` вызывает suppressor только с MainActor.
  Каждое перечисление HID-сервисов открывает новую simple-client сессию,
  которая живёт до следующей транзакции. Старые registry ID не переживают
  переподключение внутри кэша доступа к свойствам.
- `UnixSocketBridge` владеет descriptor lifecycle и backpressure. Он
  одноразовый: после terminal stop повторный start является no-op.
- `BridgeRuntimeDirectory` создаёт per-process scope `0700`, marker/socket
  `0600` и стабильный per-user discovery scope `0700`. После `listen` он
  атомарно публикует session descriptor `0600`, а при остановке удаляет его
  только если descriptor всё ещё принадлежит этому процессу.
- `BridgeWireCodec` является чистой границей protocol v2 и не владеет I/O.
- preload dependency-free, compatibility-gated, проверяет owner/permissions
  discovery descriptor и автоматически переподключает существующий
  виртуальный HID с ограниченным exponential backoff. Он никогда не изменяет
  `ChatGPT.app`.
- `CodexCompatibilityManifest` читает общий с preload manifest и находит
  единственный сервис Micro по контракту в ASAR. Имя bundle chunk не является
  контрактом. Кандидат сборки остаётся непроверенным до opt-in live-теста.
- `CodexFallbackController` выполняет только пять базовых menu actions через
  Accessibility после активации конкретного приложения. Он не посылает
  глобальные клавиши, не использует приватные API и не повторяет действия
  с неизвестным результатом после разрыва моста.
- `AppModel` наблюдает за identity установленного bundle; при замене сбрасывает
  capabilities и активный ввод. Полный режим требует handshake с той же
  версией/build и подтверждёнными runtime API; authentication сокета
  сам по себе готовности не означает.

## Контракты, которые меняются вместе

При добавлении bridge action необходимо обновить:

1. `BridgeAppAction` и его typed payload;
2. `APP_ACTIONS` / `APP_ACTION_CONTRACT` в preload;
3. `Tests/Fixtures/bridge-actions.json`;
4. Swift и Node contract tests.

При добавлении пользовательского Codex action вся семантика задаётся в
`CodexActionCatalog`: execution, availability source и consequential flag.
`AppModel` и UI не должны сравнивать специальные command ID строками.

Формат `profiles.json` имеет version 1. Новые additive‑поля должны получать
безопасный default при decode; неизвестная версия и нарушенные structural
invariants отклоняются.

## Критические инварианты

- Input Test и HID-only не dispatch-ят bindings.
- Назначения исполняются только после подтверждённого exclusive HID capture
  либо подтверждённого read-back `UserKeyMapping`; shared capture без
  защиты работает fail-closed.
- При exclusive capture `UserKeyMapping` не применяется. При shared capture
  сбой одного HID-сервиса откатывает всю партию, а незавершённый rollback
  остаётся в атомарном recovery marker для следующего процесса.
- Plugin prompt только подготавливает composer и не отправляет сообщение.
- Disconnect/shutdown всегда останавливают PTT и отпускают активные actions.
- Momentary profile никогда не заменяет persistent active profile на диске.
- Неизвестная ChatGPT build блокируется; expert override не обходит
  отсутствие обязательных private modules.
- Перезапуск ChatGPT проверяет совместимость, мост и preload до закрытия
  приложения. При ошибке повторного запуска открывает обычный ChatGPT,
  сохраняя диагностику ошибки моста. Shutdown отменяет повторный запуск.
- При недоступности приватного моста доступны только явно перечисленные в
  metadata каталога базовые команды. Удержанные при смене соединения кнопки
  требуют отпускания; старые события и результаты не повторяются через резерв.
- Старые runtime directories удаляются только для доказанно мёртвого PID и
  после повторной проверки owner marker/inode.
- Discovery descriptor принимается только вместе с совпадающим owner marker,
  приватными `0700`/`0600`, ожидаемым socket path и повторной token-
  аутентификацией; устаревший процесс не удаляет descriptor нового сеанса.
- После terminal bridge stop не публикуются `.listening`, `.connected` или
  `.failed`.

## Безопасная проверка

Быстрый цикл:

```sh
swift test
node Tests/preload-unit.cjs
node Tests/preload-smoke.cjs
```

Перед передачей результата:

```sh
./scripts/deep-test.sh --full --hardware-inventory
```

Runner не открывает приложение, не захватывает HID, не пишет в LEDs и не
перезапускает ChatGPT. Live ChatGPT E2E, HID-only launch и физическая матрица
выполняются только по отдельному явному запросу.
