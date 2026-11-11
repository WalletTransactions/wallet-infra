# Tasks

## 1. Подготовка стенда

- [ ] 1.1 Проверить место и версию Postgres: `df -h /` (нужно не меньше 5 ГБ свободно под новый образ), `docker exec wallet-test-db-1 postgres --version`. Проверка: место есть, версия 16.x записана в заметках к выкату.
- [ ] 1.2 Скачать образ `docker.io/pgvector/pgvector:pg16` и убедиться, что в нём есть `vector` и `pg_stat_statements`: `docker run --rm --entrypoint sh pgvector/pgvector:pg16 -c 'ls /usr/share/postgresql/16/extension | grep -E "^(vector|pg_stat_statements)\.control$"'`. Проверка: выведены оба файла.

## 2. compose.yaml (D1, D3, D7, D8)

- [ ] 2.1 Заменить образ `db` на `docker.io/pgvector/pgvector:pg16`, обновить комментарии шапки (расширение `vector`, роль docs в перечне ролей). Проверка: `grep -n "image:" compose.yaml` показывает новый образ у `db`, `postgres:16-alpine` нет нигде в репозитории.
- [ ] 2.2 Добавить в `environment` сервиса `db` переменные `DOCS_POSTGRES_USER/PASSWORD/DB` как `${…-}` (пустое по умолчанию). Добавить сервис `wallet-docs` с `profiles: [docs]`, образом `ghcr.io/wallettransactions/wallet-docs:${WALLET_DOCS_TAG:-unset}`, портом 8089, `mem_limit: 128m`, `env_file` секретов (`required: false`), `DATABASE_URL` на базу docs, `AUTH_SERVICE_URL`, `healthcheck` по `/healthz`, alias `wallet-docs-${WALLET_ENV}`. Проверка: `docker compose config` без профиля не содержит `wallet-docs`, с `--profile docs` — содержит.
- [ ] 2.3 Передать гейтвею `WALLET_DOCS_URL: http://wallet-docs:8089` без `depends_on`, с комментарием по образцу `wallet-mcp`. Проверка: `docker compose --env-file test.env … config` без профиля и без `DOCS_*` проходит без ошибок «переменная не задана» ни для test, ни для prod; в `depends_on` гейтвея нет `wallet-docs`.

## 3. init-db.sh (D5)

- [ ] 3.1 Добавить условный блок docs: если заданы все три `DOCS_POSTGRES_*` — роль, база, `REVOKE CONNECT … FROM PUBLIC`, `GRANT CONNECT` роли docs и `monitoring`, затем в базе docs `CREATE EXTENSION IF NOT EXISTS vector` и `pg_stat_statements`, `GRANT USAGE` и `ALTER DEFAULT PRIVILEGES` на DML и последовательности. Без них блок пропускается с одной строкой в вывод (без значений переменных). Проверка: `sh -n infra/db/init-db.sh` проходит.
- [ ] 3.2 Прогнать скрипт на одноразовом контейнере `pgvector/pgvector:pg16` дважды: сначала без `DOCS_*` (код 0, базы нет), потом с ними (база, роль, `\dx` показывает `vector`), потом повторно (код 0, без изменений). Проверка: три результата совпадают с описанными, а роль docs получает отказ на `CREATE TABLE` и на подключение к базе `wallet`.

## 4. Скрипты контура (D6, D8)

- [ ] 4.1 В `infra/env/lib.sh` добавить `wallet-docs` в `WALLET_SERVICE_PORT` (8089) и базу `docs` в `WALLET_DB_SERVICE`. В `migrate.sh` принять базу `docs` и сообщение об ошибке с её именем. Проверка: `bash infra/env/migrate.sh test docs` на контуре без `DOCS_*` завершается понятной ошибкой «не задан DOCS_POSTGRES_DB».
- [ ] 4.2 В `up.sh` накатывать миграции docs, только если профиль `docs` включён, заданы `DOCS_POSTGRES_DB` и тег `WALLET_DOCS_TAG`; иначе писать в вывод, что docs пропущен. `backup.sh` и `test-refresh.sh` оставить на четырёх базах. Проверка: `up.sh test` на контуре без профиля завершается без упоминания ошибок и без контейнера `wallet-docs`.
- [ ] 4.3 В `deploy.sh` отказывать в выкате `wallet-docs`, если профиль выключен, с сообщением и без изменений контура. Проверка: `deploy.sh test wallet-docs <тег>` на контуре без профиля завершается ошибкой, `git status` и `tags.env` не изменились.

## 5. Документация

- [ ] 5.1 Описать в `infra/db/README.md` роль docs, расширение `vector`, условность блока и правило «индекс не бэкапится»; в `infra/env/README.md` — профиль `docs`, переменные `DOCS_*`, порядок включения (test, затем prod) и откат; в корневом `README.md` — строку про `wallet-docs`. Проверка: каждая команда из новых абзацев выполняется на test как написано.

## 6. Выкат на стенд

- [ ] 6.1 test: `backup.sh test --label pre-pgvector`, затем `down`, удаление тома `db-data`, `up.sh test`, `test-refresh.sh`. Проверка: четыре сервиса здоровы, `curl` через гейтвей `:8091/api/versions` (админ-токеном) возвращает версии без ошибок, в `pg_stat_statements` есть записи.
- [ ] 6.2 test: добавить `DOCS_POSTGRES_*` в `~/.config/wallet-secrets/test/db.env` (права 600, без вывода значений), прогнать `migrate.sh test docs` до появления образа `wallet-docs`: достаточно, чтобы база и расширение создались (`psql -c '\dx'` в базе docs). Проверка: `vector` есть, `wallet-docs` не запущен, `curl :8091/healthz` отвечает 200.
- [ ] 6.3 prod: окно простоя согласовать заранее; `backup.sh prod --label pre-pgvector`, проверка дампов `pg_restore -l`, замена образа и тома, `up.sh prod`, восстановление дампов. Проверка: сервисы prod здоровы, число пользователей и операций в сводке совпадает с записанным до замены.
- [ ] 6.4 Откат отрепетировать на test: вернуть образ `postgres:16-alpine`, пересоздать том и восстановить `pre-pgvector`. Проверка: контур test здоров на старом образе, после чего образ pgvector возвращается.

## Workflow follow-up

- Включить `COMPOSE_PROFILES=docs` в `test.env`, а затем в `prod.env` — после публикации образа `wallet-docs` (отдельный change в репозитории сервиса).
- После выката всех частей фичи архивировать change.
