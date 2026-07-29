# Проверка Nostromo Codex

Проверки разделены по побочным эффектам. Автоматический runner безопасен для
повседневной разработки; физические и live-сценарии запускаются отдельно и
не считаются пройденными косвенно.

## Быстрый цикл

```sh
swift test --skip NostromoCodexAppTests.LiveChatGPTE2ETests
node --check Sources/NostromoCodexApp/Resources/chatgpt-preload.cjs
node Tests/preload-unit.cjs
node Tests/preload-smoke.cjs
node Tests/docs-links.cjs
```

Этого достаточно для локальной итерации над Swift, bridge contracts, preload
и документацией.

## Полный автоматический runner

```sh
./scripts/deep-test.sh --full --hardware-inventory
```

Runner продолжает работу после отдельного сбоя, собирает итоговую матрицу и
возвращает ненулевой exit code, если не прошёл хотя бы один шаг. Логи,
`results.jsonl` и `summary.md` сохраняются вне репозитория:

```text
${TMPDIR}/nostromo-codex-deep-test/<UTC timestamp>/
```

Другой каталог задаётся через `--results-dir`. Быстрый вариант без
санитайзеров:

```sh
./scripts/deep-test.sh --quick
```

Автоматический runner проверяет:

- debug/release XCTest и release build с warnings-as-errors;
- AddressSanitizer и ThreadSanitizer;
- preload syntax, unit и повторяемый smoke regression;
- сборку и содержимое `.app`, strict signature, arm64 и minimum macOS;
- по флагу `--hardware-inventory` — только read-only IORegistry inventory.

Он не открывает приложение, не захватывает HID, не посылает LED reports и
не запускает/останавливает ChatGPT.

## Ручные проверки

```sh
./scripts/hardware-test.sh --inventory
./scripts/hardware-test.sh --checklist
```

`--inventory` только читает IORegistry. Checklist печатается из
[`hardware-acceptance.md`](hardware-acceptance.md).

Режим ниже уже имеет аппаратные побочные эффекты:

```sh
./scripts/build-app.sh release
./scripts/hardware-test.sh --launch-hid-only
```

HID-only может эксклюзивно захватить Nostromo и управлять диагностической
подсветкой, но не запускает bridge, ChatGPT, shortcuts, bindings или
переходы профилей. Перед live E2E этот экземпляр нужно полностью завершить.

Полный live E2E перезапускает ChatGPT и выполняется только по отдельному
явному решению оператора.

## Интерпретация результата

- `PASS` относится только к фактически выполненному шагу и конкретной
  ревизии.
- `Logic PASS` не заменяет физическую проверку.
- `BLOCKED` означает внешний блокер, а не успешный результат.
- `NOT RUN` нельзя выводить из покрытия unit/mock тестами.

Датированные результаты хранятся в [`audits/`](audits/). Они являются
историческими снимками, а не rolling badge текущей ветки.
