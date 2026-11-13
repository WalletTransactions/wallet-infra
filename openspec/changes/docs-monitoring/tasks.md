# Tasks

## 1. Prometheus

- [ ] 1.1 `prometheus.yml`: job `wallet-docs` (`wallet-docs-prod:8089`, `wallet-docs-test:8089`, метка `env`), комментарий в духе соседних job. Проверка: `promtool check config` (или перезапуск стека без ошибок), цель `wallet-docs` test в `/targets` — `up`, prod — `down` (профиль не включён).

## 2. Grafana

- [ ] 2.1 `wallet-overview.json`: строка `wallet-docs` — вопросы по `result`, доля отказов, отклонённые токены по `reason`, заливки индекса по `result`, p95 `/api/docs/ask`, `up`, RSS контейнера; переменная `$env`. Проверка: JSON валиден, дашборд подгружается в Grafana (provisioning), панели строки показывают данные test после нескольких вопросов.

## 3. Проверка на стенде

- [ ] 3.1 Перезапустить стек мониторинга (`infra/monitoring/up.sh`), задать несколько вопросов на test. Проверка: в Grafana видны `docs_answers_total` по `result`; панель доли отказов пуста до выката `docs_refusals_total` (wallet-docs, `docs-answer-quality`) — отметить и вернуться после выката.
