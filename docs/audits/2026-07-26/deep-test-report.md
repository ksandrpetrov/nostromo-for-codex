# Nostromo Codex — отчёт глубокого тестирования

> Архивный объединённый отчёт. Он содержит результаты нескольких
> последовательных состояний исходников и не описывает текущую ветку.

## Актуальный автоматизированный RC audit — 2026-07-26

Авторитетный результат текущего дерева зафиксирован в
[`automated-release-audit.md`](automated-release-audit.md).
Предыдущий зелёный отчёт не переиспользован: bridge, AppModel, preload и
тесты изменялись после него.

- автоматизированный кандидат: `PASS`;
- публичный релиз: **`NO-GO`**;
- финальный runner: 14/14 шагов, 0 failures;
- Debug, Release, ASan и TSan: по 184 XCTest, 1 live skip, 0 failures;
- preload: 50 × 10 = 500/500 сценариев;
- bridge: 20/20, включая 10 reconnect, wrong token, malformed/oversized
  framing, backpressure и concurrency;
- GUI точного dist bundle: русский light/dark при 1100×700, profiles,
  import/export, Connection, Lighting, Diagnostics, restart cancel и полный
  keyboard/AX-проход;
- soak: 30 минут, 360/360 samples, CPU p95 0%, max RSS 145072 KiB,
  post-warmup slope −303.649 KiB/мин, FD span 1;
- launch/quit 10/10, SIGKILL/recovery 3/3;
- открытые P0–P2 в доступном scope: 0;
- ChatGPT и установленные bundle-файлы не изменены;
- profiles/preferences/UserKeyMapping и исходное активное состояние процесса
  восстановлены.

Обязательные ручные gates: физический ввод и latency, unplug/replug,
визуальные LED-состояния, live preload/bridge после контролируемого restart
ChatGPT, минимальная macOS 26.0 и второй Mac/Nostromo. Без них публичный
релиз не принимается.

## Предыдущий release-readiness прогон — исторический

[`release-readiness-report.md`](release-readiness-report.md)
содержит результаты более раннего состояния исходников. Он сохранён для
истории, но не является доказательством текущего кандидата.

## Исторический baseline

| Поле | Значение |
|---|---|
| Дата baseline | 2026-07-25 |
| Хост | Apple Silicon M5, arm64 |
| macOS | 26.5.2 (25F84) |
| Xcode / Swift | Xcode 26.6 / Swift 6.3.3 |
| Node.js | 26.0.0 |
| ChatGPT | 26.721.41059 (5848) |
| Nostromo | Razer Nostromo, `1532:0111` |
| Исходная ревизия | Git metadata отсутствует в рабочем каталоге |
| Итоговый прогон | 2026-07-25 17:34:01 UTC, 0 failures |
| Swift regression | 139/139 в debug, release, ASan и TSan |
| Preload regression | 50/50 запусков × 8 сценариев = 400/400 исполнений |

Итоговый расширенный прогон: debug/release, `warnings-as-errors`, ASan,
TSan, preload smoke 50/50, strict-проверка ad hoc signature, arm64-only
и deployment target macOS 26.0 — пройдены. Read-only HID inventory
повторно проверена отдельно сразу после runner-а и также прошла.

Нативный UI/live-bridge этап 2026-07-25 получил статус `BLOCKED`: три
повторные попытки Computer Use подтвердили, что Mac заблокирован и
автоматическая разблокировка недоступна. ChatGPT не перезапускался,
системные privacy-разрешения не изменялись. Этот внешний блокер не
преобразуется в `PASS` и не влияет на результат безопасной матрицы.

## Предыдущая проверка исправлений — 2026-07-26

Это отдельный прогон после физической приёмки, а не изменение исторического
baseline выше.

- 149/149 Swift-тестов, не требующих создания Unix-сокета, прошли в Debug,
  Release, ASan и TSan; release build отдельно прошёл с
  `warnings-as-errors`.
- Полный каталог содержит ещё 11 `UnixSocketBridgeTests`. Текущая управляемая
  среда запрещает `bind/listen` с `EPERM`, поэтому эти тесты здесь `BLOCKED`,
  а не `PASS`. Исторический baseline этих тестов остаётся пройденным.
- `node --check` и socket-free preload regression прошли. Она отдельно
  подтверждает восстановление свёрнутого/скрытого окна (`restore`, `show`,
  `moveTop`, Electron focus и macOS activation) и отсутствие раннего
  `require("electron")` при NODE_OPTIONS bootstrap.
- Добавлено device-scoped подавление клавиатурных usages только для
  `1532:0111`, с сохранением и восстановлением прежней `UserKeyMapping`.
  Merge/lifecycle проверены unit-тестами. Отсутствие печати физической кнопкой
  после исправления не проверено: оператор больше не может нажимать Nostromo.
- D-pad теперь принимает фактически наблюдавшиеся page-7 arrow usages и
  объединяет cardinal edges в один diagonal action; это покрыто core и
  AppModel regression.
- Постоянная индикация показывает активный профиль в idle (с возможностью
  выбрать «Выкл.»), завершённую непрочитанную задачу — синим, активную задачу —
  зелёным, а требование действия — красным; независимые статусы могут
  включать несколько индикаторов одновременно.
- Изолированный ImageRenderer-прогон рабочей области раскладки 1056×650
  подтвердил фиксированную высоту карты устройства 350 pt вместо растяжения
  на всю высоту окна. Он не заменяет визуальную проверку всего окна:
  нативные controls инспектора этим renderer-ом полностью не отрисовываются.
- Профиль пользователя после тестов совпадает с сохранённым оригиналом по
  SHA-256: `8b0720bbecf92f64b4eabc7a1ddf757b4dff88ce33ee51dab36b6617f1af7445`.
- Актуальный `dist/Nostromo Codex.app` собран из последнего release-бинарника,
  имеет arm64 deployment target 26.0, идентичный preload и проходит
  `codesign --verify --deep --strict`. Подпись ad hoc: доступ к стабильному
  локальному signing keychain запрещён управляемой средой.
- LaunchServices из этой среды возвращает ложный `kLSNoExecutableErr`, хотя
  executable существует, исполняем и валиден. Прямой запуск прекращается в
  системном `___RegisterApplication` внутри coalition `com.openai.codex`.
  Поэтому запуск GUI и live-подключение здесь `BLOCKED`, а не `PASS`.

Артефакты этого прогона:

`/var/folders/fl/k5gvl2rd61x0kw35hnf4syjc0000gn/T/nostromo-codex-deep-test/20260725T173401Z/`

Актуальный полный прогон выполняется командой:

```sh
./scripts/deep-test.sh --full --hardware-inventory
```

Логи, `results.jsonl` и итоговый `summary.md` сохраняются в системном
временном каталоге, а не в репозитории. Путь runner печатает в начале и
конце запуска.

## Автоматическая матрица

| Проверка | Команда / критерий | Baseline |
|---|---|---:|
| Debug unit tests | `swift test -c debug --arch arm64` | PASS |
| Release unit tests | `swift test -c release --arch arm64` | PASS |
| Warnings as errors | release build с `-warnings-as-errors` | PASS |
| AddressSanitizer | debug tests с `--sanitize address` | PASS |
| ThreadSanitizer | debug tests с `--sanitize thread` | PASS |
| Preload syntax | `node --check` | PASS |
| Preload socket-free | bootstrap и восстановление свёрнутого окна | PASS |
| Preload stability | 50 × 8 сценариев = 400 исполнений | PASS |
| Status LEDs | idle → профиль; completed → синий; active → зелёный; action → красный | PASS |
| Lighting settings | migration, предел яркости, 220-мс pulse и profile flash | PASS |
| Keyboard suppression | scoped map merge и lifecycle restore | PASS |
| App packaging | `scripts/build-app.sh release` | PASS |
| Bundle integrity | plist, executable и идентичный preload | PASS |
| Code signature | `codesign --verify --deep --strict`, ad hoc | PASS |
| Architecture | ровно `arm64` | PASS |
| Deployment target | `LC_BUILD_VERSION minos 26.0` | PASS |
| HID inventory | два интерфейса `1532:0111`, feature report 90 | PASS |

Runner сознательно продолжает работу после отдельного сбоя, чтобы собрать
всю матрицу, но возвращает ненулевой exit code, если упал хотя бы один шаг.
Он не открывает приложение, не захватывает HID, не посылает LED reports и
не запускает/останавливает ChatGPT.

## Историческая нативная UI/live-матрица

| Проверка | Критерий | Статус |
|---|---|---:|
| Первый запуск release bundle | Setup и Connection доступны, UI не зависает | BLOCKED — Mac locked |
| Runtime diagnostics | Capability manifest, API shape и reasoning видны после handshake | BLOCKED — Mac locked |
| Restart bridge | ChatGPT перезапускается с preload, authenticated socket подключается | BLOCKED — Mac locked |
| Целостность ChatGPT до теста | Strict codesign и SHA-256 двух основных файлов сняты | PASS |

До блокировки подтверждены исходные SHA-256:

- `app.asar`: `da39a51b06fb4c728d418b8f0f05fc8fd8c6b1f74c4fb4d47c20c7914a798f45`;
- `Contents/MacOS/ChatGPT`:
  `d7bd5eacb7f59c42240e6c5dc62eebdeca9d09a0b59ed4c3ac3e2b55ef8d9336`.

После разблокировки эти же хэши и strict signature должны совпасть после
live restart. До этого момента нельзя утверждать, что bridge E2E пройден.

## Вывод и границы результата

В автоматизированной и read-only области не воспроизведено ни одного
P0/P1-дефекта: все 13 шагов runner завершились с `PASS`. Это не означает
готовность физической и live-ChatGPT части: соответствующие строки ниже
остаются `NOT RUN`, а не считаются пройденными косвенно.

Локально исправлены проверяемые ограничения P2:

- preload извлекает command registry из фактически установленного
  `app.asar`, пересекает его с проверенным безопасным набором и передаёт
  приложению runtime capability manifest. До получения manifest
  registry-зависимые команды заблокированы;
- skills загружаются через Codex app-server `skills/list` с effective
  `enabled` и scope. Зависание app-server ограничено timeout; локальный
  scanner оставлен только как деградированный fallback;
- Diagnostics показывает источник каталога, состояние требуемых Electron
  API, недоступные функции и доступный renderer-у reasoning level;
- preflight дополнительно проверяет shape обязательных renderer/app-server
  API внутри `app.asar`; override версии не обходит отсутствие этих API;
- ошибки `IOHIDDeviceSetReport` теперь проверяются и выводятся отдельной
  диагностикой.

Остаются ограничения, которые build ChatGPT 5848 не позволяет закрыть
безопасно:

- `compact`, `status` и permissions picker отсутствуют среди 100
  зарегистрированных desktop command descriptors этой сборки. Вызов
  внутренних thread API без надёжной связи с активной UI-задачей мог бы
  изменить не тот thread, а имитация slash-команды могла бы отправить
  существующий composer. Поэтому эти три функции помечаются недоступными;
- чтение reasoning level является best-effort из доступного DOM. При иной
  локализации/shape renderer возвращается `Not exposed by renderer`, а не
  выдуманное состояние;
- plugin prompt вставляет официальный Markdown mention без auto-send, но
  превращение mention в rich chip остаётся поведением renderer ChatGPT;
- физический цвет status LEDs после новой семантики не повторён: логика
  разрешения состояния и Razer reports покрыта тестами, но визуальный
  результат на конкретном устройстве остаётся live E2E.

Первые три недоступные desktop-функции — незакрытый P2 относительно
исходного плана и внешний блокер build 5848. Rich plugin chip — P3.
Физический и live E2E ниже не считаются пройденными по unit-тестам.

## Физическая матрица

Статусы ниже объединяют исходную физическую приёмку и текущую проверку
исправлений. `NOT RUN` означает, что конкретный пункт не был подтверждён;
`Logic PASS` не заменяет физический или live E2E. Первые HID-проверки
запускаются через
`./scripts/hardware-test.sh --launch-hid-only`: этот режим журналирует raw
events, но не подключает bridge и не исполняет назначения. После прогона
экспортировать JSON из раздела «Диагностика» и полностью завершить
приложение.

| Проверка | Процедура | Критерий | Статус |
|---|---|---|---:|
| 16 клавиш | Каждую нажать 10 раз в калибровке | 160 циклов / 320 edges, без потерь и дублей | PASS — исходный физический прогон |
| Колесо | 20 шагов в каждую сторону | Знак и число шагов совпадают | PASS — исходный физический прогон |
| Нажатие колеса | 10 коротких, 10 длинных, 10 с вращением | Нет click после вращения; long от 600 мс | PASS — исходный физический прогон |
| Джойстик | 10 раз каждое из 8 направлений | Одно стабильное направление на жест | FAIL в исходном app; page-7 fix проверен unit, физически не повторён |
| Переходы джойстика | Cardinal↔diagonal по кругу | Нет ложного соседнего action | NOT RUN |
| Exclusive seize | Нажать все controls при активном приложении | Нет системных дубликатов | FAIL — `kIOReturnNotPrivileged`; заменено scoped suppression, физически не повторено |
| Штатный выход | Завершить Nostromo Codex | Устройство сразу возвращается в обычный HID | PASS — исходный физический прогон |
| Crash recovery | Принудительно завершить приложение | HID освобождён, PTT/shortcut/profile не зависли | PASS — исходный физический прогон |
| Reconnect | Три unplug/replug цикла | Повторное подключение без перезапуска | PASS — 3/3 исходного физического прогона |
| LEDs / статусы | Idle, completed, active, needs action | Профиль → синий → зелёный → красный | Logic PASS; физически не повторено |
| Latency | Снять 100 HID→callback измерений | p95 ≤ 30 мс | NOT AVAILABLE в старом JSON; экспорт исправлен, физически не повторён |
| Bridge handshake | Перезапуск через Nostromo в отдельной задаче | Synthetic `303A:8360`, authenticated RPC, ChatGPT.app не изменён | NOT RUN |
| Навигация задач | Slots 1–6, previous/next/new/fork/side chat | Каждое действие срабатывает ровно один раз | NOT RUN |
| Session modes | Plan, Fast, reasoning ±, model и worktree | UI активной задачи отражает изменение либо adapter явно отказывает | NOT RUN |
| Task actions | Approve, Decline, Stop, Send и Focus | Действие применяется только к ожидаемой задаче | NOT RUN |
| Skills | Активный и затем удалённый/disabled skill | Активный вызывается; недоступный не заменяется другим | NOT RUN |
| Plugin prompt | Пустой и заполненный composer | Mention подготовлен, auto-send отсутствует | NOT RUN |
| Attach Files | Cancel, один и несколько файлов | Cancel — no-op; выбранные файлы прикреплены по одному разу | NOT RUN |
| PTT | Hold, double-press latch, disconnect | Нет зависшей записи | NOT RUN |
| Профили | Конкретный, next и momentary switch | Binding и возврат соответствуют выбранному профилю | NOT RUN |
| Task LEDs | Idle, unread/completed, running, approval/input/error | Профиль, синий, зелёный, красный | Logic PASS; live не повторён |
| Five-minute soak | Работать всеми controls пять минут | Нет crash, stuck action, роста памяти или потери reconnect | PASS — исходный физический прогон |

Перед E2E сохранить незавершённый composer: кнопка «Перезапустить через
Nostromo» штатно завершает ChatGPT. После теста завершить Nostromo Codex и
запустить ChatGPT обычным способом, затем убедиться, что preload не
сохранился в окружении нового процесса.

## Поля результата и дефекта

Для каждого физического прогона заполнить:

- дата/время и оператор;
- macOS, Xcode/Swift, ChatGPT version/build;
- серийный экземпляр устройства или заметка, позволяющая его отличить;
- configuration JSON и активный профиль;
- шаг матрицы, ожидаемый и фактический результат;
- количество повторов, потерь, дублей и p50/p95 latency;
- путь к логам и при необходимости видео;
- итог `PASS`, `FAIL` или `BLOCKED`.

Для дефекта:

| Поле | Требование |
|---|---|
| ID / severity | `NC-…`; P0–P3 |
| Build / environment | Точные версии приложения, ChatGPT и macOS |
| Preconditions | Профиль, binding, wheel mode, состояние задачи |
| Steps | Минимальная воспроизводимая последовательность |
| Expected / actual | Наблюдаемое различие без интерпретации |
| Reproducibility | Число воспроизведений из числа попыток |
| Evidence | Лог, timestamp, raw HID signature, screenshot/video |
| Recovery | Освободился ли HID, остановился ли PTT, сохранён ли config |

P0/P1 — crash, потеря конфигурации, неверное действие, auto-send plugin,
stuck input/PTT, HID-дубли, обход compatibility gate — блокируют приёмку.
P2/P3 фиксируются в отчёте, но не блокируют личный build, если не влияют на
безопасность ввода.
