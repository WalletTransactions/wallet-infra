## ADDED Requirements

### Requirement: Метрики справки wallet-docs в Prometheus и Grafana
Prometheus SHALL опрашивать `/metrics` необязательного сервиса `wallet-docs` обоих контуров по адресам `wallet-docs-<env>:8089` с меткой `env`. Дашборд Grafana SHALL содержать строку `wallet-docs` с вопросами по исходу (`docs_answers_total{result}`), долей отказов «этого нет», отклонёнными токенами по причине, заливками индекса по результату, p95 `POST /api/docs/ask`, статусом `up` и памятью контейнера. Контур без профиля `docs` SHALL NOT считаться неисправным: цель `wallet-docs` у него в состоянии `down`, и это допустимо.

#### Scenario: Справка включена
- **WHEN** контур запущен с профилем `docs`, а стек мониторинга перезапущен
- **THEN** цель `wallet-docs` контура в Prometheus в состоянии `up`, строка `wallet-docs` на дашборде показывает вопросы и p95

#### Scenario: Справка выключена
- **WHEN** контур запущен без профиля `docs`
- **THEN** цель `wallet-docs` этого контура `down`, остальные цели и панели не страдают
