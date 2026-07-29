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
- `UnixSocketBridge` владеет descriptor lifecycle и backpressure. Он
  одноразовый: после terminal stop повторный start является no-op.
- `BridgeRuntimeDirectory` создаёт scope `0700`, marker/socket `0600` и
  удаляет только каталог с повторно подтверждённой identity.
- `BridgeWireCodec` является чистой границей protocol v2 и не владеет I/O.
- preload dependency-free, compatibility-gated и никогда не изменяет
  `ChatGPT.app`.

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
- Старые runtime directories удаляются только для доказанно мёртвого PID и
  после повторной проверки owner marker/inode.
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
