# Nostromo Codex — релизная приёмка 2026-07-26

## Итог

Статус публичного релиза: **NO-GO до ручной физической матрицы**.

Автоматическая матрица, живая GUI-приёмка, реальный bridge с ChatGPT,
перезапуски и stability soak прошли без ошибок. Исправления D1–D7 и
NC-UI-001/003/004 подтверждены тестами и доступными live-сценариями.

Единственный блокирующий остаток нельзя выполнить программно: оператор должен
физически нажать все controls подключённого Nostromo на финальном бинарнике.
Финальный повтор AX-проверки новых accessibility metadata также требует
разблокированного экрана.

Версия бандла оставлена `0.1.0 (1)`: решения о bump в задаче не было.
Git metadata в рабочем каталоге отсутствует; commit не создавался.

## Среда и артефакты

- macOS 26.5.2 (25F84), Apple Silicon, arm64.
- Xcode 26.6, Swift 6.3.3, Node.js 26.0.0.
- ChatGPT `26.721.41059 (5848)`.
- Razer Nostromo `1532:0111`, keyboard + mouse HID interfaces.
- Финальный bundle: `dist/Nostromo Codex.app`.
- Этот же бинарник и preload установлены в `/Applications/Nostromo Codex.app`.
- Полные логи: `/tmp/nostromo-release-qa-20260726T082827Z/`.
- Финальный runner:
  `/tmp/nostromo-release-qa-20260726T082827Z/final-deep-test/20260726T093952Z/`.

## Исправления

- D1: оригинальный `UserKeyMapping` сохраняется до подавления, переживает
  SIGKILL и восстанавливается при следующем запуске.
- D2/D3/D7: dashboard-open запросы централизованы и не теряются до готовности
  status controller; reopen не создаёт дубликаты окон.
- D4: bridge использует приватный owner marker, удаляет подтверждённо
  осиротевшие runtime directories и чистит собственный runtime на stop/failure.
- D5 / NC-UI-003: keycaps используют короткие уникальные labels; минимальный
  layout 1100×700 покрывает все binding kinds.
- D6 / NC-UI-004: длинные имена профилей имеют полный tooltip.
- Дополнительно: sidebar, Connection/Lighting toggles, action library,
  profile actions, setup cards, Diagnostics, menu popover и plugin editor
  получили явные accessibility labels/values/hints. Error banner сохраняет
  отдельную доступную кнопку закрытия.
- Live E2E расширен реальными безопасными действиями и точной проверкой
  capability manifest.

## Финальная автоматическая матрица

Команда:

```sh
./scripts/deep-test.sh --full --hardware-inventory
```

Результат: 14/14 шагов `PASS`, 0 failures.

- Debug: 186 tests, 1 opt-in live test skipped, 0 failures.
- Release: 186 tests, 1 opt-in live test skipped, 0 failures.
- AddressSanitizer: 0 failures.
- ThreadSanitizer: 0 failures.
- Warnings as errors: `PASS`.
- `UnixSocketBridgeTests`: 18/18.
- Preload syntax/unit: `PASS`.
- Preload smoke: 50 × 9 = 450/450.
- Packaging, bundle contents, strict codesign: `PASS`.
- Architecture: arm64; minimum macOS: 26.0.
- Hardware inventory: два ожидаемых интерфейса и feature report size 90.

## Живая GUI-приёмка

Пройдено:

- NC-UI-001: close → running process → повторный launch и `Cmd+,` возвращают
  ровно одно окно.
- Onboarding: welcome, connection, keymap, safe input-test, completion.
- Профили: create, длинное Cyrillic/emoji имя, tooltip, duplicate, destructive
  confirmation, delete и Undo.
- Import/export: cancel, JSON filter, preview, preview cancel, auto-backup,
  valid import и malformed JSON error.
- Connection: физический Nostromo определяется как два интерфейса; build 5848
  распознаётся как проверенный.
- Diagnostics: HID, suppression, bridge, capability source, три недоступные
  функции и task-lighting summary отображаются корректно.
- Lighting: controls и accessibility metadata присутствуют; test flash
  отправлен подключённому устройству без ошибки.
- Action library: доступное действие фильтруется как enabled; `Разрешения`
  возвращается единственной disabled строкой.
- Restart protection: перед закрытием ChatGPT показано предупреждение о
  незавершённом composer; подтверждённый restart вернул состояние `Готово`.

Во время финального accessibility recheck экран автоматически заблокировался.
Правки компилируются и проходят всю матрицу, но их итоговые AX attributes
нужно один раз прочитать Accessibility Inspector после разблокировки.

## Реальный ChatGPT E2E

Opt-in тест использует `FakeHID`, настоящий `UnixSocketBridge`, настоящий
`ChatGPTLauncher`, production preload и установленный ChatGPT.

Подтверждено:

- версия/build и обязательные private modules;
- token-authenticated handshake и `hello-ack`;
- неверный token отклоняется, bridge принимает следующий корректный client;
- `commandRegistrySource == runtime-app-asar`;
- все required Electron APIs равны `true`;
- unavailable features точно соответствуют README: permissions picker,
  `compact`, `status`;
- skills загружены официальным Codex app-server `skills/list`, уникальны и
  совпадают с каталогом AppModel;
- полный путь FakeHID → AppModel → real bridge → real preload выполнен для
  task slot reports, sidebar, next/previous, Plan/Fast, skill mention,
  plugin prompt без submit, PTT start/stop, stop-active и scroll;
- неизвестный command ID отклоняется;
- expert override пропускает только unknown build с полным API shape и не
  обходит отсутствие обязательных модулей;
- расширенный live E2E прошёл повторно 3/3 с реальным завершением и запуском
  ChatGPT.

## Стабильность и crash recovery

- Пятиминутный app soak: 60/60 samples.
- CPU: 0.0–0.0%.
- RSS: 118288 → 90400 KiB; монотонного роста нет.
- File descriptors: 60 → 60.
- Launch/quit: 10/10.
- В каждом цикле runtime directory существовал только во время процесса и
  отсутствовал после quit.
- Recovery marker отсутствовал после каждого штатного quit.
- Authenticated bridge reconnect: 10/10 на одном сервере.
- Реальный ChatGPT restart: 3/3.
- SIGKILL при активном HID/bridge:
  - persisted mapping marker остался;
  - orphan runtime остался ожидаемо;
  - следующий запуск удалил старый runtime;
  - следующий штатный quit удалил новый runtime и recovery marker;
  - `UserKeyMapping` после восстановления побайтно совпал с исходным.

## Целостность и восстановление

- `ChatGPT.app/Contents/Resources/app.asar`:
  `da39a51b06fb4c728d418b8f0f05fc8fd8c6b1f74c4fb4d47c20c7914a798f45`
  до и после.
- `ChatGPT.app/Contents/MacOS/ChatGPT`:
  `d7bd5eacb7f59c42240e6c5dc62eebdeca9d09a0b59ed4c3ac3e2b55ef8d9336`
  до и после.
- ChatGPT проходит `codesign --verify --deep --strict`.
- Финальный Nostromo bundle проходит strict codesign, содержит только arm64,
  minos 26.0 и preload, идентичный source.
- Installed executable SHA-256 совпадает с `dist`:
  `1fba843b42801c5c7fd438acbb8c8ce604af26d81e71633b735bf5b4cb24dac7`.
- Installed preload SHA-256 совпадает с `dist`:
  `69f91dee6e51fc377de686abf286b3069299626d6f04485a15a84681a9988a3f`.
- `profiles.json` восстановлен побайтно:
  `b0aaadf1db78ffacf08be699082e31508bd3fb0b43ccd4f75d49ba7b9a8fd6f5`.
- Preferences восстановлены побайтно:
  `168c608f558fc1e603025ced25c4d878c7219ccc148935433d0474302629e579`.
- Финальное состояние: Nostromo и ChatGPT остановлены, runtime UUID
  directories отсутствуют, keyboard recovery marker отсутствует.
- Устаревший pre-fix bundle и `.DS_Store` удалены из `dist/`.

## Обязательный ручной gate перед публичным релизом

На установленном финальном bundle:

1. Нажать 16 клавиш по 10 раз и проверить 320 edges без потерь/дублей.
2. Проверить 8 направлений D-pad и переходы cardinal ↔ diagonal.
3. Проверить колесо в обе стороны, короткое/длинное нажатие и hold+rotate.
4. Проверить PTT hold, double-press latch и отпускание.
5. Подтвердить отсутствие печатных дублей в стороннем приложении.
6. Выполнить 3 unplug/replug цикла без перезапуска приложения.
7. Зафиксировать HID callback latency p95 ≤ 30 ms.
8. Визуально подтвердить idle/completed/running/action LED states.
9. После разблокировки проверить AX names/values для sidebar, Connection
   toggles, action rows, profile menu и error-banner dismiss.

До выполнения этих пунктов финальный бинарник является технически зелёным
release candidate, но не доказанным публичным релизом для физического устройства.
