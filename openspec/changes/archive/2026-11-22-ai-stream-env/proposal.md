# Proposal

## Why

wallet-ai (`chat-sse-events`) отдаёт ход задания chat потоком, гейтвей
(`proxy-sse-stream`) его проксирует, бот (`chat-live-reply`) показывает. Поток
включается переменной `AI_STREAM_ENABLED` (по умолчанию выкл.), а в контуре её
нигде нет: на test она стоит только в локальных секретах, вне репозитория, и
пропадёт при пересборке контура.

## What Changes

- `compose.yaml`: у wallet-ai `AI_STREAM_ENABLED: ${AI_STREAM_ENABLED-false}`.
- `infra/env/test.env`: `AI_STREAM_ENABLED=true`.
- `infra/env/prod.env`: закомментированная строка (включение после test — отдельным решением).
- `infra/env/README.md`: где задаётся и почему не в `wallet-ai.env`.

Остальные параметры потока имеют умолчания и в compose не выводятся.

## Impact

Спеки не меняются (`skip_specs`): поведение контуров описано в
`deployment-environments`, здесь только значение переменной. Выкат — `up.sh test`
после тега wallet-infra. Строку `AI_STREAM_ENABLED=true` из
`~/.config/wallet-secrets/test/wallet-ai.env` после выката убрать: она
перекрывается compose и только вводит в заблуждение.
