# Физическая и live-приёмка

Эта матрица выполняется вручную на финальном бинарнике. Перед началом
зафиксируйте ревизию, macOS, ChatGPT version/build и конкретный экземпляр
Nostromo. Не переносите результаты между сборками.

## Физическая матрица

Начните с HID-only, чтобы исключить действия в ChatGPT:

```sh
./scripts/build-app.sh release
./scripts/hardware-test.sh --launch-hid-only
```

| Проверка | Процедура | Критерий |
|---|---|---|
| 16 клавиш | Каждую нажать 10 раз | 160 циклов / 320 edges, без потерь и дублей |
| Колесо | 20 шагов в каждую сторону | Знак и число шагов совпадают |
| Нажатие колеса | 10 коротких, 10 длинных, 10 с вращением | Нет click после вращения; long от 600 мс |
| D-pad | 10 раз каждое из восьми направлений | Одно стабильное направление на жест |
| Переходы D-pad | Cardinal ↔ diagonal по кругу | Нет ложного соседнего action |
| Isolation | Нажать все controls при активном текстовом поле | Нет системных дубликатов |
| Reconnect | Три unplug/replug цикла | Повторное подключение без ложного action |
| Штатный выход | Завершить Nostromo Codex | Устройство сразу возвращается в обычный HID |
| Crash recovery | Принудительно завершить приложение | HID освобождён, PTT/action/profile не зависли |
| LEDs | Ready, running, attention, unavailable | Каждый видимый статус соответствует модели |
| Latency | Снять не менее 100 HID → callback измерений | Зафиксированы p50/p95 и условия измерения |
| Five-minute soak | Работать всеми controls пять минут | Нет crash, stuck action, утечки или потери reconnect |

Экспортируйте raw HID JSON из Diagnostics и полностью завершите HID-only
экземпляр перед live-проверкой.

## Live ChatGPT E2E

Сначала сохраните незавершённый composer: контролируемый restart штатно
завершает текущий ChatGPT.

| Проверка | Критерий |
|---|---|
| Bridge handshake | Synthetic `303A:8360`, authenticated RPC, `ChatGPT.app` не изменён |
| Task slots | Slots 1–6 соответствуют отображаемым задачам |
| Навигация | Previous/next/new/fork/side chat выполняются ровно один раз |
| Modes | Plan, Chat/Work, reasoning, model и worktree меняют ожидаемое состояние либо явно отклоняются |
| Consequential actions | Approve, Decline, Stop и Send применяются только к ожидаемой задаче |
| Skills | Активный skill вызывается; disabled/удалённый не подменяется |
| Plugin prompt | Mention и шаблон подготовлены без auto-submit |
| Attach Files | Cancel — no-op; выбранные файлы прикреплены по одному разу |
| PTT | Hold, double-press latch и disconnect не оставляют запись активной |
| Profiles | Persistent, next и momentary switch дают ожидаемое назначение и возврат |

После теста завершите Nostromo Codex, запустите ChatGPT обычным способом и
убедитесь, что preload не сохранился в окружении нового процесса.

## Протокол результата

Для каждого шага запишите:

- `PASS`, `FAIL`, `BLOCKED` или `NOT RUN`;
- дату, оператора, revision и точные версии окружения;
- предусловия, число повторов и ожидаемый/фактический результат;
- путь к логам, raw HID JSON и при необходимости видео;
- способ восстановления и состояние HID/PTT/config после теста.

Crash, потеря конфигурации, неверное действие, auto-send plugin, stuck
input/PTT, HID-дубли и обход compatibility gate блокируют приёмку.
