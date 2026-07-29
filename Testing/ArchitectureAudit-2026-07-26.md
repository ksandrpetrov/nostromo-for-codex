# Архитектурный аудит Nostromo Codex

Дата: 2026-07-26

## Вывод

Точечный рефакторинг выполнен без изменения пользовательского поведения,
bridge protocol v2 и формата `profiles.json` v1. Автоматически проверенный
контур стабилен: критических дефектов и предупреждений сборки не обнаружено.

Рефакторинг уменьшил не общий объём кода, а число неявных контрактов и мест,
где можно создать рассинхронизацию при следующем изменении. `AppModel`
по-прежнему крупный; его дальнейшее механическое дробление сейчас не
обосновано, потому что оно ослабит единый `@MainActor`-владелец состояния и
не даст доказанного выигрыша в стабильности.

## Факты до изменения

- `AppModel`: 1752 строки, 84 метода, 29 публикуемых состояний.
- `UnixSocketBridge`: 1015 строк и пять блокировок.
- Swift bridge actions создавались по свободным строкам и словарям payload.
- Специальная семантика Codex actions была распределена между каталогом,
  моделью и UI.
- Persistent и momentary profile state поддерживались несколькими
  независимыми полями модели.
- Сохранение конфигурации допускало публикацию изменённой in-memory копии до
  подтверждённой записи.

Baseline перед рефакторингом: 188 XCTest, один отдельный render test, release
build с `warnings-as-errors`, preload unit 4/4 и smoke 10/10 проходили.

## Внесённые изменения

### Действия и контракты

- `BridgeAppAction` стал типизированным enum для всех 14 wire actions.
- Wire names, string payload values и protocol version 2 сохранены.
- `CodexActionDescriptor` централизует execution, consequential flag и
  необходимость runtime-регистрации.
- `AppModel` больше не сравнивает специальные Codex command ID.
- Preload использует единый локальный registry действий.
- Тестовый manifest `Tests/Fixtures/bridge-actions.json` сверяется независимо
  со Swift и preload; runtime от fixture не зависит.

### Конфигурация и профили

- Чистый `ProfileRuntimeState` владеет persistent profile и стеком momentary
  holds, включая out-of-order release.
- Постоянные изменения выполняются candidate-first: validate/atomic save,
  затем публикация в UI и lighting/HUD.
- Ошибка записи не публикует новый профиль или конфигурацию.
- Momentary profile остаётся runtime-only и не попадает в persisted snapshot.
- Повреждённый исходный `profiles.json` резервируется один раз перед первым
  успешным восстановлением.
- Отсутствующий additive schema-v1 flag `forceUnsupportedChatGPT` получает
  безопасный default `false`; неизвестная версия и опасная структура
  отклоняются как раньше.

### Bridge и concurrency

- Runtime directory ownership/cleanup вынесены в
  `BridgeRuntimeDirectory`.
- JSON decode/encode и validators вынесены в чистый `BridgeWireCodec`.
- `UnixSocketBridge` получил terminal одноразовый lifecycle и generation
  checks: поздние `.listening`, `.connected` и `.failed` после stop
  подавляются.
- Повторный stop безопасен; start после terminal stop является no-op.
- POSIX transport, существующие очереди, backpressure и socket lock не
  переписывались на actor.
- `ConfigurationStore` больше не имеет необоснованного
  `@unchecked Sendable`; stateless macOS adapters стали Sendable value types.

### Навигация для будущих изменений

- Добавлены `ARCHITECTURE.md`, проектный `AGENTS.md` и секции навигации в
  `AppModel`.
- Зафиксированы владельцы состояния, recovery-инварианты, совместно
  изменяемые контракты и запрет live-операций без отдельного разрешения.

## Метрики после изменения

- `AppModel`: 1737 строк, 84 метода, 29 публикуемых состояний.
- `UnixSocketBridge`: 792 строки и четыре блокировки.
- Выделенные bridge-компоненты: 276 строк runtime directory и 116 строк
  codec.
- Суммарный bridge-код вырос с 1015 до 1184 строк. Это осознанная цена
  явных safety/lifecycle checks и тестируемых границ; заявлять уменьшение
  общего объёма или сложности по одной метрике строк было бы неверно.
- Swift runtime-код не содержит свободных конструкторов или raw wire strings
  bridge actions вне типизированного контракта.

## Автоматическая проверка

Команда:

```sh
./scripts/deep-test.sh --full --hardware-inventory
```

Результат:

- debug и release XCTest: PASS;
- release `warnings-as-errors`: PASS;
- Address Sanitizer: PASS;
- Thread Sanitizer: PASS;
- preload syntax/unit: PASS;
- preload smoke: 50 повторов по 10 сценариев, PASS;
- package, bundle contents, code signature, architecture/minOS: PASS;
- read-only hardware inventory: PASS, найдены обе HID interface Nostromo;
- failures: 0.

После добавления новых contract/state/lifecycle тестов полный обычный набор
содержит 198 XCTest, из них один opt-in live test пропускается, плюс один
Swift Testing render test. Новый охват включает typed wire serialization,
manifest parity, все execution-типы, неизвестную и недоступную команду,
candidate-first rollback, legacy decode, единственную corrupt backup,
momentary ordering и terminal bridge lifecycle.

## Ограничения и неизвестное

Автоматический runner не запускал приложение, не открывал и не захватывал HID,
не отправлял feature reports, не изменял LED и не перезапускал ChatGPT.
Поэтому физическая матрица controls, реальное lighting-поведение и live
ChatGPT E2E остаются непроверенными manual gates. Наличие устройства в
IORegistry подтверждено, его рабочее поведение — нет.

Также не доказано, что дальнейшее уменьшение `AppModel` улучшит проект.
Возвращаться к этому стоит только при появлении конкретного нового
независимого владельца состояния или повторяющихся дефектов на его границе.
