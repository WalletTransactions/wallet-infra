# Tasks

## 1. Хост

- [x] 1.1 Освободить место на `/`: `docker builder prune` и `docker image prune` (около 12 ГБ, D10). Проверка: `df -h /` показывает не меньше 20 ГБ свободно.
- [x] 1.2 Выполнить `docker login ghcr.io` токеном `read:packages` на хосте (D3). Проверка: `docker pull` любого опубликованного образа `ghcr.io/wallettransactions/…` успешен (после 3.2; до этого проверяется `docker login` без ошибок).
- [x] 1.3 Включить в LM Studio «Serve on Local Network» и проверить доступ из контейнера: `docker run --rm --add-host host.docker.internal:host-gateway busybox:1.36 wget -qO- http://host.docker.internal:1234/v1/models`. Проверка: в ответе список моделей.

## 2. compose.yaml и скрипты контуров (wallet-infra)

- [x] 2.1 Переписать `compose.yaml` под контуры (D2, D8, D10, D11):
  - `name: wallet-${WALLET_ENV:?}`;
  - убрать `build:`, образы `ghcr.io/wallettransactions/<сервис>:${<СЕРВИС>_TAG:?}`;
  - на хост только гейтвей `${WALLET_GATEWAY_PORT:?}:8090`, остальные `ports:` убрать;
  - `env_file` и PEM из `${WALLET_SECRETS_DIR}`;
  - сеть `wallet-${WALLET_ENV}` external, alias `<сервис>-${WALLET_ENV}`;
  - `mem_limit` и `oom_score_adj: ${WALLET_OOM_ADJ}`;
  - `LLM_URL` wallet-ai из настроек контура;
  - шапку файла переписать под новую схему запуска.

  Проверка: `docker compose config` с настройками prod и test проходит, без настроек падает на незаданной переменной, ни у одного сервиса нет `build`.
- [x] 2.2 Создать `infra/env/prod.env` и `infra/env/test.env` (без секретов): `WALLET_ENV`, порт гейтвея 8090/8091, `WALLET_OOM_ADJ` −900/500, `LLM_URL` (test — пусто). Проверка: `diff` двух файлов показывает только эти различия.
- [x] 2.3 Написать `infra/env/up.sh <env>`:
  - проверяет каталоги `WALLET_SECRETS_DIR`/state и права 700/600;
  - создаёт сеть контура, если её нет;
  - `docker compose` с тремя `--env-file` (настройки контура, `tags.env`, `db.env`) и `up -d --wait`;
  - не печатает значений секретов: без `set -x`, без `cat`.

  Проверка: `bash -n`; запуск без `tags.env` падает с понятной ошибкой.
- [x] 2.4 Написать `infra/env/migrate.sh <env> <база> <образ>` по D4: образ сервиса копирует `/migrations` во временный docker-том, затем `migrate/migrate:v4.18.3 up` в сети контура ролью мигратора; после базы wallet — пароль `wallet_reader` из `READER_POSTGRES_PASSWORD`. Удалить `infra/db/migrate.sh`. Проверка: `bash -n`; на test после 5.3 повторный запуск — no change, wallet-report подключается с паролем из `db.env`, а со строкой `wallet_reader` — нет.
- [x] 2.5 Добавить в `infra/db/init-db.sh` роль `dumper` с `pg_read_all_data` (D9). Задокументировать роль и правило expand/contract для миграций в `infra/db/README.md`. Проверка: на чистом томе test `\du` показывает `dumper`, а `pg_dump` ею проходит по всем четырём базам.
- [x] 2.6 Удалить `infra/k8s/` целиком. Проверка: в репозитории нет ссылок на `infra/k8s`, `apply.sh`, `wallet-transaction` (`git grep`).
- [x] 2.7 Написать `infra/env/README.md`: контуры, порты, раскладка секретов и состояния, `up.sh`, доступ к db через `docker exec`. Проверка: по README test поднимается с нуля без других источников.

## 3. CI: образы в ghcr (репозитории сервисов)

- [x] 3.1 Добавить `COPY migrations /migrations` в Containerfile google-auth, wallet-api, wallet-telegram и wallet-ai. Проверка: `docker run --rm --entrypoint ls <образ> /migrations` показывает `*.up.sql`. Собирать по одному сервису.
- [x] 3.2 Добавить в каждый из 7 сервисов `.github/workflows/release.yml` (тег `v*`; юнит-тесты — из `ci.yml` через `workflow_call`). У wallet-web завести `VERSION` и `GET /version` (как у C++-сервисов). Для тега `v*-rc.*`:
  - проверка `VERSION == X.Y.Z`;
  - сборка с `GIT_COMMIT`;
  - push `ghcr.io/wallettransactions/<сервис>:X.Y.Z-rc.N`;
  - `permissions: packages: write`.

  Проверка: тег `v<VERSION>-rc.1` в google-auth публикует образ, его `/version` отдаёт версию и хэш.
- [x] 3.3 Добавить job на тег `vX.Y.Z`: найти старший `vX.Y.Z-rc.*` на том же коммите и скопировать манифест под финальным тегом (`skopeo copy --preserve-digests`) без сборки; если rc нет, завершиться ошибкой. Проверка: digest `:X.Y.Z` равен digest rc. Тег на коммит без rc роняет workflow.
- [x] 3.4 Добавить чистку старых версий пакета (оставлять 10). Проверить квоту Packages в Billing. Проверка: workflow чистки отрабатывает вручную через `workflow_dispatch`.
  Итог 2026-10-26: `packages-cleanup.yml` во всех 7 сервисах (финальные X.Y.Z не удаляются, из rc — 10 новых; понедельник 04:17 UTC и вручную); `workflow_dispatch` в google-auth и плановые прогоны всех 7 — success. Billing (план free, usage API): начислений за Packages нет.
- [x] 3.5 Описать схему тегов (rc уходит в test, финальный тег — в prod, VERSION должен совпадать) в README google-auth, раздел «Версия», со ссылками из остальных. Проверка: в README всех 7 сервисов есть ссылка на этот раздел.

## 4. Выкат (wallet-infra + BuildPlatform)

- [x] 4.1 Написать `infra/env/deploy.sh <env> <сервис> <тег> [--rollback]` по D5 и D6 (`--rollback` — без миграций и без гейта):
  - flock `<state>/<env>.lock` (не `/tmp`: у контейнера Jenkins свой `/tmp`);
  - pull и digest;
  - гейт digest и дамп для prod;
  - миграции;
  - `tags.env`, `up -d --no-deps --wait`;
  - smoke `/healthz` и `/version`;
  - возврат прежнего тега при ошибке;
  - запись в `verified` и `history`;
  - чистка образов сервиса старше 3 версий.

  Проверка: выкат rc в test проходит. Выкат в prod непроверенного digest падает с «digest не проверен в test». Битый тег (контейнер не healthy) возвращается на прежний.
- [x] 4.2 Добавить в `deploy.sh` ветку `wallet-infra`: checkout тега в `<state>/<env>/infra`, `up.sh`, smoke, при ошибке — прежний тег. Проверка: выкат тега wallet-infra не меняет версий сервисов (`docker compose ps --format` до и после).
- [x] 4.3 Написать `infra/env/backup.sh prod`: дамп четырёх баз prod в `${WALLET_BACKUP_DIR}`, ротация (3 последних с выкатов плюс 7 суточных). Проверка: после двух ручных запусков в каталоге лежат файлы, `pg_restore -l` их читает.
- [x] 4.4 Смонтировать в Jenkins `~/.config/wallet-secrets`, `~/.local/state/wallet-envs`, `${WALLET_BACKUP_DIR}` и `~/.docker/config.json` по тем же абсолютным путям (D7). Проверка: из контейнера Jenkins `docker compose config` контура test проходит.
- [ ] 4.5 Создать job'ы `env-deploy`, `env-rollback` (параметры ENV, SERVICE, TAG) и `prod-backup` (ежесуточно) — тонкие обёртки над скриптами из `<state>/<env>/infra`. Проверка: ручной откат `wallet-api` в test на предыдущий rc без запуска миграций.
- [ ] 4.6 Создать job `env-release-watch` (cron `H/5`): теги ghcr и `git ls-remote` wallet-infra против `tags.env`, запуск `env-deploy`. Проверка: новый rc-тег сервиса через ≤10 минут работает в test, а prod не тронут.
- [ ] 4.7 Удалить job'ы `deploy-*` (кроме `deploy-logging`, `deploy-monitoring`), `deploy-all`, `deploy-servers`, `db-migrate` и `lib/deploy_services.sh`, `lib/migrate_all.sh`. Перенацелить `wallet-api-loadtest` и `wallet-report-loadtest` на сеть `wallet-test`. Проверка: loadtest проходит против test, в prod нет запросов от него (логи гейтвея prod).
- [ ] 4.8 Проверить логи всех env-job'ов на секреты: grep значений из `wallet-secrets` по `$JENKINS_HOME/jobs/{env-*,prod-backup}/builds/*/log`. Проверка: совпадений нет.
- [ ] 4.9 Описать job'ы в `BuildPlatform/jenkins/README.md`. Проверка: README описывает новые job'ы, их параметры и отсутствие старых.

## 5. Контур test

- [x] 5.1 Зарегистрировать test-бота в BotFather. Собрать `~/.config/wallet-secrets/test/` с новыми значениями (D7): пароли БД (включая `READER_POSTGRES_PASSWORD`), RSA-ключ, токен бота, `TELEGRAM_SERVICE_SECRET` (одинаковый в `google-auth.env` и `wallet-telegram.env`), `REDIRECT_URL` на `:8091`. Каталог 700, файлы 600. Проверка: `stat` показывает права, и ни одно значение не совпадает с текущими `.env` (сравнение хэшей).
- [x] 5.2 Добавить redirect URI `http://localhost:8091/auth/google/callback` в OAuth-клиент Google Cloud Console. Проверка: в Console у клиента два URI.
- [x] 5.3 Поднять test: `tags.env` с rc всех сервисов из 3.2, миграции четырёх баз, `up.sh test`. Проверка:
  - все сервисы `wallet-test` healthy;
  - `curl :8091/healthz` — 200;
  - `/api/ai/status` — `enabled` соответствует `LLM_URL` в `infra/env/test.env` (сейчас ИИ включён явно, design D8).
- [x] 5.4 Ручной сценарий в test:
  - вход через Google на `:8091`;
  - создание кошелька;
  - привязка test-бота и команда ему.

  Проверка: всё проходит, у бота нет 409, кошелёк виден в test.
- [x] 5.5 Проверить изоляцию: контейнер `wallet-test` не резолвит и не достаёт db prod, токен test в `:8090` получает 401, Postgres слушает только `127.0.0.1` (prod 15555, test 15432), redis на хосте не слушается (`ss -ltn`), `oom_score_adj` prod ниже test. Выполняется после 7.2, когда prod переключён.

## 6. Перезаливка test из prod

- [ ] 6.1 Написать `infra/env/test-refresh.sh` по D9:
  - блокировка test;
  - остановка сервисов test, кроме db и redis;
  - дамп prod ролью `dumper`;
  - `pg_restore --clean`;
  - миграции test;
  - `TRUNCATE telegram_links`, `tg_link`, `tg_update_offset`;
  - `FLUSHALL`;
  - `up.sh test`.

  Проверка: после запуска число кошельков в test равно prod, три таблицы пусты, старая cookie test получает 401.
- [ ] 6.2 Создать job `env-test-refresh` (ручной запуск), использует ту же блокировку контура, что и `deploy.sh`. Проверка: rc-тег, появившийся во время перезаливки, выкатывается в test только после её окончания (по времени в логах).
- [x] 6.3 Описать сид и перезаливку в `infra/env/README.md`. Проверка: в README есть раздел с командой и списком того, что вычищается.

## 7. Переключение prod

- [x] 7.1 Собрать `~/.config/wallet-secrets/prod/` с новыми значениями (D7): пароли БД (включая `READER_POSTGRES_PASSWORD`), RSA-ключ, `TELEGRAM_SERVICE_SECRET`; токен @WalletTransaction_bot и Google OAuth — прежние; `REDIRECT_URL` на `:8090`. Каталог 700, `*.env` 600, ключ 644. Проверка: `stat` показывает права, ни один пароль и ключ не совпадает с test.
- [x] 7.2 Подготовить финальные теги `vX.Y.Z` всех сервисов на коммитах rc, прошедших 5.3 и 5.4. Проверка: digest каждого финального образа есть в `test/verified`.
- [x] 7.3 Поднять prod по Migration Plan, шаг 4 (старый стек `servers` уже снесён):
  1. `tags.env` prod с финальными тегами;
  2. `up.sh prod` — миграции четырёх баз на пустых томах, затем сервисы;
  3. smoke.

  Проверка: `curl :8090/healthz` — 200, `/version` каждого сервиса показывает финальную версию.
- [ ] 7.4 Проверить prod вживую:
  - вход в веб на `:8090`, создание кошелька;
  - выход и вход на Android (Pixel), синк с новым кошельком;
  - привязка @WalletTransaction_bot заново и команда ему;
  - `/api/ai/status` — `enabled=true`.

  При провале — Migration Plan, шаг 5 (отката на `servers` нет).
- [x] 7.5 Обновить корневой `README.md`: два контура, порты, ссылка на `infra/env/README.md`, нет локального `up --build`. Проверка: раздел «Запуск» описывает оба контура и не упоминает `servers` и `infra/db/.env` как способ запуска.

## 8. Наблюдаемость

- [x] 8.1 Fluent Bit: белый список префиксов `wallet-prod-` и `wallet-test-` вместо `servers-`, поле `env` из префикса (D11). Проверка: в OpenSearch поиск `env:test` находит только записи `wallet-test`.
- [x] 8.2 Prometheus: сети `wallet-prod` и `wallet-test` как external вместо `wallet-net`, scrape по alias'ам `<сервис>-<env>` с меткой `env`. Проверка: `up{job="wallet-api"}` возвращает две серии с `env="prod"` и `env="test"`.
- [x] 8.3 Экспортёры postgres и redis — по одному на контур, с меткой `env`. Проверка: в Prometheus цели экспортёров обоих контуров up.
- [x] 8.4 Дашборды Grafana: переменная `env` во всех панелях. Проверка: при `env=test` панели показывают только test.
- [x] 8.5 Проверить, что стек метрик не связывает контуры: из контейнера `wallet-test` нет доступа к сервисам `wallet-prod` при запущенном Prometheus. Проверка: соединение не устанавливается.

## 9. Сквозная проверка

- [ ] 9.1 Полный цикл на одном сервисе (например, wallet-report):
  1. правка, затем тег `vX.Y.Z-rc.1` — через ≤10 минут работает в test, smoke зелёный;
  2. тег `vX.Y.Z` — через ≤10 минут работает в prod с тем же digest;
  3. ручной откат prod на предыдущую версию.

  Проверка: Jenkins показывает все три прогона зелёными, `/version` на `:8090` меняется ожидаемо.
- [ ] 9.2 Цикл с миграцией (wallet-api, expand-миграция): rc с миграцией в test, затем финальный тег в prod. Проверка: перед миграцией в `${WALLET_BACKUP_DIR}/prod/wallet/` появился дамп с тегом, `schema_migrations` prod показывает новую версию.

## Workflow follow-up

- Старый стек `servers` снесён 2026-10-24 (Migration Plan, шаг 3); сеть `wallet-net` убрать после раздела 8.
- Архивировать change после ревью: `/opsx:archive add-prod-test-environments`.
