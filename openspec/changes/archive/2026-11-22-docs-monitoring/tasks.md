# Tasks

## 1. Prometheus

- [x] 1.1 `prometheus.yml`: job `wallet-docs` (`wallet-docs-prod:8089`, `wallet-docs-test:8089`, метка `env`), комментарий в духе соседних job. Проверка: `promtool check config` (или перезапуск стека без ошибок), цель `wallet-docs` test в `/targets` — `up`, prod — `down` (профиль не включён).

## 2. Grafana

- [x] 2.1 `wallet-overview.json`: строка `wallet-docs` — вопросы по `result`, доля отказов, отклонённые токены по `reason`, заливки индекса по `result`, p95 `/api/docs/ask`, `up`, RSS контейнера; переменная `$env`. Проверка: JSON валиден, дашборд подгружается в Grafana (provisioning), панели строки показывают данные test после нескольких вопросов.

## 3. Проверка на стенде

- [x] 3.1 Перезапустить стек мониторинга (`infra/monitoring/up.sh`), задать несколько вопросов на test. Проверка: в Grafana видны `docs_answers_total` по `result`; панель доли отказов пуста до выката `docs_refusals_total` (wallet-docs, `docs-answer-quality`) — отметить и вернуться после выката. (2026-11-22: стек поднят `up.sh`; на test заданы вопросы справки; в Prometheus цели `wallet-docs` test и prod — `up`; `docs_answers_total{result="answered"}` 31, `docs_refusals_total` 7 — выкачен, панель доли отказов показывает данные; из 7 панелей строки данные у 5, пусты «Отклонённые токены» и «Заливки индекса за час» — за последний час отказов токенов и заливок не было; дашборд `wallet-overview` подхвачен Grafana 11.1.0. Prod-цель `up`, а не `down`, как предполагалось: профиль `docs` на prod уже включён)
