# Участие в разработке

Nostromo Codex управляет физическим вводом и может выполнять действия в
ChatGPT. Изменения принимаются только вместе с проверяемыми контрактами и
безопасным поведением при сбоях.

## Перед началом

1. Прочитайте [`ARCHITECTURE.md`](ARCHITECTURE.md) и
   [`AGENTS.md`](AGENTS.md).
2. Проверьте, что задача не требует ослабить compatibility gate, permissions,
   HID isolation или bridge authentication.
3. Для изменения bridge action используйте `BridgeAppAction` и синхронно
   обновите manifest и contract tests. Raw action strings не допускаются.

## Локальная разработка

Требуются Apple Silicon, macOS 26+, Xcode 26+ и Swift 6.3.

```sh
swift test --skip NostromoCodexAppTests.LiveChatGPTE2ETests
node --check Sources/NostromoCodexApp/Resources/chatgpt-preload.cjs
node Tests/preload-unit.cjs
node Tests/preload-smoke.cjs
node Tests/docs-links.cjs
```

Перед передачей готового изменения:

```sh
./scripts/deep-test.sh --full --hardware-inventory
```

Полный runner безопасен: он не запускает приложение, не захватывает HID и не
перезапускает ChatGPT. Физический checklist, HID-only и live ChatGPT E2E
запускаются только вручную и с явным пониманием побочных эффектов.

## Pull request

В PR укажите:

- проблему и выбранное решение;
- затронутые контракты или инварианты;
- выполненные автоматические проверки;
- отдельно — любые ручные проверки и точное окружение;
- что осталось непроверенным.

Не называйте HID, LED или live ChatGPT поведение проверенным по результатам
mock/unit runner. Не включайте в issue, логи или fixtures токены bridge,
локальные пути с персональными данными и пользовательские конфигурации.

## Документация

README должен описывать подтверждённое текущее поведение, а не намерение.
Датированные результаты хранятся в `docs/audits/`; актуальные инструкции —
в `README.md`, `ARCHITECTURE.md` и поддерживаемых документах из
[`docs/README.md`](docs/README.md).
