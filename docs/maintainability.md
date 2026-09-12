# Поддерживаемость и автоматические проверки

Срез переработки от 12 сентября 2026 года. Исходная ревизия — `06be6b3`,
включая четыре ранее неопубликованных коммита поверх `origin/main`.
На момент начала других локальных или удалённых веток с уникальными
изменениями не было. Вложенная копия репозитория не включена в изменения.

## Изменения и границы

`AppModel` сокращён с 2231 до 1874 строк. Жесты, заменяемые таймеры,
черновик калибровки, задача запуска ChatGPT и диагностика получили отдельных
владельцев. UI остаётся подписанным на один MainActor-фасад. IOHID, POSIX,
atomic persistence и состояние momentary-профилей остаются в существующих
специализированных компонентах. Публичные API Core, protocol v2, action
manifest и формат profiles v1 не менялись.

Исправлены воспроизведённые дефекты:

- промежуточные ошибки plist, ресурсов, подписи и записи лога могли
  приводить к ложному PASS автоматического runner;
- callback-и, ожидающие MainActor, могли выполнять действия и возвращать
  защиту ввода после shutdown;
- JSON `null` приводил к необработанному исключению preload в socket callback;
- версия протокола и ID слота могли приниматься после усечения дроби или
  приведения boolean к числу.

Для таймеров добавлена защита от устаревшего завершения после замены.
Задача запуска теперь отменяется при shutdown и не публикует поздний
результат. Framing preload отделён от authentication и обработки сообщений.
Владельцы locks сохранены, ручные пары lock/unlock заменены на `withLock`
для хранения callback-ов bridge.

Новые возможности продукта, переработка визуального дизайна и обходы
проверок совместимости не входили в изменения. Низкое аппаратное покрытие
не компенсировалось тестами, проверяющими только текст реализации.

## Матрица критических контрактов

| Контракт | Основная автоматическая защита |
|---|---|
| Candidate-first save, повреждённая конфигурация, backup | `ConfigurationRobustnessTests`, `AppModelProfilesTests` |
| Momentary profile не сохраняется и корректно отпускается | `ProfileRuntimeStateTests`, `AppModelProfilesTests`, `AppModelInputTests` |
| Отмена и замена таймеров, непрерывный D-pad, long press | `RuntimeSchedulerTests`, `InputGestureCoordinatorTests`, `AppModelInputTests` |
| Калибровка не выполняет bindings и поглощает последнее отпускание | `CalibrationSessionTests`, `AppModelInputTests` |
| Shutdown, запрет новых запусков, отмена восстановления | `AppModelLifecycleTests`, `ChatGPTLaunchCoordinatorTests` |
| PTT release, fallback, свежий ввод после reconnect | `AppModelInputTests`, `AppModelActionsTests`, preload `ptt-failsafe`, `close-queue-guard`, `automatic-reconnect` |
| Read-back/rollback UserKeyMapping и fail-closed dispatch | `NostromoKeyboardSuppressorTests`, `AppModelInputTests`, `HIDManagerOpenPolicyTests` |
| Socket lifecycle, permissions, owner markers, backpressure | `UnixSocketBridgeTests`, `NostromoInstanceLockTests` |
| Неверные protocol envelopes, IDs и payloads | `BridgeWireCodecTests`, `BridgeProtocolContractTests`, preload `virtual-hid-actions`, `authentication-failure` |
| Build gates, scoped hooks и allowlist | `CodexCompatibilityTests`, `CodexActionCatalogTests`, preload smoke scenarios |
| Нельзя скрыть сбой проверяющего инструмента | `Tests/deep-test-runner.cjs` с искусственными отказами |

## Изменения тестового набора

Было 233 XCTest, стало 245. Отдельный Swift Testing rendering-тест сохранён.
`AppModelTests` разделён на шесть наборов с общими fixtures. Четыре
интеграционных теста D-pad переведены на управляемое время. Fixtures
завершают модель и удаляют временную конфигурацию после каждого теста.

Удалены три проверки с сохранением защиты:

| Удалённая проверка | Где проверяется контракт |
|---|---|
| `testGoldenRedLEDReport` | `testGoldenLEDReportsForEveryLEDAndState`, включая фиксированные аппаратные ID и независимую checksum |
| `testGoldenBacklightBrightnessReport` | `testGoldenBrightnessReportsAtBoundaries`, включая значение `0x80` |
| `testHighRateDPadStreamResolvesBeforeStreamStops` | `testRepeatedReportsResolveDuringStreamAndExtendReleaseDeadline` с управляемым временем, интеграция momentary остаётся в `AppModelInputTests` |

## Покрытие

Замеры выполнены одним Xcode 26.6 без live E2E. Данные Swift взяты из
LLVM coverage export, preload — из `NODE_V8_COVERAGE` для unit и smoke.
Воспроизводимая команда приведена в [testing.md](testing.md).

| Область | До | После |
|---|---:|---:|
| Core, line coverage | 1403/1482 · 94,67% | 1403/1482 · 94,67% |
| Приложение без UI, line coverage | 4172/6207 · 67,21% | 4206/6239 · 67,41% |
| SwiftUI, line coverage | 2205/10216 · 21,58% | 2205/10216 · 21,58% |
| Preload, вызванные функции V8 | 87/96 · 90,63% | 92/101 · 91,09% |

Покрытие строк почти не изменилось. Существенное дополнение — проверки
ошибочных входных данных, отмены и завершения, которых раньше не было.
Удаление дублирующих LED-тестов не уменьшило покрытие Core.
LLVM учитывает сгенерированные SwiftUI/closure regions, поэтому знаменатель
не равен числу физических строк файлов. Долю функций V8 нельзя сравнивать
с долей строк Swift или трактовать как branch coverage.

Физические HID/LED, диалоги разрешений macOS и live-поведение ChatGPT
не проверялись. Полный автоматический runner проверяет сборку, XCTest,
санитайзеры, Node, bundle, подпись и read-only hardware inventory. Его PASS
не доказывает корректность этих физических сценариев.
