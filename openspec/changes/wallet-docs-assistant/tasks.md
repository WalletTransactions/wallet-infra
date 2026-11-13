# Tasks

## 1. Подготовка стенда

- [x] 1.1 Проверить место и версию Postgres: `df -h /` (нужно не меньше 5 ГБ свободно под новый образ), `docker exec wallet-test-db-1 postgres --version`. Проверка: место есть, версия 16.x записана в заметках к выкату.
- [x] 1.2 Скачать образ `docker.io/pgvector/pgvector:pg16` и убедиться, что в нём есть `vector` и `pg_stat_statements`: `docker run --rm --entrypoint sh pgvector/pgvector:pg16 -c 'ls /usr/share/postgresql/16/extension | grep -E "^(vector|pg_stat_statements)\.control$"'`. Проверка: выведены оба файла.

## 2. compose.yaml (D1, D3, D7, D8)

- [x] 2.1 Заменить образ `db` на `docker.io/pgvector/pgvector:pg16`, обновить комментарии шапки (расширение `vector`, роль docs в перечне ролей). Проверка: `grep -n "image:" compose.yaml` показывает новый образ у `db`, `postgres:16-alpine` нет нигде в репозитории.
- [x] 2.2 Добавить в `environment` сервиса `db` переменные `DOCS_POSTGRES_USER/PASSWORD/DB` как `${…-}` (пустое по умолчанию). Добавить сервис `wallet-docs` с `profiles: [docs]`, образом `ghcr.io/wallettransactions/wallet-docs:${WALLET_DOCS_TAG:-unset}`, портом 8089, `mem_limit: 128m`, `env_file` секретов (`required: false`), `DATABASE_URL` на базу docs, `AUTH_SERVICE_URL`, `healthcheck` по `/healthz`, alias `wallet-docs-${WALLET_ENV}`. Проверка: `docker compose config` без профиля не содержит `wallet-docs`, с `--profile docs` — содержит.
- [x] 2.3 Передать гейтвею `WALLET_DOCS_URL: ${WALLET_DOCS_URL-}` без `depends_on`, с комментарием по образцу `wallet-mcp`. Проверка: `docker compose --env-file test.env … config` без профиля и без `DOCS_*` проходит без ошибок «переменная не задана» ни для test, ни для prod; в `depends_on` гейтвея нет `wallet-docs`, а `WALLET_DOCS_URL` у гейтвея пуст.

## 3. init-db.sh (D5)

- [x] 3.1 Добавить условный блок docs: если заданы все три `DOCS_POSTGRES_*` — роль, база, `REVOKE CONNECT … FROM PUBLIC`, `GRANT CONNECT` роли docs и `monitoring`, затем в базе docs `CREATE EXTENSION IF NOT EXISTS vector` и `pg_stat_statements`, `GRANT USAGE` и `ALTER DEFAULT PRIVILEGES` на DML и последовательности. Без них блок пропускается с одной строкой в вывод (без значений переменных). Проверка: `sh -n infra/db/init-db.sh` проходит.
- [x] 3.2 Прогнать скрипт на одноразовом контейнере `pgvector/pgvector:pg16` дважды: сначала без `DOCS_*` (код 0, базы нет), потом с ними (база, роль, `\dx` показывает `vector`), потом повторно (код 0, без изменений). Проверка: три результата совпадают с описанными, а роль docs получает отказ на `CREATE TABLE` и на подключение к базе `wallet`.

## 4. Скрипты контура (D6, D8)

- [x] 4.1 В `infra/env/lib.sh` добавить `wallet-docs` в `WALLET_SERVICE_PORT` (8089) и базу `docs` в `WALLET_DB_SERVICE`. В `migrate.sh` принять базу `docs` и сообщение об ошибке с её именем. Проверка: `bash infra/env/migrate.sh test docs` на контуре без `DOCS_*` завершается понятной ошибкой «не задан DOCS_POSTGRES_DB».
- [x] 4.2 В `up.sh` накатывать миграции docs, только если профиль `docs` включён, заданы `DOCS_POSTGRES_DB` и тег `WALLET_DOCS_TAG`; иначе писать в вывод, что docs пропущен. `backup.sh` и `test-refresh.sh` оставить на четырёх базах. Проверка: `up.sh test` на контуре без профиля завершается без упоминания ошибок и без контейнера `wallet-docs`.
- [x] 4.3 В `deploy.sh` отказывать в выкате `wallet-docs`, если профиль выключен, с сообщением и без изменений контура. Проверка: `deploy.sh test wallet-docs <тег>` на контуре без профиля завершается ошибкой, `git status` и `tags.env` не изменились.

## 5. Документация

- [x] 5.1 Описать в `infra/db/README.md` роль docs, расширение `vector`, условность блока и правило «индекс не бэкапится»; в `infra/env/README.md` — профиль `docs`, переменные `DOCS_*`, порядок включения (test, затем prod) и откат; в корневом `README.md` — строку про `wallet-docs`. Проверка: каждая команда из новых абзацев выполняется на test как написано.

## 6. Выкат на стенд

- [x] 6.1 test: `backup.sh test --label pre-pgvector`, затем `down`, удаление тома `db-data`, `up.sh test`, `test-refresh.sh`. Проверка: четыре сервиса здоровы, `curl` через гейтвей `:8091/api/versions` (админ-токеном) возвращает версии без ошибок, в `pg_stat_statements` есть записи.
- [x] 6.2 test: добавить `DOCS_POSTGRES_*` в `~/.config/wallet-secrets/test/db.env` (права 600, без вывода значений), прогнать `migrate.sh test docs` до появления образа `wallet-docs`: достаточно, чтобы база и расширение создались (`psql -c '\dx'` в базе docs). Проверка: `vector` есть, `wallet-docs` не запущен, `curl :8091/healthz` отвечает 200.
- [x] 6.3 prod: окно простоя согласовать заранее; `backup.sh prod --label pre-pgvector`, проверка дампов `pg_restore -l`, замена образа и тома, `up.sh prod`, восстановление дампов. Проверка: сервисы prod здоровы, число пользователей и операций в сводке совпадает с записанным до замены.
- [ ] 6.4 Откат отрепетировать на test: вернуть образ `postgres:16-alpine`, пересоздать том и восстановить `pre-pgvector`. Проверка: контур test здоров на старом образе, после чего образ pgvector возвращается.

## Заметки к выкату

- 1.1 (2026-11-13): свободно 15 ГБ на `/`; Postgres test и prod — 16.15 (alpine), в `pgvector/pgvector:pg16` — 16.15 (Debian), образ 621 МБ.
- 1.2: в образе есть `vector.control` и `pg_stat_statements.control`.
- 2.1–2.3: `docker compose config` с поддельными секретами и тегами (настоящие не печатаются) на `test.env` и `prod.env`: без профиля и без `DOCS_*`/`WALLET_DOCS_TAG` — код 0, `wallet-docs` нет, у гейтвея `WALLET_DOCS_URL` пуст; с `--profile docs` — сервис есть; с `COMPOSE_PROFILES=docs` и `WALLET_DOCS_URL` в env-файле — сервис есть и адрес задан (D4 работает через `--env-file`). В `depends_on` никого `wallet-docs` нет. `16-alpine` в репозитории не осталось (кроме openspec).
- 3.2: одноразовый `pgvector/pgvector:pg16`: без `DOCS_*` — строка «пропущена», базы и роли нет; с ними — база, `vector 0.8.7`, `pg_stat_statements`; повтор — код 0, ACL базы прежний. Роль docs: DML — да, `CREATE TABLE` — `permission denied for schema public`, `TRUNCATE` — отказ, подключение к чужой базе — отказ; `dumper` к базе docs — отказ.
- 4.1, 4.3 на живом test: `migrate.sh test docs` — «не задан DOCS_POSTGRES_DB»; `deploy.sh test wallet-docs 0.1.0` — «профиль docs … выключен»; `backup.sh test docs` — «индекс docs не бэкапится»; `tags.env` и контейнеры не изменились.
- Сверх design: (а) `deploy.sh` в prod не снимает дамп базы docs перед миграцией — иначе выкат падал бы (у `dumper` нет `CONNECT`); (б) `up.sh` при включённом профиле без `DOCS_POSTGRES_DB` или тега выключает профиль на этот запуск (`COMPOSE_PROFILES=` процесса сильнее `--env-file`, проверено), иначе compose тянул бы `wallet-docs:unset`.
- 6.1 (2026-11-13, 08:05–08:08, 3 минуты): по решению владельца **без** `backup.sh test` (данные test берутся из prod). Под одной блокировкой test: `down` → `docker volume rm wallet-test_db-data` → push тега `v0.4.0-rc.1` → `deploy.sh test wallet-infra 0.4.0-rc.1` (свежий том на `pgvector/pgvector:pg16`, миграции всех баз, smoke гейтвея) → `test-refresh.sh` (четыре базы из prod, миграции test поверх, FLUSHALL Redis). Все 10 сервисов healthy, `pg_stat_statements` — 1922 записи, `vector 0.8.7` доступен, `wallet` на версии 36. Проверка `/api/versions` админ-токеном не делалась (сессии test сброшены перезаливкой).
- 4.2 на живом test (тег `v0.4.0-rc.1`): `up.sh test` без профиля — «docs пропущен: профиль docs выключен», контейнера `wallet-docs` нет.
- 6.2: `DOCS_POSTGRES_*` в test `db.env` (600) добавил владелец; `up.sh test` пересоздал `db` с новыми переменными, `migrate.sh test docs` создал базу `wallet_docs` с `vector 0.8.7` и `pg_stat_statements` (CONNECT — мигратор, роль docs, monitoring) и завершился ожидаемой ошибкой «нет тега wallet-docs». `wallet-docs` не запущен, гейтвей 200. Шаблон `infra/db/.env.example` с `DOCS_POSTGRES_*` — PR #20.
- 6.3 (2026-11-13): по решению владельца **без** бэкапа и восстановления — в prod практически не было данных, база начата с нуля. Финальный тег `v0.4.0` на коммит `bc9a6d26`, проверенный в test (`v0.4.0-rc.1`). Первая попытка (08:24) упала на первой миграции: в `MIGRATOR_POSTGRES_PASSWORD` prod попала кириллическая буква, URL мигратора не разбирается (`net/url: invalid userinfo`); автооткат на `v0.2.0` упал на том же секрете — prod лежал ~9 минут. Пароль заменён (ASCII), том пересоздан ещё раз, `deploy.sh prod wallet-infra 0.4.0` (08:33) — ok: 10 сервисов healthy, `:8090/healthz` 200, Postgres 16.15 (Debian), `vector.control` в образе. Пароль мигратора prod сменён (старый засветился в выводе ошибки).
- 5.1: команды README про профиль проверены в 4.1–4.3 и 6.1–6.2; включение профиля и выкат сервиса — после первого образа wallet-docs.
- Для полного подключения сервиса по чек-листу «Новый сервис в контуре» ещё нужны цель в `infra/monitoring/prometheus.yml`, имя в whitelist `infra/logging/fluent-bit.conf` и `wallet-docs` в `SERVICE` job'ов `env-deploy`/`env-rollback` — в задачах этого change их нет, делаются вместе с первым образом сервиса.

## Workflow follow-up

- Включить `COMPOSE_PROFILES=docs` и `WALLET_DOCS_URL=http://wallet-docs:8089` в `test.env`, а затем в `prod.env` — после публикации образа `wallet-docs` (отдельный change в репозитории сервиса).
- После выката всех частей фичи архивировать change.
