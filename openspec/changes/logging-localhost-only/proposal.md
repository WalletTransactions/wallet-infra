## Why

Аудит безопасности 2026-11-23: в `infra/logging/compose.yaml` у OpenSearch
выключен security-плагин (`plugins.security.disabled=true`), у Dashboards —
тоже, а порты `19200` и `15601` публиковались на `0.0.0.0`. Пока стек логов
запущен, любой в LAN или tailnet читал логи prod и test (`user_id`,
`trace_id`, тексты ошибок) и мог удалить индексы (`DELETE /_all`) или
подложить записи.

## What Changes

- Порты OpenSearch (`19200`) и Dashboards (`15601`) публикуются только на
  `127.0.0.1`. Fluent Bit пишет в OpenSearch по внутренней сети стека, браузер
  открывает `http://localhost:15601` — как и раньше.

## Capabilities

### Modified Capabilities

- `environment-observability` — стек логов доступен только с этой машины.

## Impact

- `infra/logging/compose.yaml`. Сервисы и контуры не меняются.
- Смотреть логи с другой машины — через SSH-туннель
  (`ssh -L 15601:127.0.0.1:15601 ivan-pc`).
