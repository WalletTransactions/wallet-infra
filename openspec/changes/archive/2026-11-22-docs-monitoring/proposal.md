# Proposal

## Why

`wallet-docs` отдаёт `/metrics` (`docs_answers_total`, `docs_answers_without_sources_total`,
`docs_auth_rejected_total`, `docs_index_total`, общие `http_*`), но Prometheus его не
опрашивает, а в Grafana нет строки про справку: цели `wallet-docs-<env>:8089` в
`prometheus.yml` нет, в `wallet-overview.json` есть строки для остальных сервисов, для docs —
нет. Качество ответов (change `docs-answer-quality` в wallet-docs) и ложные отказы после
каждого выката приходится мерить скриптом вручную.

## What Changes

- `infra/monitoring/prometheus.yml`: job `wallet-docs` с целями `wallet-docs-prod:8089` и
  `wallet-docs-test:8089` (метка `env`), как у `wallet-mcp`. Сервис необязательный
  (compose-профиль `docs`): на контуре без профиля цель просто `down`, это не ошибка.
- `wallet-overview.json`: строка «wallet-docs — вопросы, отказы, индекс» — вопросы в минуту
  по `result`, доля отказов «этого нет» (по новому счётчику `docs_refusals_total` из
  `docs-answer-quality`), отклонённые токены по `reason`, заливки индекса по `result`,
  p95 `/api/docs/ask`, `up`, RSS контейнера.
- Устаревший текст в комментариях `prometheus.yml` («HTTP-сервисы проекта…») дополняется
  упоминанием docs.

## Capabilities

### New Capabilities

Нет.

### Modified Capabilities

- `environment-observability`: новое требование — метрики необязательного модуля
  `wallet-docs` собираются и видны в Grafana по контуру.

## Impact

- `wallet-infra`: `infra/monitoring/prometheus.yml`, `infra/monitoring/grafana/dashboards/
  wallet-overview.json`. Prometheus перечитывает конфиг при перезапуске стека мониторинга
  (`infra/monitoring/up.sh`); сервисы контуров не затрагиваются.
- Зависимость: панель доли отказов появится с данными после выката счётчика
  `docs_refusals_total` (wallet-docs, change `docs-answer-quality`); до этого она пуста.
