# Spec Delta

## Purpose

Описывает `wallet-docs` как необязательный модуль контура: включается профилем compose, не добавляет зависимостей другим сервисам и при отсутствии не нарушает запуск, выкат и работу остальных сервисов.

## ADDED Requirements

### Requirement: wallet-docs запускается только в профиле docs
Сервис `wallet-docs` SHALL входить в compose-профиль `docs` и запускаться, только если профиль включён в настройках контура (`COMPOSE_PROFILES=docs` в `infra/env/<env>.env`). Без профиля сервис SHALL NOT создаваться, а его контейнер и тег не нужны для старта контура.

#### Scenario: Контур без профиля
- **WHEN** выполняется `infra/env/up.sh <env>` при выключенном профиле и без `WALLET_DOCS_TAG` в `tags.env`
- **THEN** контур поднимается, как до этого change, и `docker compose ps` не показывает `wallet-docs`

#### Scenario: Контур с профилем
- **WHEN** профиль включён, в `tags.env` есть `WALLET_DOCS_TAG`, а в `db.env` заданы `DOCS_POSTGRES_*`
- **THEN** `up.sh` накатывает миграции базы docs, поднимает `wallet-docs` и ждёт состояния healthy

### Requirement: Ни один сервис не зависит от wallet-docs
Ни один другой сервис контура SHALL NOT указывать `wallet-docs` в `depends_on`. Гейтвей SHALL получать адрес сервиса через `WALLET_DOCS_URL` и обращаться к нему на каждый запрос.

#### Scenario: Сервис остановлен
- **WHEN** контейнер `wallet-docs` остановлен или отсутствует
- **THEN** остальные сервисы остаются healthy, а гейтвей на запрос к `/api/docs/*` отвечает 502

#### Scenario: Старт без docs
- **WHEN** контур запускается без `wallet-docs`
- **THEN** гейтвей достигает состояния healthy и не ждёт docs

### Requirement: Выкат wallet-docs идёт тем же путём, что у остальных сервисов
`wallet-docs` SHALL выкатываться через `infra/env/deploy.sh` по тегу образа из ghcr с проверкой `GET /version` внутри сети контура. Миграции базы docs SHALL браться из образа сервиса (`/migrations`).

#### Scenario: Выкат нового тега
- **WHEN** выполняется `infra/env/deploy.sh <env> wallet-docs <тег>` в контуре с включённым профилем
- **THEN** миграции базы docs накатываются из образа, сервис пересоздаётся, а `/version` отдаёт выкаченный тег

#### Scenario: Выкат при выключенном профиле
- **WHEN** тот же выкат запускается в контуре без профиля `docs`
- **THEN** скрипт завершается с понятной ошибкой, что профиль выключен, и не меняет контур
