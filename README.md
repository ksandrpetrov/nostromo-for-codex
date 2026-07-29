# Nostromo Codex

Персональная нативная панель действий Codex для Razer Nostromo RZ07-0049 на
Apple Silicon. Karabiner не используется: приложение читает интерфейсы
`1532:0111` через `IOHIDManager`, а ChatGPT видит локально эмулированный
Codex Micro (`303A:8360`).

## Что реализовано

- Menu bar-приложение на Swift 6 / SwiftUI / AppKit, arm64 и macOS 26+.
- Значок постоянно находится в верхней строке меню; приложение не показывает
  отдельную иконку в нижнем Dock.
- Guided setup не захватывает HID и не запускает ChatGPT до явного
  завершения; readiness виден в menu bar и отдельном Connection-разделе.
- Интерактивный digital twin повторяет 15 основных клавиш, thumb key 16,
  колесо и восемь направлений D-pad; безопасный Input Test подсвечивает
  физический ввод, но не исполняет назначения.
- Nostromo всегда открывается как отдельный макропад с автоматическим
  эксклюзивным HID-захватом. Если macOS запрещает `seize`, приложение
  продолжает чтение в обычном режиме и включает отдельную защиту от печати.
- При успешном эксклюзивном HID-захвате системная карта клавиш не меняется.
  Если macOS разрешила только shared capture, клавиатурные HID-сервисы только
  самого Nostromo `1532:0111` транзакционно переназначаются в `Undefined`.
  Запись проверяется read-back, предыдущая карта атомарно сохраняется и
  восстанавливается при отключении или следующем запуске. Пока ни один из
  способов изоляции не подтверждён, назначения блокируются fail-closed.
- Переназначение 16 клавиш и восьми направлений джойстика.
- Типы назначений: task slot, Codex command, skill, plugin prompt, macOS
  shortcut, постоянное/моментальное переключение профиля и `none`.
- В категории режимов есть отдельное действие `Chat / Work`: оно переключает
  верхний сегмент домашнего композитора и не меняет режим Codex или worktree.
- Колесо: scroll; зажать и вращать — reasoning; короткое нажатие — смена
  режима; 600 мс — панель настроек. Вращение подавляет click.
- Push-to-talk по удержанию; двойное нажатие фиксирует запись.
- Основная JSON-конфигурация в Application Support; импорт и экспорт через
  системные файловые диалоги. Перед импортом показывается summary и создаётся
  восстановимая резервная копия текущей конфигурации.
- Searchable action library, shortcut recorder, подтверждение перезапуска
  ChatGPT и удаления профиля, Undo последнего удаления.
- Неактивирующий runtime HUD показывает профиль, режим колеса и состояние PTT
  поверх рабочего пространства, не забирая keyboard focus у ChatGPT.
- Калибровка всех клавиш, восьми векторов джойстика и нажатия колеса.
- Project2077 bridge через Unix socket с одноразовым 256-битным токеном,
  правами `0700/0600` и лимитами сообщений.
- Razer feature reports для общей подсветки и profile LEDs.
- Отдельный Lighting-раздел настраивает предел яркости и видимую 220-мс
  обратную связь при нажатии.
  Аппаратно Nostromo поддерживает общую подсветку клавиш, а не поклавишный RGB.
- Три фиксированных profile LEDs не настраиваются и используются только для
  агрегированного состояния Codex: красный — задача ждёт действия пользователя
  или завершилась ошибкой, зелёный — есть выполняющаяся задача, синий — Codex
  подключён, свободен и готов. Индикаторы взаимоисключающие с приоритетом
  красный → зелёный → синий; когда Codex недоступен, все три выключены.
  Статусные LEDs не зависят от таймера автогашения подсветки Codex Micro.
- Проверка версии и наличия внутренних модулей до запуска ChatGPT.

Приложение не изменяет и не переподписывает `/Applications/ChatGPT.app`.
Preload передаётся только дочернему процессу через `NODE_OPTIONS`.

## Сборка

Требуются Swift 6.3 / SwiftPM 6.3, Xcode 26+ и установленный
`/Applications/ChatGPT.app`.

```sh
./scripts/build-app.sh
open "dist/Nostromo Codex.app"
```

Иконка приложения собирается в `AppIcon.icns` из
`Resources/AppIcon.png` автоматически.

При первой сборке скрипт создаёт отдельную локальную code-signing identity
в `~/Library/Application Support/Nostromo Codex/Signing`. Следующие сборки
подписываются той же identity, поэтому macOS распознаёт их как обновления
одного приложения и не привязывает privacy-разрешения к меняющемуся CDHash.

При первом запуске разрешите Input Monitoring в:

`System Settings → Privacy & Security → Input Monitoring`.

Если вы назначаете обычные macOS shortcuts, отдельно разрешите отправку
системных событий в:

`System Settings → Privacy & Security → Accessibility`.

Без этого разрешения приложение явно отклоняет shortcut и показывает
ошибку вместо молчаливого no-op.

Если ChatGPT уже запущен, используйте **Restart ChatGPT…** в разделе
Connection. Приложение сначала покажет подтверждение и напомнит сохранить
незавершённый текст в composer, затем перезапустит ChatGPT с приватным bridge.

Конфигурация хранится в:

`~/Library/Application Support/Nostromo Codex/profiles.json`

## Проверка

Карта владельцев состояния, bridge/configuration contracts и инварианты
безопасных изменений описаны в
[`ARCHITECTURE.md`](ARCHITECTURE.md). Короткие правила для дальнейшего
агентного редактирования находятся в [`AGENTS.md`](AGENTS.md), а фактические
результаты точечного рефакторинга — в
[`Testing/ArchitectureAudit-2026-07-26.md`](Testing/ArchitectureAudit-2026-07-26.md).

```sh
swift test
node --check Sources/NostromoCodexApp/Resources/chatgpt-preload.cjs
node Tests/preload-unit.cjs
node Tests/preload-smoke.cjs
```

Unit-тесты покрывают Project2077 framing/RPC, wheel gestures, PTT latch,
восемь направлений, debounce, все типы назначений, JSON round-trip,
авторитетный `skills/list`, runtime capability manifest и golden Razer
reports/checksum.

### Глубокое тестирование

Полный безопасный прогон:

```sh
./scripts/deep-test.sh --full --hardware-inventory
```

Он последовательно проверяет debug/release tests, сборку с
`warnings-as-errors`, ASan, TSan, синтаксис, socket-free регрессию preload
и 50 smoke-запусков preload,
упаковку `.app`, содержимое bundle, strict-проверку локальной signature,
arm64-only и minimum macOS 26.0. Все шаги выполняются даже после отдельного
сбоя; итоговый exit code будет ненулевым, если упал хотя бы один.

Baseline 2026-07-25: 12/12 шагов полного runner-а и отдельная read-only
HID inventory имеют статус `PASS`; 139/139 Swift-тестов отдельно в debug,
release, ASan и TSan; 50 запусков по 8 preload-сценариев
(400/400 исполнений). Это безопасный автоматизированный scope, а не
физическая или live-ChatGPT приёмка.

Быстрый прогон без санитайзеров:

```sh
./scripts/deep-test.sh --quick
```

Логи, `results.jsonl` и `summary.md` записываются под
`${TMPDIR}/nostromo-codex-deep-test/<UTC timestamp>/`, то есть вне
репозитория. Другой каталог задаётся флагом `--results-dir`.

Runner не открывает Nostromo Codex, не захватывает HID, не пишет в LEDs и
не запускает/останавливает ChatGPT. Read-only инвентаризацию подключённого
устройства и ручной checklist можно вызвать отдельно:

```sh
./scripts/hardware-test.sh --inventory
./scripts/hardware-test.sh --checklist
```

Для физической проверки без bridge и без риска отправить действие в
ChatGPT сначала соберите приложение, затем запустите отдельный режим:

```sh
./scripts/build-app.sh release
./scripts/hardware-test.sh --launch-hid-only
```

В `HID-only` приложение может эксклюзивно захватить Nostromo и управлять
его диагностической подсветкой, но не стартует bridge, не
запускает/останавливает ChatGPT, не выполняет shortcuts, bindings или
переходы профилей. Последние 2000 raw HID-событий видны и экспортируются
как JSON в разделе «Диагностика». Перед обычным E2E полностью завершите
HID-only экземпляр.

Полная матрица, baseline и форма для дефектов находятся в
[`Testing/DeepTestReport.md`](Testing/DeepTestReport.md). Физические
нажатия, LEDs и bridge E2E с перезапуском ChatGPT остаются отдельным ручным
этапом и не помечаются пройденными по результатам автоматического runner.

## Граница совместимости

Целевая разрешённая сборка adapter-а: ChatGPT `26.721.41059 (5848)`;
preload/mock regression для неё пройден. Полный live E2E с этой сборкой
остаётся ручным этапом. Неизвестная сборка блокируется. Override для
непроверенной сборки находится под Expert options в Connection, но не означает
совместимость.

При запуске preload читает command registry фактически установленного
`app.asar`, пересекает его с проверенным безопасным набором действий и
передаёт capability manifest приложению. Пока manifest не получен,
registry-зависимые команды заблокированы. Если shape registry изменился,
используется только проверенный fallback для разрешённой сборки; неизвестный
command ID всегда отклоняется. Build 5848 не регистрирует desktop-команды
для permissions picker, `compact` и `status`, поэтому они явно показываются
как недоступные, а не имитируются через ввод в composer.

Skills загружаются через официальный Codex app-server `skills/list` для
текущего workspace, включая effective `enabled` и scope. При недоступности
app-server после ограниченного timeout используется локальный scanner как
деградированный fallback.

Diagnostics показывает полный путь HID → mapping → назначение → bridge,
режим захвата, состояние защиты ввода, источник runtime command catalog,
наличие требуемых Electron API, недоступные функции, ошибки LED feature
reports и доступный renderer-у текущий reasoning level. В JSON-экспорт
добавлены версия и путь приложения, macOS/архитектура и структурированные
счётчики обработки. Последний reasoning level является best-effort:
если build или локализация не экспонирует состояние в DOM, UI честно
показывает `Not exposed by renderer`.

Plugin binding вставляет официальный Markdown mention вида
`[@Name](plugin://stable-uri)` и шаблон в активный composer без отправки.
В build 5848 нет публичного renderer API для создания rich plugin node в
существующем composer; поэтому визуальное превращение mention в chip
остаётся поведением самого ChatGPT. Авторизация и workspace policy не
обходятся.

Физическая приёмка HID, LEDs и полного restart bridge должна выполняться
вручную: автоматический тест не перезапускает текущий ChatGPT и не может
достоверно проверить механику конкретного экземпляра Nostromo.
