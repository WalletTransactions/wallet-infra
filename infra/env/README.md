# env — контуры prod и test

Два постоянных контура стека на одной машине, оба — compose-проекты docker
по одному `compose.yaml` в корне репозитория. Почему так, а не k8s и не
dev-стек рядом — `openspec/changes/add-prod-test-environments/design.md`.

| | prod | test |
| --- | --- | --- |
| Проект compose | `wallet-prod` | `wallet-test` |
| Гейтвей на хосте | `:8090` | `:8091` |
| Postgres (только `127.0.0.1`) | `:15555` | `:15432` |
| Сеть docker | `wallet-prod` | `wallet-test` |
| Тома | `wallet-prod_db-data`, `wallet-prod_redis-data` | `wallet-test_db-data`, `wallet-test_redis-data` |
| Какой git-тег катится | `vX.Y.Z` (только digest, прошедший test) | `vX.Y.Z-rc.N` |
| Telegram-бот | @WalletTransaction_bot | свой test-бот |
| ИИ (LM Studio) | включён | включён явно (`infra/env/test.env`) |
| При нехватке памяти хоста | убивается последним (`oom_score_adj` −900) | первым (500) |

Postgres — только на `127.0.0.1`, из LAN не виден (`../db/README.md`,
«Подключение к базе контура»); redis наружу не публикуется — `docker exec`. Контейнеры разных
контуров друг друга не видят — у каждого своя сеть.

## Что откуда берётся

`compose.yaml` один; контур задают три источника переменных, их
подставляет `up.sh` (и все остальные скрипты — через `lib.sh: env_compose`):

| Что | Где | В git |
| --- | --- | --- |
| Настройки контура: имя, порт, `oom_score_adj`, LLM | `infra/env/<env>.env` | да |
| Теги образов сервисов | `~/.local/state/wallet-envs/<env>/tags.env` | нет, пишет только выкат |
| Пароли ролей Postgres | `~/.config/wallet-secrets/<env>/db.env` | нет |
| Секреты и настройки сервисов | `~/.config/wallet-secrets/<env>/<сервис>.env` | нет |
| Ключ подписи JWT google-auth | `~/.config/wallet-secrets/<env>/jwt_signing_key.pem` | нет |

Каталоги переопределяются переменными `WALLET_SECRETS_ROOT` и
`WALLET_STATE_ROOT` (так делает Jenkins: каталоги смонтированы в его
контейнер по тем же абсолютным путям, что на хосте, а `$HOME` другой).

Без этих источников `docker compose` в корне репозитория падает на первой
незаданной переменной — так и задумано.

## Скрипты

| Скрипт | Что делает |
| --- | --- |
| `up.sh <env>` | Сеть → db, redis → миграции всех баз → остальные сервисы, ждёт healthy. Повторный запуск безопасен |
| `deploy.sh <env> <сервис> <тег> [--rollback]` | Выкат одной версии: гейт, дамп, миграции, сервис, smoke, автооткат — см. «Выкат и откат» |
| `migrate.sh <env> <база> [образ] [команда]` | Миграции одной базы из образа сервиса (`/migrations`), по умолчанию `up` — см. `../db/README.md`, «Миграции» |
| `backup.sh <env> [--label <метка>] [<база>...]` | Дамп баз ролью `dumper` в `${WALLET_BACKUP_DIR}`, с ротацией — см. «Дампы» |
| `release-watch.sh` | Что пора выкатить: новые теги в ghcr и git-теги wallet-infra против контуров; печатает `<env> <сервис> <тег>`, сам не выкатывает — см. «Выкат и откат» |
| `test-refresh.sh` | Перезаливка данных test из prod с вычисткой — см. «Данные test» |
| `loadtest_env.sh` | Контур нагрузочных прогонов (только test): подключают скрипты `wallet-api/loadtest` и `wallet-report/loadtest` — см. «Нагрузочные прогоны» |
| `lib.sh` | Общие функции, подключается через `source` |

`compose.yaml` контура скрипты берут из выкатанного тега wallet-infra —
checkout'а `~/.local/state/wallet-envs/<env>/infra` (его ведёт
`deploy.sh <env> wallet-infra <тег>`), а не из рабочей папки. Пока
checkout'а нет — из репозитория, где лежит запущенный скрипт.

Все скрипты берут блокировку контура
(`~/.local/state/wallet-envs/<env>.lock`): выкаты, миграции и перезаливка в
одном контуре идут строго по одному, второй запуск ждёт первый — и ручной на
хосте, и job Jenkins (каталог состояния смонтирован в Jenkins, `/tmp` у него
свой). Значения секретов скрипты не печатают.

## Первый запуск контура

На примере test; для prod — то же самое с `prod` и значениями prod.

**1. Хост (один раз):** `docker login ghcr.io` токеном GitHub с правом
`read:packages` — образы в ghcr приватные.

**2. Секреты.** Каталог 700, `*.env` 600, ключ `jwt_signing_key.pem` 644 —
его читает google-auth в контейнере под своим uid, а посторонних не пускает
каталог 700 (`up.sh` проверяет права и не
стартует с другими):

```bash
S=~/.config/wallet-secrets/test
install -m 700 -d "$S"
install -m 600 infra/db/.env.example "$S/db.env"        # + заменить все change-me-*
for s in google-auth wallet-api wallet-report wallet-ai wallet-gateway wallet-telegram; do
    install -m 600 "../$s/.env.example" "$S/$s.env"
done
openssl genrsa -out "$S/jwt_signing_key.pem" 2048 && chmod 644 "$S/jwt_signing_key.pem"
```

Что вписать руками:

- `db.env` — свои пароли каждой роли (`openssl rand -hex 24`). У prod и
  test они разные.
- `google-auth.env` — `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET` (клиент
  общий на оба контура), `REDIRECT_URL=http://localhost:<порт
  контура>/auth/google/callback` (этот URI должен быть в списке клиента в
  Google Cloud Console), `ADMIN_EMAILS`, `TELEGRAM_SERVICE_SECRET`,
  `TELEGRAM_BOT_USERNAME` (имя бота контура без `@`, как в
  `wallet-telegram.env`; без него «Подключить Telegram» в вебе получает 503),
  `JWT_RSA_PRIVATE_KEY_PATH=/app/jwt_signing_key.pem`.
- `wallet-telegram.env` — токен и имя бота контура (в test — отдельный бот
  из BotFather, НЕ @WalletTransaction_bot: два процесса на одном токене
  получают 409), тот же `TELEGRAM_SERVICE_SECRET`, что в `google-auth.env`.
- `wallet-ai.env` — `LLM_API_KEY`, если нужен; `LLM_URL`/`LLM_MODEL` задаёт
  `infra/env/<env>.env`.

Адреса других сервисов, `DATABASE_URL`, `HOST`/`PORT` из `.env.example`
можно не трогать: `compose.yaml` переопределяет их адресами сети контура.

**3. Теги образов.** Обычно `tags.env` пишет выкат; на пустом контуре —
руками, по опубликованным в ghcr тегам:

```bash
mkdir -p ~/.local/state/wallet-envs/test
cat > ~/.local/state/wallet-envs/test/tags.env <<'EOF'
GOOGLE_AUTH_TAG=1.0.0-rc.1
WALLET_API_TAG=1.0.0-rc.1
WALLET_REPORT_TAG=1.0.0-rc.1
WALLET_AI_TAG=1.0.0-rc.1
WALLET_GATEWAY_TAG=1.0.0-rc.1
WALLET_WEB_TAG=1.0.0-rc.1
WALLET_TELEGRAM_TAG=1.0.0-rc.1
EOF
```

**4. Запуск:**

```bash
bash infra/env/up.sh test
curl -s http://localhost:8091/healthz
```

Пустой контур получает только схему (миграции); администратор появляется
при первом входе по `ADMIN_EMAILS`. Демо-данных нет.

## Выкат и откат

Обычно выкатывает Jenkins: `env-release-watch` раз в 5 минут запускает
`release-watch.sh` и по каждой его строке — `env-deploy`
(`BuildPlatform/jenkins/README.md`, «env-* — контуры»). Правило
`release-watch.sh`:

- старший `X.Y.Z-rc.N` в ghcr → test, если он новее выкатанного;
- старший `X.Y.Z` → prod, если новее выкатанного и его digest уже в
  `test/verified` (непроверенный не предлагается — иначе job падал бы на
  гейте каждые 5 минут);
- тег, выкат которого в этот контур уже падал (`failed` в `history`), не
  повторяется — его заменит следующий;
- git-теги wallet-infra — так же, гейт prod по коммиту.

Репозиторий wallet-infra приватный, а у Jenkins нет git-учётки хоста.
Теги wallet-infra он читает fine-grained токеном GitHub (Repository access:
только `wallet-infra`; Permissions: Contents — Read-only) из
`~/.config/wallet-secrets/github-read.token` (файл 600; каталог уже
смонтирован в Jenkins). Нет файла — `release-watch.sh` предупреждает и
пропускает только wallet-infra, сервисы выкатываются как обычно; на хосте git
тогда идёт со своей учёткой.

```bash
install -m 600 /dev/null ~/.config/wallet-secrets/github-read.token
$EDITOR ~/.config/wallet-secrets/github-read.token   # вставить токен
```

Посмотреть, что выкатится на следующем прогоне, ничего не трогая:
`bash infra/env/release-watch.sh`.

Руками — тот же скрипт, что у `env-deploy`:

```bash
bash infra/env/deploy.sh test wallet-api 1.4.0-rc.1
bash infra/env/deploy.sh prod wallet-api 1.4.0
bash infra/env/deploy.sh prod wallet-api 1.3.2 --rollback   # ручной откат
bash infra/env/deploy.sh test wallet-infra v0.3.0-rc.1      # описание контура
```

Что делает `deploy.sh` для сервиса, по порядку:

1. ждёт блокировку контура;
2. `docker pull`, берёт digest образа;
3. **prod:** digest должен быть в `test/verified` — то есть этот же образ
   прошёл smoke в test. Иначе «digest не проверен в test», prod не трогается;
4. у сервиса есть база (google-auth, wallet-api, wallet-telegram, wallet-ai):
   в prod — дамп этой базы (`backup.sh`), затем миграции из нового образа.
   Не снялся дамп или упала миграция — сервис остаётся на прежнем образе;
5. новый тег в `tags.env`, пересоздаётся только этот сервис, ждёт healthy;
6. smoke изнутри гейтвея: `/healthz` гейтвея, `/version` сервиса отдаёт
   версию тега (и коммит, которым CI пометил образ);
7. не прошло — прежний тег обратно, job падает. Прошло — digest в
   `verified`, строка в `history`, на хосте остаются 3 последних образа сервиса.

В prod катится только финальный тег `X.Y.Z`. `--rollback` пропускает
миграции и гейт: схема при откате не откатывается (expand/contract,
`../db/README.md`). На какие теги можно откатиться — `history` контура.

`wallet-infra` выкатывается так же по git-тегу (`vX.Y.Z-rc.N` → test,
`vX.Y.Z` → prod, гейт — по коммиту тега): checkout тега, `up.sh` из него,
smoke гейтвея; не прошло — прежний тег и `up.sh` ещё раз. Версии сервисов
при этом не меняются — они в `tags.env`, а не в git.

Состояние контура (`~/.local/state/wallet-envs/<env>/`):

| Файл | Что |
| --- | --- |
| `tags.env` | теги образов, на которых работает контур |
| `verified` | digest'ы образов (и `git:<коммит>` wallet-infra), прошедшие smoke в этом контуре |
| `history` | время, сервис, тег, digest, итог — каждый выкат и откат |
| `infra/` | checkout выкатанного тега wallet-infra |

## Дампы

`backup.sh` снимает `pg_dump -Fc` ролью `dumper` (только чтение) в
`${WALLET_BACKUP_DIR}/<env>/<база>/<время>_<метка>.dump` и проверяет, что
файл читается `pg_restore -l`. `WALLET_BACKUP_DIR` обязателен и должен быть
на другом физическом диске, чем тома docker (здесь — DATA): дамп рядом с
базой не спасёт при отказе диска.

- перед миграцией в prod — дамп затрагиваемой базы с меткой
  `<сервис>-<тег>` (из `deploy.sh`), хранятся 3 последних на базу;
- ежесуточно (Jenkins, `prod-backup`) — все четыре базы с меткой `daily`,
  хранятся 7 последних.

Восстановить базу из дампа (контур должен быть остановлен, кроме db):

```bash
docker exec -i wallet-prod-db-1 sh -c \
    'pg_restore -U "$POSTGRES_USER" -d wallet_api --clean --if-exists' \
    < "$WALLET_BACKUP_DIR/prod/wallet/<файл>.dump"
```

## Данные test

**Сид.** Новый контур (prod и test одинаково) получает только схемы — миграции
четырёх баз из `up.sh`. Роли заводит `init-db.sh` и миграция `auth/000001`,
администратор появляется при первом входе по `ADMIN_EMAILS` контура.
Демо-данных нет; понадобятся — отдельный SQL в `../db/seed/`.

**Перезаливка из prod** — job `env-test-refresh` (с отметкой `CONFIRM`) или руками:

```bash
bash infra/env/test-refresh.sh
```

Под блокировкой test (выкат rc в test ждёт окончания):

1. останавливает все сервисы test, кроме db и redis;
2. базы auth, wallet, telegram, ai test удаляет (`DROP ... WITH (FORCE)`) и
   создаёт заново `init-db.sh`;
3. снимает `pg_dump -Fc` каждой базы prod ролью `dumper` (только чтение) и
   потоком отдаёт в `pg_restore` test — файла на диске не остаётся;
4. накатывает миграции test (из образов, выкатанных в test) поверх схемы prod;
5. вычищает то, что принадлежит prod:
   - `telegram_links` (база auth) — привязки Telegram к пользователям;
   - `tg_link`, `tg_update_offset` (база telegram) — привязки и offset
     getUpdates prod-бота;
   - Redis test целиком (`FLUSHALL`) — все сессии и refresh-токены;
6. поднимает контур: `up.sh test`.

Вход в test после этого — заново. Старый refresh-токен и `/auth/me` сразу
получают 401. Access-JWT (cookie `session`) гейтвей проверяет по подписи без
Redis, поэтому он доживает свой TTL (15 минут), если ключ подписи test тот же.
Упало посреди — сервисы test остаются остановленными; повторный запуск
начинает с начала.

В test при этом лежат персональные финансовые данные prod — допустимо, пока
test LAN-only и только у владельца (design D9).

## Нагрузочные прогоны

Нагрузка, сид данных и минтинг токенов (`wallet-api/loadtest`,
`wallet-report/loadtest`, job'ы `test-*-loadtest`) идут только в test. Их
скрипты подключают `loadtest_env.sh`, который:

- отказывает для любого контура, кроме test (`LOADTEST_ENV=prod` — ошибка);
- даёт сеть `wallet-test`, контейнер db test и ключ подписи
  `~/.config/wallet-secrets/test/jwt_signing_key.pem` (токены принимает
  гейтвей test, prod — нет);
- подгружает `db.env` test (`PERF_POSTGRES_*` — база `perf_history` есть только в test);
- `loadtest_container_id <сервис>` — id контейнера для фильтра cAdvisor
  (`name=`): по `image` prod и test на одном теге не различить;
- `loadtest_override <сервис> <ПЕРЕМЕННАЯ> <значение>` и
  `loadtest_restore <сервис>` — пересоздать сервис test с другим окружением
  (например, `DATABASE_POOL_SIZE`) под блокировкой контура и вернуть обратно.

```bash
bash -c 'source infra/env/loadtest_env.sh && loadtest_override wallet-report REPORTS_DB_POOL_SIZE 4'
bash -c 'source infra/env/loadtest_env.sh && loadtest_restore wallet-report'
```

## Контур руками

```bash
# compose контура с теми же переменными, что у скриптов:
bash -c 'source infra/env/lib.sh; env_init test; env_compose ps'
bash -c 'source infra/env/lib.sh; env_init test; env_compose logs -f wallet-api'

docker exec -it wallet-test-db-1 sh -c 'psql -U "$POSTGRES_USER" -d wallet_api'
docker exec -it wallet-test-redis-1 redis-cli
```

Остановить контур, не теряя данных: `env_compose stop`. `env_compose down -v`
удаляет тома — в prod так не делать.
