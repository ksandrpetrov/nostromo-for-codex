# Nostromo Codex — автоматизированный release audit

> Исторический снимок ревизии от 2026-07-26. Automation получила `PASS`,
> но публичный релиз остался `NO-GO`.

Дата: 2026-07-26  
Основной run: `20260726T125054Z`  
Финальная матрица: `20260726T135625Z`

## Итог

| Область | Статус |
|---|---|
| Автоматизированный release candidate в доступном scope | **PASS** |
| Открытые P0 / P1 / P2 в доступном scope | **0 / 0 / 0** |
| Публичный релиз | **NO-GO** |

Кандидат прошёл сборку, тесты, sanitizers, упаковку, GUI-приёмку,
30-минутный soak и recovery-матрицу без открытых P0–P2. Это не означает,
что публичный релиз доказан: физический ввод, визуальные LED-состояния и
live-интеграция с ChatGPT намеренно не были выданы за автоматизированный
`PASS`.

Предыдущий зелёный отчёт не использовался как доказательство. Все результаты
ниже получены заново после изменений bridge, AppModel, preload и тестов.

## Кандидат и окружение

| Поле | Значение |
|---|---|
| Хост | Apple Silicon, `arm64` |
| macOS | 26.5.2, build 25F84 |
| Xcode | 26.6, build 17F113 |
| Swift | 6.3.3 |
| Node.js | 26.0.0 |
| ChatGPT | 26.721.41059 (5848) |
| Устройство | Razer Nostromo `1532:0111`, две HID-интерфейса |
| Git metadata | отсутствует |
| Bundle | `dist/Nostromo Codex.app` |
| Архитектура / deployment target | arm64 only / macOS 26.0 |
| Подпись | `Nostromo Codex Local Development`, strict codesign PASS |

Идентификаторы кандидата:

- source tree SHA-256:
  `3a96c64a5590bb09e09e2ec67d8b76f8629e59ddd9d4434ec5bb9e65591ee837`;
- bundle-manifest SHA-256:
  `c864216dd639bda0ef46c1bbb9be2c12a5ed1954bd348ffe6d78ab3227582a77`;
- executable SHA-256:
  `c6c11fe1e19ea4e1165f596e1f6e992422599b7f99e059b91c68bd9026722f66`;
- preload SHA-256:
  `868fbd846d7e15045380095c16aed0bb1434537b6cc588d3635545b319da20bd`;
- `Info.plist` SHA-256:
  `8787f32e645f75881c216f88d2b11d69e0e18bb9fab3d22fa1a41e779daaf565`.

Локальная подпись доказывает целостность этого кандидата, но не заменяет
Developer ID signing и notarization для публичной поставки.

## Безопасность прогона

- Установленный `/Applications/Nostromo Codex.app` не заменялся.
- ChatGPT не завершался и не перезапускался; основной PID `749` сохранился
  от начала до конца.
- Полная автоматическая матрица не открывала HID-устройство и не отправляла
  feature reports.
- GUI-тестирование затрагивало только Nostromo Codex и обратимые настройки.
- Light mode и `AppleKeyboardUIMode=3` включались временно; финально
  восстановлены исходные `Dark` и отсутствующий `AppleKeyboardUIMode`.
- Один промежуточный GUI-запрос по имени приложения дополнительно запустил
  установленный Nostromo. Эти снимки исключены из доказательств, лишний
  процесс штатно завершён, а GUI-приёмка повторена с адресацией точного
  `dist`-пути.

## Финальная автоматизированная матрица

`deep-test.sh --full --hardware-inventory`: **14/14 PASS**, 0 failures.

| Проверка | Результат |
|---|---:|
| Environment capture | PASS |
| Debug tests | PASS |
| Release tests | PASS |
| Warnings as errors | PASS |
| AddressSanitizer | PASS |
| ThreadSanitizer | PASS |
| Preload syntax | PASS |
| Preload unit | PASS |
| Preload smoke | PASS |
| Package app | PASS |
| Bundle contents | PASS |
| Strict codesign | PASS |
| arm64 / minos 26.0 | PASS |
| Read-only HID inventory | PASS |

В Debug, Release, ASan и TSan выполнено по 184 XCTest: 0 failures,
1 live opt-in тест штатно пропущен. Отдельный Swift Testing test рендеринга
light/dark прошёл в каждой конфигурации.

Preload:

- socket-free unit: 4/4;
- 50 итераций × 10 сценариев = 500/500;
- покрыты scoped catalog, capability/runtime gates, неподдерживаемая и
  forced версия, task slots, virtual HID actions, PTT failsafe, close queue,
  wrong token, malformed JSON и handshake больше 1 MiB.

В логах финальной матрицы нет сообщений ASan, TSan, data race, runtime error,
compiler warning или fatal error.

## Бизнес-сценарии и защитные ветки

Автоматизированно подтверждены:

- onboarding/readiness без раннего HID-захвата и без запуска или завершения
  ChatGPT;
- создание, переименование, дублирование, удаление с подтверждением и Undo
  профилей;
- export/import с отменой, preview валидного файла, malformed JSON,
  pre-import backup, миграции и round-trip;
- каждый `BindingAction`, каждый `ControlID` и каждая проверенная
  Codex-команда;
- task slots, skills, plugin prompt без auto-submit, shortcuts,
  постоянные и моментальные профили;
- D-pad, колесо, PTT, debounce, reconnect gate, synthetic calibration,
  disconnect и shutdown failsafe;
- compatibility gate, capability manifest, неизвестные и недоступные
  команды, expert override без обхода обязательных модулей;
- bridge wrong token, fragmented/malformed framing, предел 1 MiB,
  backpressure, concurrency, 10 authenticated reconnect и восстановление
  сервера после ошибки;
- runtime permissions: каталог `0700`, socket и `.owner` `0600`.

Схема `profiles.json` и bridge protocol не менялись. Миграции,
backward-compatible decoding и round-trip тесты прошли.

## Coverage

Coverage использовался для поиска пробелов, а не как самостоятельный
release-критерий:

- regions: 46.71%;
- lines: 38.48%.

Критичные участки:

| Файл / область | Line coverage |
|---|---:|
| `UnixSocketBridge.swift` | 87.50% |
| `ConfigurationStore.swift` | 94.64% |
| `Models.swift` | 95.41% |
| `Project2077.swift` | 95.34% |
| D-pad / wheel / Razer protocol | 100% |
| PTT state machine | 100% |
| `NostromoHIDManager.swift` | 8.91% |

Низкий общий показатель вызван главным образом SwiftUI/AppKit и реальными
IOHID-ветками. Эти пробелы не скрыты: они относятся к GUI/hardware/live
gates ниже.

## GUI-приёмка release bundle

Проверен точный `dist/Nostromo Codex.app`:

- lifecycle окна, повторное открытие, menu-bar fallback и отсутствие
  дубликатов;
- русский интерфейс при 1100×700, длинное кириллическое имя профиля и emoji;
- light и dark mode без clipping;
- полный Tab-проход при системном full keyboard access: профиль, keypad,
  колесо, восемь направлений D-pad, выбор действия, input-test и sidebar;
- AX Description/Help/Value, tooltips и закрытие error banner;
- Profiles, Layout, Connection, Lighting, Diagnostics;
- malformed import error и его dismissal;
- restart-warning с обязательной отменой.

LED test-flash прошёл путь отправки без диагностической ошибки
`IOHIDDeviceSetReport`. Фактический цвет глазами оператора не подтверждён и
остаётся `BLOCKED`.

## Стабильность и recovery

Чистый release soak:

| Метрика | Результат | Порог |
|---|---:|---:|
| Длительность / samples | 30 минут / 360 из 360 | 30 минут |
| Crash / dead samples | 0 | 0 |
| CPU p95 | 0.0% | ≤ 2% |
| Максимальный RSS | 145072 KiB | ≤ 153600 KiB |
| Максимальный RSS после 5 минут | 74080 KiB | ≤ 153600 KiB |
| RSS trend после прогрева | −303.649 KiB/мин | ≤ 1024 KiB/мин |
| FD span после прогрева | 1 | ≤ 2 |
| FD endpoint drift | 0 | ≤ 2 |

Первый предварительный soak после интенсивной GUI-приёмки не засчитывался:
в начале RSS составлял около 190 MiB. После определения загрязнения
методики приложение было штатно перезапущено и выполнен отдельный чистый
30-минутный прогон, приведённый в таблице.

Recovery:

- normal launch/quit: 10/10;
- SIGKILL → persisted marker/orphan runtime → recovery launch → normal quit:
  3/3;
- после каждого normal quit: runtime `0`, recovery marker `0`,
  device-scoped mapping `0`;
- во время работы: runtime `1`, marker `1`, 20 device-scoped suppression
  mappings;
- после SIGKILL ожидаемо оставались runtime `1`, marker `1`, mappings `20`;
  следующий запуск удалял stale runtime, а quit полностью восстанавливал
  состояние.

## Изменения тестов и дефекты

Дефектов P0–P2 в доступном автоматизированном scope не найдено, поэтому код
продукта не менялся.

Добавлены регрессии:

1. все доступные runtime-команды Swift-каталога должны присутствовать в
   allowlist preload;
2. factory calibration должна однозначно покрывать каждый физический
   `ControlID`;
3. каждая проверенная Codex-команда должна dispatch-иться либо быть явно
   недоступной;
4. bridge должен отклонять unauthenticated сообщение больше 1 MiB и после
   этого принимать новый client;
5. preload authentication-сценарий дополнен oversized handshake.

Открытых P3 продукта не зарегистрировано. Промежуточный запуск установленного
приложения по неточному GUI-target был артефактом тестового инструмента, а не
поведением Nostromo Codex.

## Целостность и восстановление

До и после совпали хеши:

- ChatGPT `app.asar`:
  `da39a51b06fb4c728d418b8f0f05fc8fd8c6b1f74c4fb4d47c20c7914a798f45`;
- ChatGPT executable:
  `d7bd5eacb7f59c42240e6c5dc62eebdeca9d09a0b59ed4c3ac3e2b55ef8d9336`;
- установленный Nostromo executable:
  `df08d28a3113ab3d7510bb347bc250509bfb5336231e36c3db69fc5d4fa22c09`;
- установленный Nostromo preload:
  `868fbd846d7e15045380095c16aed0bb1434537b6cc588d3635545b319da20bd`.

Пользовательское состояние восстановлено побайтно:

- `profiles.json`:
  `a201daeb237e7a44e0cea0eab9747cf1b5ab7838eaecea9bf8545a0e5c97e68d`;
- preferences:
  `c45105a05a4c3c5f780f7c4b2288bfca8ff5594cce674a943b464592bdd60624`;
- global `UserKeyMapping`: исходное `(null)`.

Финально восстановлено исходное активное состояние: запущен один
установленный Nostromo, dist-кандидат остановлен, runtime/marker и 20
device-scoped suppression mappings активны, ChatGPT остаётся PID `749`.

## Обязательные незакрытые gates

Публичный статус остаётся **NO-GO** до выполнения на финальном бинарнике:

1. физические 16 клавиш, все направления и переходы D-pad, колесо, PTT,
   duplicate suppression, latency и unplug/replug;
2. визуальная проверка LED-состояний;
3. контролируемый restart ChatGPT и реальный preload/bridge: handshake,
   task slots, Codex actions, skills и plugin prompt без auto-submit;
4. runtime-проверка на минимальной macOS 26.0;
5. повтор на другом Mac и другом экземпляре Razer Nostromo;
6. для публичной дистрибуции — Developer ID signing и notarization.

До закрытия этих пунктов слово `PASS` применимо только к автоматизированному
кандидату, но не к публичному релизу.

## Артефакты

Все логи и machine-readable результаты:

`/tmp/nostromo-automated-qa-20260726/20260726T125054Z/`

Ключевые файлы:

- `final-matrix/20260726T135625Z/summary.md`;
- `final-matrix/20260726T135625Z/results.jsonl`;
- `logs/clean-soak-samples.tsv`;
- `logs/clean-soak-summary.json`;
- `logs/launch-quit-cycles.tsv`;
- `logs/sigkill-recovery-cycles.tsv`;
- `logs/coverage-report-final2.txt`;
- `final/overall-results.json`;
- `final/source-manifest.sha256`;
- `final/candidate-bundle-manifest.sha256`;
- `final/final-user-process-state-check.txt`.
