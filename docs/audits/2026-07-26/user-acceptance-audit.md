# Nostromo Codex — пользовательский и технический аудит

> Исторический отчёт, superseded более поздними исправлениями и
> [`automated-release-audit.md`](automated-release-audit.md).

Дата: 2026-07-26  
Среда: macOS 26.5.2 (25F84), arm64, Xcode 26.6, Swift 6.3.3, Node 26.0.0  
Сборка ChatGPT: 26.721.41059 (5848), проверенный adapter  
Устройство: Razer Nostromo `1532:0111`, два ожидаемых HID-интерфейса

## Вывод

Приложение нельзя считать полностью готовым к ежедневному использованию из-за одного
воспроизводимого P1-дефекта: при удалённом menu-bar item окно после закрытия невозможно
штатно вернуть, хотя процесс продолжает работать. Основная бизнес-логика, конфигурация,
bridge protocol, state machines и большинство проверенных пользовательских сценариев
работают.

Полный runner завершился с четырьмя `FAIL`, но все четыре вызваны одним дефектом
rendering-теста на Retina. Остальные 161 XCTest проходят в каждом проверенном режиме;
preload, packaging, signature, architecture и read-only HID inventory прошли.

Live bridge, реальные назначения ChatGPT, физические нажатия, D-pad, колесо, PTT,
reconnect и визуальная проверка LED не выполнялись по согласованным ограничениям.

## Автоматическая матрица

| Проверка | Результат | Примечание |
|---|---:|---|
| Debug tests | FAIL | 161 XCTest PASS; Retina assertion FAIL |
| Release tests | FAIL | тот же Retina assertion |
| Warnings as errors | PASS | release build |
| AddressSanitizer | FAIL | функциональные тесты проходят; тот же rendering assertion |
| ThreadSanitizer | FAIL | функциональные тесты проходят; тот же rendering assertion |
| Preload syntax/unit | PASS | 2/2 socket-free regressions |
| Preload smoke | PASS | 50 × 9 сценариев = 450 исполнений |
| Packaging/bundle | PASS | bundle и preload согласованы |
| Code signature | PASS | strict verification |
| Architecture/minimum OS | PASS | arm64, macOS 26.0 |
| HID inventory | PASS | keyboard + mouse interface, feature report 90 |

Логи полного запуска сохранены вне репозитория:
`/tmp/nostromo-audit-20260726.dBwOKf/deep-test/20260726T060310Z/`.

## Пользовательские сценарии

| Сценарий | Результат | Наблюдение |
|---|---:|---|
| Раскладка и digital twin | PASS с замечанием | выбор элементов и inspector работают; подписи на keycaps часто обрезаны |
| Библиотека действий | PASS | категории, поиск и прокрутка работают |
| Недоступная команда | PASS | `Разрешения` остаётся недоступной и не назначается |
| Создание профиля | PASS | новый профиль создаётся и активируется |
| Длинное имя профиля | PASS с замечанием | editor переносит текст; sidebar/list обрезают без полного visual fallback |
| Дублирование профиля | PASS | создаётся копия и становится активной |
| Удаление профиля | PASS | есть явное destructive confirmation |
| Undo удаления | PASS | профиль и активное состояние восстанавливаются |
| Export/Import cancel | PASS | системные панели закрываются без изменения конфигурации |
| Import file filtering | PASS | неподдерживаемые файлы недоступны для выбора |
| Настройки подсветки | PASS логически | toggle и test flash меняют состояние; физический результат не подтверждён |
| Connection/recovery copy | PASS | статусы устройства и build понятны |
| Restart ChatGPT protection | PASS | показано предупреждение о незавершённом composer; выполнена отмена |
| Onboarding welcome/connect | PASS | текст влезает, hierarchy и next/back понятны |
| Onboarding keymap/input test | BLOCKED | live-переход прерван lifecycle-дефектом; логика покрыта тестами |
| Diagnostics | PARTIAL | структура и accessibility проверены статически; raw physical data отсутствуют |
| Keyboard/AX navigation | PARTIAL | основные controls имеют labels/values/hints; полный VoiceOver-прогон заблокирован окном |

## Дефекты

### NC-UI-001 — P1 — приложение становится недоступным без menu-bar item

**Факт.** В исходных пользовательских preferences было
`menuBarExtraInserted = false`. После закрытия окна процесс Nostromo Codex оставался
активным, но:

- dashboard отсутствовал;
- menu-bar item отсутствовал;
- Dock icon отсутствовал из-за `LSUIElement = true`;
- повторный `open` bundle и прямой запуск executable не возвращали окно;
- Computer Use и accessibility получали `cgWindowNotFound`.

**Ожидание.** Повторный запуск приложения или `Cmd+,` должен всегда открывать dashboard,
даже если пользователь удалил menu-bar item.

**Риск.** Пользователь теряет единственный штатный путь к настройкам и выключению
контроллера. Для восстановления требуются внешнее завершение процесса и ручная работа с
preferences.

**Вероятная причина (вывод из кода).** `MenuBarExtra` полностью управляется persisted
`isInserted`, а приложение является accessory app. Единственный `openWindow` listener
находится внутри label исчезающего `MenuBarExtra`; application delegate не обрабатывает
reopen/activate как fallback.

### NC-TEST-002 — P2 — rendering test не учитывает Retina scale

`DesignSystemRenderingTests` задаёт view `920×620` points, но сравнивает
`bitmap.pixelsWide/High` с `920/620`. На Retina получено `1840×1240`, поэтому debug,
release, ASan и TSan steps получают `FAIL`.

Это дефект теста, а не доказательство неправильной геометрии UI. Он, однако, делает
заявление о полностью зелёном deep-test baseline неверным для текущей машины.

### NC-UI-003 — P2 — основные назначения нечитаемы на digital twin

На минимальном поддерживаемом окне большинство 72-point keycaps показывают фрагменты
вроде `Подтве…`, `Отклон…`, `Быстры…`. Полное значение доступно в inspector и
accessibility, но пользователь не может быстро считать всю раскладку как карту.

Это особенно мешает главной продуктовой задаче — пространственному запоминанию
назначений. Нужны короткие устойчивые labels/icons либо адаптивная типографика,
проверенная snapshot-тестами.

### NC-UI-004 — P3 — обрезанные длинные имена не имеют visual disclosure

Длинное имя корректно переносится в editor, но обрезается в sidebar и profile list.
Accessibility содержит полное значение, однако для обычного pointer-пользователя
profile row не добавляет `.help(profile.name)` или другой способ увидеть полное имя.

## Что подтверждено тестами, но не live E2E

- безопасный Input Test и калибровка без dispatch;
- wheel click/hold/rotation boundaries;
- PTT latch и disconnect failsafe;
- восемь направлений D-pad, debounce и reconnect gate;
- все binding variants и configuration round-trip;
- import validation и pre-import backup;
- authenticated Unix socket, malformed clients и backpressure;
- runtime capability manifest и блокировка неизвестных command IDs;
- skill/plugin dispatch без auto-submit;
- lighting priority и Razer report checksums;
- scoped keyboard suppression и restore.

## Неизвестное

Без физического участия и restart ChatGPT нельзя утверждать, что работают:

- реальные 16 клавиш, восемь направлений, колесо и latency;
- отсутствие печатных дублей в стороннем приложении;
- unplug/replug и crash recovery на текущей сборке;
- физические LED-цвета и яркость;
- authenticated live handshake с ChatGPT;
- task slots/actions, session modes, attachments, skills/plugins и PTT в реальном UI.

## План исправлений

1. **P1 lifecycle.** Перенести обработку reopen/activate в application delegate или
   отдельный всегда существующий coordinator. При отсутствии visible windows вызывать
   `openWindow(id: "dashboard")`; не полагаться на label условного `MenuBarExtra`.
   Добавить integration test для `menuBarExtraInserted=false`, close, terminate/relaunch
   и `applicationShouldHandleReopen`.
2. **Rendering test.** Проверять logical size с учётом `bitmap.size` либо
   `backingScaleFactor`, или явно рендерить через `ImageRenderer(scale: 1)`. Повторить
   debug/release/ASan/TSan и требовать полностью зелёный runner.
3. **Digital twin labels.** Ввести короткий display label отдельно от полного
   `BindingSummary`, добавить icon для устойчивых действий и snapshots всех binding
   categories при минимальном размере окна.
4. **Long-name disclosure.** Добавить tooltip/help для sidebar и profile rows; покрыть
   очень длинные Cyrillic/Latin/emoji names визуальными тестами.
5. После исправлений повторить полный runner и live UI. Затем отдельно выполнить
   физическую и live-ChatGPT матрицу из
   [`deep-test-report.md`](deep-test-report.md).

## Целостность после аудита

- `profiles.json` восстановлен побайтно: SHA-256 до и после совпадает.
- Preferences восстановлены семантически и побайтно после XML-нормализации.
- Основные файлы `/Applications/ChatGPT.app` не изменились; SHA-256 совпадает.
- ChatGPT не перезапускался и не завершался.
- Nostromo Codex оставлен завершённым: при исходном
  `menuBarExtraInserted=false` точное восстановление одновременно и preferences, и
  открытого доступного окна невозможно из-за NC-UI-001.
