# Proposal

## Why

Пользователи Android и админы в вебе хотят спрашивать «как это работает» и получать
ответ по OpenSpec-спекам репозиториев. Для этого новому сервису `wallet-docs` нужен
векторный поиск (pgvector) в Postgres, а стенд сейчас на `postgres:16-alpine` без
расширения `vector` и без места для базы такого сервиса. Начинать нужно с
инфраструктуры: без неё нельзя ни собрать сервис, ни проверить его на стенде.

Главное требование к фиче — модульность: нет компонента, значит нет фичи, и
ничего вокруг не ломается. Поэтому эта часть должна быть строго опциональной.

## What Changes

- Образ `db` меняется на `pgvector/pgvector:pg16` (тот же Postgres 16, с расширением
  `vector`). Это основа Debian вместо alpine, поэтому существующие тома `db-data`
  пересоздаются, а данные заливаются из логических дампов (`backup.sh`, `pg_dump -Fc`).
  **BREAKING** для тома: старый каталог данных новым образом не подхватывается.
- `init-db.sh` получает необязательный блок `wallet-docs`: база, роль только с DML,
  `CREATE EXTENSION vector`. Блок выполняется, только если в `db.env` заданы
  `DOCS_POSTGRES_*`; иначе база не создаётся, и скрипт работает как раньше.
- `compose.yaml`: сервис `wallet-docs` в профиле `docs`. Без профиля он не
  создаётся, не описывается в `ps` и не мешает запуску. Переменные `DOCS_*` и
  `WALLET_DOCS_TAG` читаются с пустым значением по умолчанию (не `:?`), чтобы
  контур без docs поднимался как сейчас.
- Профиль включается per-контур строкой `COMPOSE_PROFILES=docs` в
  `infra/env/<env>.env`: сначала test, потом prod.
- `up.sh` и `migrate.sh` знают базу `docs`, но трогают её только при включённом
  профиле. Миграции берутся из образа `wallet-docs` (`/migrations`), как у остальных.
- В `wallet-gateway` передаётся `WALLET_DOCS_URL` без `depends_on` (как для
  `wallet-mcp`): упал `wallet-docs` — гейтвей отвечает 502 на `/api/docs/*`.
- Индексы документации не входят в `backup.sh`: они воспроизводимы из Jenkins.

Сам сервис `wallet-docs`, маршрут в гейтвее, заливка из Jenkins и разделы в клиентах —
отдельные change'и в своих репозиториях; здесь только контур.

## Capabilities

### New Capabilities
- `docs-database`: Postgres контура содержит расширение `vector`, а под `wallet-docs`
  заводится собственная база и роль только с DML. Всё это появляется, только если
  задано в секретах контура.
- `docs-service-module`: `wallet-docs` — опциональный модуль контура (compose-профиль
  `docs`). Без него контур, выкат, бэкап и гейтвей работают без изменений; с ним
  сервис поднимается, не добавляя зависимостей другим сервисам.

### Modified Capabilities
<!-- В openspec/specs/ wallet-infra пока нет спек: деплой-спеки лежат в незакрытом
     change add-prod-test-environments. Менять их требования здесь не нужно. -->

## Impact

- **wallet-infra**: `compose.yaml`, `infra/db/init-db.sh`, `infra/env/{up,migrate,lib}.sh`,
  `infra/env/{test,prod}.env`, README (корневой, `infra/db`, `infra/env`).
- **Стенд**: пересоздание `db-data` в test и prod (разовый простой БД); +~50 МБ на образ,
  RAM `db` пока 384 МБ (индекс по ~тысячам чанков для неё некритичен).
- **Вне этого репозитория**: `wallet-docs` (новый C++-сервис, образ в ghcr),
  `wallet-gateway` (маршрут), `android-wallet`, `wallet-web`, Jenkins в BuildPlatform
  (вне git; заливка индекса).
- **Секреты**: `~/.config/wallet-secrets/<env>/db.env` — `DOCS_POSTGRES_USER/PASSWORD/DB`;
  `wallet-docs.env` — по решению сервиса.
