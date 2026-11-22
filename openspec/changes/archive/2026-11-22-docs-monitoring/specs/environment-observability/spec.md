## ADDED Requirements

### Requirement: Prometheus опрашивает wallet-docs
Prometheus SHALL опрашивать `/metrics` необязательного сервиса `wallet-docs` обоих контуров по адресам `wallet-docs-<env>:8089` с меткой `env`. Контур без профиля `docs` SHALL NOT считаться неисправным: цель `wallet-docs` у него `down`, и это допустимо.

#### Scenario: Справка включена
- **WHEN** контур запущен с профилем `docs`, а стек мониторинга перезапущен
- **THEN** цель `wallet-docs` этого контура в Prometheus в состоянии `up`

#### Scenario: Справка выключена
- **WHEN** контур запущен без профиля `docs`
- **THEN** цель `wallet-docs` этого контура `down`, остальные цели не страдают

### Requirement: Строка wallet-docs на дашборде
Дашборд Grafana SHALL содержать строку `wallet-docs` с вопросами по исходу (`docs_answers_total{result}`), долей отказов «этого нет», отклонёнными токенами по причине, заливками индекса по результату, p95 `POST /api/docs/ask`, статусом `up` и памятью контейнера; строка SHALL фильтроваться по контуру переменной `$env`.

#### Scenario: Вопросы видны на дашборде
- **WHEN** на контуре test заданы вопросы справке
- **THEN** панель вопросов строки `wallet-docs` показывает рост `docs_answers_total` по `result`
