# env — контуры prod и test

Два постоянных контура стека на одной машине, оба — compose-проекты docker
по одному `compose.yaml` в корне репозитория. Почему так, а не k8s и не
dev-стек рядом — `openspec/changes/add-prod-test-environments/design.md`.

| | prod | test |
| --- | --- | --- |
| Проект compose | `wallet-prod` | `wallet-test` |
| Гейтвей на хосте | `:8090` | `:8091` |
| Сеть docker | `wallet-prod` | `wallet-test` |
| Тома | `wallet-prod_db-data`, `wallet-prod_redis-data` | `wallet-test_db-data`, `wallet-test_redis-data` |
| Какой git-тег катится | `vX.Y.Z` (только digest, прошедший test) | `vX.Y.Z-rc.N` |
| Telegram-бот | @WalletTransaction_bot | свой test-бот |
| ИИ (LM Studio) | включён | выключен (`LLM_URL=` пусто) |
| При нехватке памяти хоста | убивается последним (`oom_score_adj` −900) | первым (500) |

Больше ничего наружу не публикуется: к db и redis — `docker exec`
(`../db/README.md`, «Подключение к базе контура»). Контейнеры разных
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
| `lib.sh` | Общие функции, подключается через `source` |

`compose.yaml` контура скрипты берут из выкатанного тега wallet-infra —
checkout'а `~/.local/state/wallet-envs/<env>/infra` (его ведёт
`deploy.sh <env> wallet-infra <тег>`), а не из рабочей папки. Пока
checkout'а нет — из репозитория, где лежит запущенный скрипт.

Все скрипты берут блокировку контура (`/tmp/wallet-env-<env>.lock`):
выкаты, миграции и перезаливка в одном контуре идут строго по одному, второй
запуск ждёт первый. Значения секретов скрипты не печатают.

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

Обычно выкатывает Jenkins: `env-release-watch` раз в 5 минут сверяет теги
в ghcr с `tags.env` контуров и запускает `env-deploy`. Руками — тот же скрипт:

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
