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
| Пароль admin Grafana (общий на оба контура, `infra/monitoring/up.sh`) | `~/.config/wallet-secrets/monitoring.env` | нет |

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
| `docs-index.sh <env> <репозиторий\|all> [--strict]` | Заливка OpenSpec-спек в индекс wallet-docs — см. «Необязательный модуль wallet-docs» |
| `loadtest_env.sh` | Контур нагрузочных прогонов (только test): подключают скрипты `wallet-api/loadtest` и `wallet-report/loadtest` — см. «Нагрузочные прогоны» |
| `export-ca.sh <env> [файл]` | Публичный корень CA TLS-прокси контура для установки на устройства — см. «Необязательный TLS на входе» |
| `lib.sh` | Общие функции, подключается через `source` |
| `tls.sh` | TLS-производные для compose (профиль, порт гейтвея, `generated/`), подключается из `lib.sh` |

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
стартует с другими). Значения `*_USER`, `*_PASSWORD`, `*_DB` в `db.env` —
только `[A-Za-z0-9._~-]`: из них собираются URL подключения, и все скрипты
контура проверяют это до любых действий (кириллическая буква в пароле
мигратора 2026-11-13 уронила prod после `down`). Генерировать —
`openssl rand -hex 24`:

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
  `JWT_RSA_PRIVATE_KEY_PATH=/app/jwt_signing_key.pem`. Вход по паролю
  (необязателен, change `add-password-auth`) настраивается там же, полный список — в
  `google-auth/.env.example`:

  ```bash
  # какие способы входа включены: password | google | both (по умолчанию both)
  AUTH_METHODS=both
  # самостоятельная регистрация: open | closed (по умолчанию open; на prod — closed)
  REGISTRATION=closed
  # принимать пароль и по HTTP: только пока в контуре нет TLS (по умолчанию выключено)
  ALLOW_INSECURE_AUTH=true
  # лимиты попыток входа (по умолчанию 5 на email и 30 на IP за 900 с)
  # AUTH_FAIL_MAX_PER_EMAIL=5
  # AUTH_FAIL_MAX_PER_IP=30
  # AUTH_FAIL_WINDOW_SECS=900
  ```

  Без `ALLOW_INSECURE_AUTH` пароль принимается только с `X-Forwarded-Proto: https`
  (его ставит `wallet-gateway`, а `https` туда придёт от TLS-прокси — change
  `add-tls-ingress`); без TLS вход по паролю вернёт `403 insecure_transport`. Пустой
  `AUTH_METHODS=google` отключает ручки пароля без отката кода. После правки файла
  нужно пересоздать контейнер: `bash infra/env/up.sh <env>`.
- `wallet-gateway.env` — `TRUST_FORWARDED_HEADERS` здесь задавать не нужно:
  compose выставляет его из `WALLET_TLS` (`true` только вместе с TLS-прокси и
  закрытым портом гейтвея), а строка в секрете перекрывается. То же для
  `COOKIE_SECURE` в `google-auth.env`. См. «Необязательный TLS на входе».
- `wallet-telegram.env` — токен и имя бота контура (в test — отдельный бот
  из BotFather, НЕ @WalletTransaction_bot: два процесса на одном токене
  получают 409), тот же `TELEGRAM_SERVICE_SECRET`, что в `google-auth.env`.
- `wallet-ai.env` — `LLM_API_KEY`, если нужен; `LLM_URL`/`LLM_MODEL` и
  `AI_STREAM_ENABLED` (поток событий chat, по умолчанию выключен) задаёт
  `infra/env/<env>.env`. `AI_STREAM_ENABLED` в самом `wallet-ai.env` не
  действует: `environment` в compose сильнее `env_file`. Остальные параметры
  потока (`AI_STREAM_MAX`, `AI_STREAM_MAX_PER_USER`, `AI_STREAM_PING_SECS`,
  у гейтвея `GATEWAY_STREAMS_MAX`) имеют рабочие умолчания и в compose не
  выведены.

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
WALLET_MCP_TAG=0.1.0-rc.1
EOF
```

У wallet-mcp `.env` необязателен (`required: false` в `compose.yaml`),
адреса соседей задаёт `compose.yaml`. Единственный его секрет —
`AUTH_EXCHANGE_SECRET` (приём JWT для wallet-mcp, change `add-jwt-access`
wallet-mcp). Обмен токена (RFC 8693) включается тремя файлами одного
контура, секреты у prod и test разные (`openssl rand -hex 32`):

| Файл | Строка |
| --- | --- |
| `google-auth.env` | `TOKEN_EXCHANGE_SECRETS=wallet-ai=<A>,wallet-mcp=<M>` |
| `wallet-mcp.env` (600) | `AUTH_EXCHANGE_SECRET=<M>` |
| `wallet-ai.env` | `AUTH_EXCHANGE_SECRET=<A>` |

Без них обмен выключен: google-auth отвечает на `/internal/token/exchange`
`503`, wallet-mcp принимает только `wmcp_…`. Откат — убрать строки и
`up.sh <env>`: сервисы пересоздаются с новым окружением.

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
   версию тега (и коммит, которым CI пометил образ). У wallet-mcp сверх
   этого — `POST /api/mcp/` без токена изнутри его контейнера должен
   получить `401`: образ, который отвечает анонимному клиенту иначе, не
   выкатывается (`smoke: wallet-mcp без токена ответил <код>, ожидался 401`);
7. не прошло — прежний тег обратно, job падает. Прошло — digest в
   `verified`, строка в `history`, на хосте остаются 3 последних образа сервиса.

В prod катится только финальный тег `X.Y.Z`. `--rollback` пропускает
миграции и гейт: схема при откате не откатывается (expand/contract,
`../db/README.md`). На какие теги можно откатиться — `history` контура.

`wallet-infra` выкатывается так же по git-тегу (`vX.Y.Z-rc.N` → test,
`vX.Y.Z` → prod, гейт — по коммиту тега): checkout тега, `up.sh` из него,
smoke гейтвея; не прошло — прежний тег и `up.sh` ещё раз. Версии сервисов
при этом не меняются — они в `tags.env`, а не в git.

### Новый сервис в контуре

Так подключался wallet-mcp (`openspec/changes/add-wallet-mcp-service`):
сервис в `compose.yaml`, порт в `WALLET_SERVICE_PORT` (`lib.sh`), цель в
`infra/monitoring/prometheus.yml`, имя в whitelist
`infra/logging/fluent-bit.conf`, в `SERVICE` у job'ов `env-deploy` и
`env-rollback`. Порядок выката в каждом контуре (сначала test, потом prod):

1. CI сервиса публикует первый образ в ghcr (`vX.Y.Z-rc.1`; для prod —
   финальный `X.Y.Z` после проверки в test).
2. **До** выката тега wallet-infra с новым сервисом — тег в `tags.env`
   контура руками, одной строкой (`WALLET_MCP_TAG=0.1.0-rc.1`). Иначе
   `compose.yaml` с `${WALLET_MCP_TAG:?}` не соберётся, и `up.sh` упадёт
   на всём контуре. Это единственная ручная правка `tags.env` — дальше её
   ведёт `deploy.sh`. `up.sh` гейт prod не проверяет, поэтому в prod
   вписывается только финальный тег, чей rc прошёл test. И вписывается
   сразу: `release-watch.sh` работает из checkout'а test и, пока у prod
   нет строки тега, предлагает `prod <сервис> X.Y.Z`. `deploy.sh` prod из
   старого тега wallet-infra такой сервис не знает и падает каждые 5 минут.
3. Выкат тега wallet-infra (`deploy.sh <env> wallet-infra <тег>` или
   `env-release-watch`): `up.sh` поднимает новый сервис.
4. Следующие теги сервиса катит `env-release-watch` сам.

Откат на тег wallet-infra без сервиса: `up.sh` из прежнего тега убирает
его контейнер (`--remove-orphans`). Если контейнер остался — `docker rm -f
wallet-<env>-wallet-mcp-1`. Строку тега в `tags.env` можно не трогать:
лишняя переменная compose не мешает.

### Необязательный модуль wallet-docs

`wallet-docs` (справка по OpenSpec-спекам, change `wallet-docs-assistant`)
живёт в compose-профиле `docs`. Нет профиля — нет сервиса: `up.sh`,
`deploy.sh` других сервисов, бэкап и гейтвей работают как без него. Модуль
включается **двумя строками вместе** в `infra/env/<env>.env`:

```bash
COMPOSE_PROFILES=docs
WALLET_DOCS_URL=http://wallet-docs:8089
```

`WALLET_DOCS_URL` без профиля не задают: тогда гейтвей отвечает на
`/api/docs/*` `404 gateway: docs не подключён` (клиенты прячут раздел), а не
`502` на несуществующее имя.

Поведение скриптов:

| Скрипт | Профиль выключен | Профиль включён |
| --- | --- | --- |
| `up.sh` | пишет «docs пропущен» | миграции базы docs из образа и сервис — если в `db.env` есть `DOCS_POSTGRES_DB`, а в `tags.env` — `WALLET_DOCS_TAG`; чего-то нет — «docs пропущен», профиль на этот запуск выключается |
| `deploy.sh <env> wallet-docs <тег>` | отказ, контур не меняется | как у остальных; в prod без дампа (индекс не бэкапится) |
| `migrate.sh <env> docs` | без `DOCS_POSTGRES_DB` в `db.env` — ошибка | миграции из образа `wallet-docs` |
| `backup.sh <env> docs` | отказ: индекс не бэкапится | то же |

Включение — сначала test, потом prod:

1. **pgvector.** Образ `db` сменился, том `db-data` пересоздаётся (см.
   `../db/README.md`). test: `backup.sh test --label pre-pgvector`, `down`,
   `docker volume rm wallet-test_db-data`, `up.sh test`, `test-refresh.sh`.
   prod — в согласованное окно: `backup.sh prod --label pre-pgvector`,
   проверка дампов `pg_restore -l`, замена тома, `up.sh prod`, восстановление.
2. **База.** `DOCS_POSTGRES_USER/PASSWORD/DB` в `db.env` контура (права
   600, значения не печатать), `up.sh <env>` (контейнер `db` получит новые
   переменные), затем `migrate.sh <env> docs`: база и расширение
   создаются (`init-db.sh`); пока нет тега `wallet-docs`, скрипт после этого
   сообщает «нет тега» — это ожидаемо.
3. **Сервис.** Первый образ в ghcr; `WALLET_DOCS_TAG=<тег>` в `tags.env`
   руками (как у нового сервиса выше), `wallet-docs.env` (600: `INDEX_TOKEN`,
   `LLM_URL`, `LLM_MODEL`, `EMBED_MODEL`; нет файла — вопросы и заливка
   отвечают 503), две строки в `<env>.env`, тег wallet-infra и его выкат.
4. **Индекс.** `docs-index.sh <env> all` (ниже), затем ночью — job Jenkins
   `docs-index`.

#### Заливка индекса — `docs-index.sh`

```sh
infra/env/docs-index.sh test wallet-gateway     # один репозиторий
infra/env/docs-index.sh test all                # все каталоги с openspec/ рядом с wallet-infra
infra/env/docs-index.sh test all --strict       # любой отказ — ненулевой код
```

- Источник — рабочая папка организации (`WALLET_TRANSACTIONS_PATH`, иначе
  каталог над wallet-infra), не git-клон: `openspec/**/*.md` и файлы
  `README.md` любой глубины (вид `ops`, без `third_party/`, `node_modules/`,
  `.worktrees/`, `build/`, `vendor/`), обычные файлы без симлинков. В индекс
  попадают и незакоммиченные черновики — их видит только админ (вид `change`),
  как и `ops`; пользователям доступны `specs/`. Репозитории без `openspec/`
  (например `org`) пропускаются целиком.
- JSON собирает `jq` (в контейнере Jenkins нет `python3`), запрос
  `PUT /docs/index/<репозиторий>` уходит изнутри контейнера `wallet-docs`
  (`docker exec`): `INDEX_TOKEN` остаётся в его окружении (`wallet-docs.env`)
  и в заголовок попадает через файл — его нет ни в аргументах процессов, ни в
  выводе. `set -x` в скрипт не добавлять.
- Сеть и стек Jenkins не участвуют: `curl` выполняется внутри контейнера
  `wallet-docs`, в его сети. Способ выбирается по его окружению: если задан
  `TLS_CERT` (контур с mTLS) — `https://wallet-docs:8089` с сертификатом самого
  контейнера (`TLS_CERT`, `TLS_KEY`, `TLS_CA`, имя проверяется по SAN), иначе
  `http://127.0.0.1:8089`.
- На репозиторий — одна строка `<репозиторий>: chunks=… embedded=… reused=…
  skipped=… files=… за N с`. Повторная заливка без изменений —
  `reused` = `chunks`, `embedded=0`.
- Мягкий отказ: профиль `docs` выключен, контейнер не запущен, репозитория нет
  на диске, тело больше 16 МБ или ответ не 2xx — строка `docs-index: <причина>`
  и код 0 (при `all` — дальше по списку); с `--strict` — код 1. Job
  `docs-index` по этой строке ставит `UNSTABLE`. Причина названа: «сертификат
  контейнера не читается», «TLS-рукопожатие не прошло (curl N)», «сервис
  недоступен (curl N)», «wallet-docs ответил 401 …» — а не голое `000`.
- Берёт блокировку контура: не идёт параллельно с выкатом и миграцией.

Выключение — убрать обе строки из `<env>.env` и выкатить тег wallet-infra;
если контейнер остался — `docker rm -f wallet-<env>-wallet-docs-1`. Секреты
`DOCS_*` можно не трогать: без профиля они ничего не включают. Возврата на
`postgres:16-alpine` не предусмотрено: образ `db` — `pgvector/pgvector:pg16` во
всех контурах, а выключается только сервис `wallet-docs`.

Состояние контура (`~/.local/state/wallet-envs/<env>/`):

| Файл | Что |
| --- | --- |
| `tags.env` | теги образов, на которых работает контур |
| `verified` | digest'ы образов (и `git:<коммит>` wallet-infra), прошедшие smoke в этом контуре |
| `history` | время, сервис, тег, digest, итог — каждый выкат и откат |
| `infra/` | checkout выкатанного тега wallet-infra |

### Необязательный TLS на входе

Перед гейтвеем контура можно поставить HTTPS-прокси Caddy (сервис
`tls-proxy`, профиль `tls`, change `add-tls-ingress`). Без него контур
работает по HTTP, как раньше. Включается **одной строкой** в
`infra/env/<env>.env` и списком адресов:

```bash
WALLET_TLS=true
WALLET_TLS_MODE=tailscale          # internal (по умолчанию) | files | tailscale
WALLET_TLS_HOST=192.168.1.105,192.168.1.105.nip.io,ivan-pc.tail5afb65.ts.net
# WALLET_TLS_PORT уже задан: prod 8443, test 8444
```

Остальное выводит `tls.sh` при **каждом** вызове compose из скриптов (и
`up.sh`, и `deploy.sh` одного сервиса), поэтому рассогласовать нельзя:

| | Без TLS | `WALLET_TLS=true` |
| --- | --- | --- |
| профиль `tls`, сервис `tls-proxy` | нет | есть, порт `WALLET_TLS_PORT` |
| порт гейтвея (8090/8091) | все интерфейсы | только `127.0.0.1` (скрипты, `curl` с хоста) |
| `COOKIE_SECURE` у google-auth | `false` | `true` |
| `TRUST_FORWARDED_HEADERS` у гейтвея | `false` | `true` |

Эти два значения пишутся в `~/.local/state/wallet-envs/<env>/generated/` и
перекрывают одноимённые строки секретов `google-auth.env`/`wallet-gateway.env`.
Там же лежит сгенерированный `caddy/Caddyfile`. Руками их не правят.

**Какой режим выбрать.** Режим задаётся для каждого контура отдельно.

| Режим | Сертификат | Клиентам нужно | Когда |
| --- | --- | --- | --- |
| `internal` | CA Caddy (том `wallet-<env>_tls-data`), на любой IP или имя | установить корень CA | LAN без домена и без Tailscale |
| `tailscale` | Let's Encrypt на имя узла `*.ts.net` от `tailscaled` хоста; остальные адреса списка — CA Caddy | быть в tailnet (для имени `.ts.net`) | есть Tailscale, домена нет |
| `files` | `~/.config/wallet-secrets/<env>/tls/fullchain.pem` и `privkey.pem` (600) | ничего (при публичном CA) | есть домен и свой ACME-клиент |

**Список адресов.** `WALLET_TLS_HOST` перечисляет через запятую все адреса,
по которым клиенты открывают контур. Сертификат проверяется по адресу из URL,
поэтому адреса не из списка не работают. Ограничения:

- корректный сертификат по IP получает только **первый** IP списка:
  по IP клиент не передаёт имя (SNI), а за docker-NAT прокси не видит, на
  какой адрес хоста пришло соединение. Рекомендуется один IP плюс имена;
- вход через Google по LAN-IP google-auth переписывает в `<IP>.nip.io`, и
  после Google браузер возвращается по этому имени. Поэтому `<IP>.nip.io`
  тоже нужен в списке.

**Google.** URI сверяется буквально, а с TLS у него меняются схема и порт.
Для каждого имени добавьте https-вариант с TLS-портом в `ALLOWED_REDIRECT_URIS`
(`google-auth.env`) **и** в Authorized redirect URIs в Google Cloud Console.
Старые http-варианты оставьте для отката. Для test:

```
https://ivan-pc.tail5afb65.ts.net:8444/auth/google/callback
https://192.168.1.105.nip.io:8444/auth/google/callback
```

**Режим `tailscale`.** Один раз: в админке Tailscale → DNS включить MagicDNS
и **HTTPS Certificates**. В список входит ровно одно имя `.ts.net`, и это имя
этого узла (`tailscale status --json | jq -r .Self.DNSName`): чужое имя
`tailscaled` не выдаст. `up.sh` проверяет имя и включённые сертификаты до
запуска. В контейнере Jenkins сокета не видно, и проверка там пропускается
с предупреждением. Каталог сокета (`/var/run/tailscale`, другой путь
задаёт `WALLET_TAILSCALE_SOCKET`) монтируется в `tls-proxy` только в этом режиме.

> Риск: через сокет процесс Caddy (root в контейнере) получает полный LocalAPI
> tailscaled и может менять настройки Tailscale хоста. Если это неприемлемо,
> берите `files` с сертификатом от `tailscale cert`, перевыпуская его по
> таймеру. Новый сертификат подхватывается следующим `up.sh <env>`: метка
> прокси меняется вместе с файлом, и compose пересоздаёт контейнер.
>
> ```bash
> sudo tailscale cert --cert-file ~/.config/wallet-secrets/test/tls/fullchain.pem \
>   --key-file ~/.config/wallet-secrets/test/tls/privkey.pem ivan-pc.tail5afb65.ts.net
> ```
>
> После этого исправьте владельца (`sudo chown`) и права на ключ (`chmod 600`).

**Корень CA на устройства** (режимы `internal` и `tailscale`, для адресов не `.ts.net`):

```bash
bash infra/env/export-ca.sh test            # → ./wallet-test-root.crt
```

Скрипт берёт только публичный `root.crt` из тома и проверяет, что в файле нет
ключа. Корень у каждого контура свой. Куда ставить:

- Android: «Настройки → Безопасность → Шифрование и учётные данные →
  Установить сертификат → Сертификат ЦС». Приложение доверяет
  пользовательским CA с 1.0.165;
- Linux: `sudo cp wallet-test-root.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates`.
  Chrome на Linux берёт сертификаты из NSS, поэтому ему нужен ещё импорт в
  «Настройки → Конфиденциальность → Сертификаты → Центры сертификации».

**Включение** (сначала test, потом prod):

1. В обоих контурах выкачен wallet-gateway с `TRUST_FORWARDED_HEADERS`.
2. Строки выше в `<env>.env`, тег wallet-infra и его выкат (или `up.sh <env>`).
3. Проверки: `https://<адрес>:8444/healthz` отвечает `200` по каждому адресу
   списка. С другой машины `http://<хост>:8091` не отвечает. После входа
   cookie `session` приходят с `Secure`.
4. Вход по паролю за TLS не требует `ALLOW_INSECURE_AUTH`: после проверки
   задайте `WALLET_ALLOW_INSECURE_AUTH=false`.

Откат: убрать `WALLET_TLS` (или `false`) и снова `up.sh <env>`. Порт гейтвея
опять откроется на все интерфейсы, `COOKIE_SECURE` и доверие к заголовкам
выключатся, а контейнер `tls-proxy` `up.sh` удалит сам. Том с CA остаётся, поэтому при повторном включении корень на устройствах переустанавливать не нужно.

**Способы входа** (`WALLET_AUTH_METHODS`, `WALLET_REGISTRATION`,
`WALLET_ALLOW_INSECURE_AUTH` в `<env>.env`) задавать необязательно. Если
строка задана, она перекрывает такую же настройку в `google-auth.env`. Если
нет, действует значение из секрета или умолчание google-auth.

## Служебная сеть `auth-internal`

`/internal/*` google-auth (выдача токенов по `X-Service-Secret`) вынесен на
отдельный порт `8081` и сеть `auth-internal` (change `add-internal-mtls`, D11).
В сети четыре сервиса: google-auth, wallet-telegram, wallet-mcp, wallet-ai.
Сеть создаёт сам compose (`wallet-<env>_auth-internal`, `internal: true`, на
хост не публикуется), `up.sh` ничего дополнительно не делает.

- google-auth слушает порт на адресе алиаса `google-auth-internal` (не на
  `0.0.0.0`), поэтому из общей сети `wallet-<env>` он недоступен.
- Клиенты получают `AUTH_INTERNAL_URL=http://google-auth-internal:8081`
  и ходят туда за `/internal/*`; JWKS берётся по-прежнему с `AUTH_SERVICE_URL`.
- Откат одного контура: `WALLET_AUTH_INTERNAL_URL=` (пустое значение) в
  `<env>.env` и `up.sh <env>` — клиенты вернутся на публичный порт.
- Порядок выката: сначала версия google-auth со служебным портом, потом
  клиенты. Клиент с `AUTH_INTERNAL_URL` и старым google-auth получит отказ в
  соединении.
- Проверка: из контейнера wallet-api `curl http://google-auth:8081` не отвечает;
  из wallet-ai `curl -X POST http://google-auth-internal:8081/internal/token/exchange` → 401.

## mTLS на служебном порту google-auth (раньше остального контура)

Критичный путь выдачи токенов (`/internal/telegram/*`, `/internal/mcp/token`,
`/internal/token/exchange`) защищается отдельно и раньше остального контура
(change `add-internal-mtls`, design D10–D13). Две настройки в `infra/env/<env>.env`:

```bash
# какие клиенты служебного порта ходят по mTLS (через запятую):
WALLET_AUTH_MTLS_CLIENTS=wallet-telegram          # wallet-telegram, wallet-mcp, wallet-ai
# проверка идентичности на google-auth (необязательно, по умолчанию observe):
WALLET_AUTH_IDENTITY=observe                      # или observe,telegram=enforce
```

**Перед первым включением** на хосте один раз: `bash infra/env/mtls-init.sh <env>` — создаёт
CA контура. Jenkins монтирует секреты только на чтение и создать CA не может; без него
выкат останавливается с этой подсказкой, сервисы не затрагиваются (откат на прежний тег).

Что происходит: google-auth получает второй служебный слушатель `:8443` (mTLS, клиентский
сертификат обязателен) рядом с обычным `:8081`; названные клиенты получают свой сертификат
и `AUTH_INTERNAL_URL=https://google-auth-internal:8443`. Остальные клиенты остаются на
`:8081` — переносить их можно по одному. Подключается `compose.auth-mtls.yaml`, сертификаты
выпускает `mtls.sh`. Образы google-auth и названных клиентов должны иметь метку
`org.wallet.mtls=1`, иначе `up.sh` и `deploy.sh` откажут.

`WALLET_AUTH_IDENTITY` — режимы `INTERNAL_IDENTITY` google-auth (README google-auth,
«Служебный порт»): по группам ручек `telegram`, `mcp-token`, `exchange` — `off`,
`observe` (журнал и метрика `internal_identity_total`, ничего не отклоняется),
`enforce-tls` (403 без сертификата и при CN ≠ actor), `enforce` (то же и 403 сервису не
из списка). Порядок включения: `observe` → сутки без расхождений → `enforce` по группе.

**Закрытие остаточных путей** (после того, как все клиенты на mTLS):

```bash
WALLET_AUTH_INTERNAL_PUBLIC=false   # /internal/* пропадает с публичного порта google-auth (404)
WALLET_AUTH_INTERNAL_PLAIN=false    # служебный порт без TLS (:8081) не слушается, остаётся :8443
```

Обе по умолчанию `true`. `PLAIN=false` допустим, только если в `WALLET_AUTH_MTLS_CLIENTS`
все три клиента (иначе скрипт останавливается до любых действий); `PUBLIC=false` несовместим с
пустым `WALLET_AUTH_INTERNAL_URL`. Нужна версия google-auth не ниже 0.4.3 — более старая
игнорирует `INTERNAL_ON_PUBLIC_PORT` и ручки останутся открытыми (проверка — п. ниже).
Проверка: `curl -s -o /dev/null -w '%{http_code}' -X POST http://google-auth:8080/internal/token/exchange`
из любого контейнера контура — 404; `curl … http://google-auth-internal:8081/…` — отказ соединения.

**Откат:** убрать строки и `up.sh <env>` — клиенты вернутся на `:8081` без mTLS; режим
`observe` или `off` вместо `enforce` — перезапуск google-auth тем же способом. Данные и
токены пользователей не затрагиваются.

**Проверка расхождений (observe):**

```bash
docker logs --since 1h wallet-<env>-google-auth-1 2>&1 | grep '"event":"internal_identity"' | grep -v '"finding":"ok"'
docker exec wallet-<env>-wallet-ai-1 curl -s http://google-auth:8080/metrics | grep internal_identity_total
```

`WALLET_INTERNAL_MTLS=true` (весь контур, ниже) подразумевает все три клиента.

## mTLS внутри контура

Взаимная TLS-аутентификация между сервисами (change `add-internal-mtls`): каждый
сервис предъявляет сертификат и проверяет сертификат собеседника. Необязателен и
**выключен по умолчанию**. Сервисы получают поддержку по шагам change (`tasks.md`),
поэтому включать режим можно только когда у всех образов контура есть метка
`org.wallet.mtls=1` — `up.sh` и `deploy.sh` иначе отказывают до любых действий.

**Включить** — одна строка в `infra/env/<env>.env`:

```bash
WALLET_INTERNAL_MTLS=true
```

и `bash infra/env/up.sh <env>`. **Выключить (откат)** — убрать строку (или
`false`) и снова `up.sh`: сервисы вернутся на обычный HTTP, данные и пользователи
не затрагиваются. Выпущенные сертификаты остаются на диске.

Что делает режим (скрипт `infra/env/mtls.sh`, выполняется при каждом вызове
compose):

- **CA контура** — `~/.config/wallet-secrets/<env>/mtls-ca/{ca.key,ca.crt}`. У
  каждого контура свой CA: сертификат test не проходит проверку prod. Закрытый ключ
  CA остаётся только там и **не монтируется** в контейнеры. Потеряли `ca.key` —
  удалить каталог `mtls-ca` и перезапустить: CA и все сертификаты выпустятся заново.
- **Сертификаты сервисов** — ECDSA P-256, срок 30 дней (`WALLET_MTLS_DAYS`), CN —
  имя сервиса, SAN — `<сервис>` и `<сервис>-<env>` (алиас для Prometheus),
  `serverAuth` и `clientAuth`. Лежат в `~/.local/state/wallet-envs/<env>/generated/mtls/<имя>/`
  (`tls.crt`, `tls.key`, `ca.pem`); каждому контейнеру монтируется только его
  каталог, read-only. Отдельный сертификат `prometheus` — клиентский.
- **Обновление** — повторный запуск ничего не меняет, пока осталось больше половины
  срока, CA тот же и имена прежние; иначе сертификат перевыпускается, а compose
  пересоздаёт только его контейнер (метка `wallet.mtls-config` — хэш сертификата).
  Отдельного таймера нет: сертификат обновляется при любом `up.sh` или выкате
  сервиса, поэтому между ними не должно проходить больше ~15 дней (иначе — `up.sh`
  вручную; открытый вопрос design.md).
- **compose** — `compose.mtls.yaml` подключается к `compose.yaml` только при
  включённом режиме (без него `docker compose config` не меняется): переменные
  `TLS_CERT`, `TLS_KEY`, `TLS_CA`, монтирование и healthcheck через `curl` с
  собственным сертификатом (имя в URL — имя сервиса, `127.0.0.1` в SAN нет). Входной
  порт гейтвея остаётся обычным HTTP — это граница контура.
- **Что на mTLS в этом режиме.** Серверы api, report, docs, ai, mcp, telegram и nginx (web) требуют
  клиентский сертификат; их вызовы друг к другу идут по https (`INTERNAL_MTLS=true`, его задаёт
  `compose.mtls.yaml`). Гейтвей: входной порт обычный HTTP, вызовы к апстримам по mTLS через пул
  постоянных соединений, второй слушатель `:8443` (только `/healthz`, `/metrics`, `/version`).
  Публичный порт google-auth остаётся HTTP (`/auth/*`, JWKS), его `/internal/*` — на служебных
  портах (раздел выше), а `/healthz` и `/metrics` — только по mTLS на отдельном порту `:8442`
  (`SERVICE_MTLS_PORT`, google-auth не ниже 0.4.4; на публичном порту их нет, `/version` остаётся).
  nginx без клиентского сертификата отвечает 400, а не рвёт рукопожатие.
- **Prometheus.** Задания сервисов генерирует `infra/monitoring/gen-scrape-config.sh` (его вызывает
  `infra/monitoring/up.sh`): по режиму каждого контура — https и клиентский сертификат `prometheus`
  этого контура (у контуров разные CA) либо обычный HTTP. Метки `job` и `env` прежние, дашборды не
  меняются. Гейтвей собирается со служебного порта `:8443`, google-auth — с `:8442` (публичный
  порт `:8080` остаётся HTTP для гейтвея и JWKS, `/metrics` на нём нет).
  После включения или выключения режима в контуре перезапустите `infra/monitoring/up.sh`.
- **Smoke выката.** При включённом режиме `deploy.sh` проверяет `/version` сервисов по https с
  сертификатом гейтвея (входной порт гейтвея и google-auth — как раньше).
- **Метка образа** — образы с поддержкой mTLS собираются с `LABEL org.wallet.mtls="1"`.

Права на ключи — 644: контейнер работает под другим uid, а монтируется только его
пара; граница — пользователь хоста.

**Проверка** (на копии контура, без влияния на настоящий):

```bash
openssl verify -CAfile ~/.config/wallet-secrets/<env>/mtls-ca/ca.crt \
    ~/.local/state/wallet-envs/<env>/generated/mtls/google-auth/tls.crt
openssl x509 -in .../google-auth/tls.crt -noout -ext subjectAltName
```

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

## Redis: пароль и ACL

Redis контура хранит токены google-auth (refresh на 30 дней, access, MCP, коды привязки Telegram,
счётчики неудачных входов). Без пароля его мог читать любой контейнер сети `wallet-<env>`.
Change `add-redis-auth`: ACL-пользователи с минимальными правами, пароли по файлу на потребителя.
Необязательно и **выключено по умолчанию**.

| Пользователь | Права | Кто использует |
| --- | --- | --- |
| `google-auth` | только `set get getdel del exists sadd srem smembers expire expiretime incr ttl` на ключах своих префиксов | сервис |
| `exporter` | чтение статистики (`info ping client\|list config\|get dbsize …`), без чтения и записи ключей | redis-exporter |
| `health` | только `ping` | healthcheck контейнера |
| `admin` | всё | оператор, `test-refresh.sh` |
| `default` | `compat`: включён без пароля (совместимость и откат); `on`: выключен | старые клиенты |

**Включить** (порядок важен, на каждом контуре; google-auth не ниже 0.4.5 должен быть выкачен **раньше**):

```bash
bash infra/env/redis-init.sh <env>        # один раз НА ХОСТЕ: пароли в ~/.config/wallet-secrets/<env>/redis/ (0600)
# infra/env/<env>.env:  WALLET_REDIS_AUTH=compat
bash infra/env/up.sh <env>                # Redis перезапускается с ACL, google-auth пересоздаётся (секунды; AOF и том целы)
# проверка: docker exec … redis-cli CLIENT LIST — у google-auth user=google-auth, нет user=default
# infra/env/<env>.env:  WALLET_REDIS_AUTH=on
bash infra/env/up.sh <env>                # ACL LOAD без рестарта: default выключается
```

Пароли создаёт только хостовый `redis-init.sh`: Jenkins монтирует секреты на чтение, выкат их читает и пишет
в `~/.local/state/wallet-envs/<env>/generated/redis/users.acl` одни SHA-256-хеши. Файлы `redis/*.env` —
по одному на потребителя, чтобы пароль не попадал в чужие контейнеры: в контейнер google-auth — только его
пароль, в контейнер Redis — только пароль `health`, `admin.env` никуда не монтируется.

**Откат:** `WALLET_REDIS_AUTH=compat` (default снова открыт) и `up.sh` — ACL перечитывается без рестарта;
`off` — возврат к Redis без пароля (Redis и google-auth пересоздаются). Данные Redis не затрагиваются.

**Оператор** — под `admin`, пароль через `REDISCLI_AUTH`, не аргументом:

```bash
docker exec -it -e REDISCLI_AUTH="$(sed -n 's/^REDISCLI_AUTH=//p' ~/.config/wallet-secrets/<env>/redis/admin.env)" \
    wallet-<env>-redis-1 redis-cli --user admin
bash -c 'source infra/env/lib.sh; env_init test; env_redis_admin DBSIZE'   # то же через скрипты контура
```

Внутри контейнера Redis уже задан `REDISCLI_AUTH` пользователя `health`, поэтому `redis-cli` без `--user admin`
и без своего `REDISCLI_AUTH` при выключенном `default` ответит `WRONGPASS` — это нормально. TLS до Redis ещё нет
(`add-internal-mtls`, группа 9): пароль защищает от неаутентифицированного доступа, но не от перехвата в сети.

## Контур руками

```bash
# compose контура с теми же переменными, что у скриптов:
bash -c 'source infra/env/lib.sh; env_init test; env_compose ps'
bash -c 'source infra/env/lib.sh; env_init test; env_compose logs -f wallet-api'

docker exec -it wallet-test-db-1 sh -c 'psql -U "$POSTGRES_USER" -d wallet_api'
bash -c 'source infra/env/lib.sh; env_init test; env_redis_admin INFO keyspace'   # Redis с паролем: под admin, см. «Redis: пароль и ACL»
```

Остановить контур, не теряя данных: `env_compose stop`. `env_compose down -v`
удаляет тома — в prod так не делать.
