# Установка стека WalletTransactions — от минимума до максимума

Инструкция идёт «слоями»: каждый следующий уровень добавляется поверх
предыдущего и не требует переделывать то, что уже стоит. Остановиться можно
на любом уровне — он самодостаточен.

| Ур. | Что получаете | Чего требует сверх предыдущего |
| --- | --- | --- |
| 0 | Хост готов | docker, учётка GitHub, OAuth-клиент Google |
| 1 | **Минимум:** контур test — веб-кабинет, синк, отчёты, Telegram-бот | секреты, теги образов, `up.sh test` |
| 2 | ИИ: разбор трат текстом, импорт выписок, чат | GPU-хост с LM Studio |
| 3 | MCP и обмен токена (LM Studio/Claude как клиент к данным) | 3 секрета |
| 4 | Контур prod | свои секреты, свой бот, свой порт |
| 5 | Метрики и логи | Prometheus/Grafana, OpenSearch (~1,3 ГБ RAM) |
| 6 | Справка wallet-docs (поиск по спекам + LLM) | pgvector, база docs |
| 7 | Автоматика: Jenkins, авто-выкат по тегам, бэкапы | BuildPlatform |
| 8 | Android-клиент | JDK 17, Android SDK |

Подробности по каждому шагу — в [`infra/env/README.md`](infra/env/README.md)
(контуры), [`infra/db/README.md`](infra/db/README.md) (Postgres) и README
сервисов. Здесь — только порядок и «что может пойти не так».

---

## Уровень 0. Подготовка хоста (один раз)

**Нужно на хосте:** Linux, `docker` с плагином `compose` v2, `git`, `curl`,
`openssl`, `jq` (только для заливки индекса wallet-docs).

**Раскладка папок.** Репозитории лежат соседями, имена папок = имена
репозиториев (скрипты ищут друг друга по относительным путям):

```text
WalletTransactions/          # сама папка — НЕ git-репозиторий
├── wallet-infra/            # отсюда поднимается стек
├── google-auth/  wallet-api/  wallet-report/  wallet-gateway/
├── wallet-web/  wallet-telegram/  wallet-ai/  wallet-mcp/  wallet-docs/
└── android-wallet/  org/  wallet-site/
```

```bash
git clone git@github.com:WalletTransactions/wallet-infra.git
# остальные — по необходимости; для уровня 1 нужны ТОЛЬКО .env.example сервисов,
# значит клонировать надо google-auth, wallet-api, wallet-report, wallet-ai,
# wallet-gateway, wallet-telegram (образы собирает CI, на хосте сборки нет)
```

**Доступ к образам.** Образы лежат в приватном `ghcr.io/wallettransactions/*`:

```bash
docker login ghcr.io          # токен GitHub с правом read:packages
```

**Google OAuth-клиент** (Google Cloud Console → Credentials → OAuth client ID,
тип *Web application*). Нужны `GOOGLE_CLIENT_ID` и `GOOGLE_CLIENT_SECRET`.
В *Authorized redirect URIs* добавить
`http://localhost:8091/auth/google/callback` (для prod — `:8090`). Вход из LAN:
Google не принимает голый IP — используйте `<LAN-IP>.nip.io` (см.
`google-auth/.env.example`, `ALLOWED_REDIRECT_URIS`).

**Telegram-бот контура.** В @BotFather создать отдельного бота *для test*
(токен и username). Один токен — один процесс, иначе Telegram отвечает 409.

---

## Уровень 1. Минимум: контур test

Поднимаются: `db` (Postgres 16 + pgvector), `redis`, `google-auth`,
`wallet-api`, `wallet-report`, `wallet-ai`, `wallet-mcp`, `wallet-web`,
`wallet-gateway`, `wallet-telegram`. Наружу — только гейтвей на `:8091`.

> `up.sh` поднимает контур целиком и не умеет «половину». `wallet-gateway`
> ждёт healthy у `wallet-ai`, а `compose.yaml` требует теги и env-файл для
> всех сервисов (`${…:?}`), поэтому «минимум» — это весь базовый набор, а не
> отдельные контейнеры. ИИ при этом остаётся выключенным (см. шаг 2).

### 1. Секреты (вне git)

```bash
S=~/.config/wallet-secrets/test
install -m 700 -d "$S"
install -m 600 infra/db/.env.example "$S/db.env"
for s in google-auth wallet-api wallet-report wallet-ai wallet-gateway wallet-telegram; do
    install -m 600 "../$s/.env.example" "$S/$s.env"
done
openssl genrsa -out "$S/jwt_signing_key.pem" 2048 && chmod 644 "$S/jwt_signing_key.pem"
```

Права проверяет `up.sh` и не стартует с другими: каталог **700**, `*.env`
**600**, `.pem` **644** (его читает google-auth в контейнере под своим uid).

Что вписать руками:

| Файл | Что |
| --- | --- |
| `db.env` | заменить **все** `change-me-*` разными паролями: `openssl rand -hex 24`. Значения `*_USER/_PASSWORD/_DB` — только `[A-Za-z0-9._~-]`, иначе ломаются URL подключения |
| `google-auth.env` | `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `REDIRECT_URL=http://localhost:8091/auth/google/callback`, `ADMIN_EMAILS` (первый вход этого адреса создаёт админа), `TELEGRAM_SERVICE_SECRET` (любая случайная строка), `TELEGRAM_BOT_USERNAME` (без `@`), `JWT_RSA_PRIVATE_KEY_PATH=/app/jwt_signing_key.pem` |
| `wallet-telegram.env` | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_BOT_USERNAME`, **тот же** `TELEGRAM_SERVICE_SECRET`, что в `google-auth.env` |
| остальные `*.env` | `DATABASE_URL`, адреса соседей, `HOST`/`PORT` можно не трогать — `compose.yaml` их переопределяет |

### 2. Теги образов

Обычно `tags.env` ведёт выкат; на пустом контуре — руками, по тегам,
опубликованным в ghcr (проверьте актуальные в GitHub → Packages):

```bash
mkdir -p ~/.local/state/wallet-envs/test
cat > ~/.local/state/wallet-envs/test/tags.env <<'EOF'
GOOGLE_AUTH_TAG=<тег>
WALLET_API_TAG=<тег>
WALLET_REPORT_TAG=<тег>
WALLET_AI_TAG=<тег>
WALLET_GATEWAY_TAG=<тег>
WALLET_WEB_TAG=<тег>
WALLET_TELEGRAM_TAG=<тег>
WALLET_MCP_TAG=<тег>
EOF
```

Для test — теги вида `X.Y.Z-rc.N`. **Любой пропущенный тег** роняет `up.sh`
на первой же строке compose — так и задумано.

### 3. Настройки контура

`infra/env/test.env` уже в git. Чтобы ИИ был выключен (нет GPU-хоста),
оставьте `LLM_URL=` пустым — `/api/ai/status` ответит `enabled=false`, трата
текстом и импорт выписок будут недоступны, всё остальное работает.

### 4. Запуск

```bash
bash infra/env/up.sh test
curl -s http://localhost:8091/healthz
```

`up.sh` по порядку: создаёт docker-сеть `wallet-test` → `db`, `redis` →
миграции баз `auth`, `wallet`, `telegram`, `ai`, `perf` → остальные сервисы,
ждёт healthy. Повторный запуск безопасен. На первом старте пустого тома
`infra/db/init-db.sh` заводит роли и базы сам.

### 5. Проверка

1. Открыть `http://localhost:8091` → «Войти через Google» адресом из
   `ADMIN_EMAILS` — вы админ.
2. Бейдж версии в углу = `GET /api/versions` — все сервисы должны ответить.
3. «Подключить Telegram» в вебе → бот отвечает.
4. Swagger каждого сервиса — `GET /docs` на его прямом порту (внутри сети).

Данных нет — только схема. Контур можно остановить `env_compose stop`
(`down -v` удаляет тома, в prod так не делать).

---

## Уровень 2. ИИ на хосте (LM Studio)

GPU и модель — на хосте, вне docker. Проверено на GTX 1070 8 ГБ: модели до
8B в Q4 (по умолчанию `qwen/qwen3-8b`, ~4,7 ГБ при контексте 8192); 14B не
помещается.

1. Установить LM Studio и CLI `lms`.
2. Запустить сервер и загрузить модель под стабильным id `wallet-parse`:
   `bash wallet-ai/scripts/lms-load.sh` (идемпотентен; после перезагрузки
   хоста запускать заново).
3. В GUI: *Developer → Server Settings* → «Serve on Local Network»; порт
   `1234` в файрволе — только для docker-сетей (`172.16.0.0/12`). Включить
   токен API; логи запросов (verbose) выключить — там тексты трат.
4. `LLM_API_KEY=<токен>` — в `wallet-ai.env`; `LLM_URL`/`LLM_MODEL` уже в
   `infra/env/<env>.env`.
5. `bash infra/env/up.sh test` — сервис пересоздастся. Проверка:
   `/api/ai/status` → `enabled=true`.

> GPU один: тяжёлые задания test (импорт выписок) занимают его и у prod.

Чат (вид `chat`) требует ещё и уровень 3 (обмен токена).

---

## Уровень 3. MCP и обмен токена

`wallet-mcp` уже поднят на уровне 1 и принимает MCP-токены `wmcp_…` без
доп. настроек (токен выпускается в веб-кабинете). Чтобы wallet-ai-чат и
JWT-клиенты ходили в wallet-mcp, включается обмен токена (RFC 8693) — три
строки одного контура, секреты у test и prod **разные**:

| Файл | Строка |
| --- | --- |
| `google-auth.env` | `TOKEN_EXCHANGE_SECRETS=wallet-ai=<A>,wallet-mcp=<M>` |
| `wallet-mcp.env` (600) | `AUTH_EXCHANGE_SECRET=<M>` |
| `wallet-ai.env` | `AUTH_EXCHANGE_SECRET=<A>` |

`<A>` и `<M>` — `openssl rand -hex 32`. Затем `bash infra/env/up.sh test`.
Откат — убрать строки и `up.sh` ещё раз.

Подключение MCP-клиента: URL **с завершающим слэшем** —
`http://<хост>:8091/api/mcp/` (без слэша гейтвей отдаёт 401).

---

## Уровень 4. Контур prod

То же самое, что уровень 1, со своими значениями. Отличия:

| | test | prod |
| --- | --- | --- |
| Секреты | `~/.config/wallet-secrets/test/` | `~/.config/wallet-secrets/prod/` — **другие** пароли и JWT-ключ |
| Порты | гейтвей `8091`, Postgres `127.0.0.1:15432` | `8090`, `127.0.0.1:15555` |
| Telegram | отдельный test-бот | основной бот |
| `REDIRECT_URL` | `…:8091/auth/google/callback` | `…:8090/auth/google/callback` (и добавить в Google Console) |
| Теги | `X.Y.Z-rc.N` | только финальный `X.Y.Z`, чей digest уже прошёл test |
| Память | `oom_score_adj=500` (убивается первым) | `-900` |

```bash
bash infra/env/up.sh prod
curl -s http://localhost:8090/healthz
```

**Бэкапы prod** обязательны до первых реальных данных. Нужна переменная
`WALLET_BACKUP_DIR` на **другом физическом диске**, чем тома docker:

```bash
WALLET_BACKUP_DIR=/path/to/other/disk bash infra/env/backup.sh prod --label manual
```

Автоматически: перед каждой миграцией в prod и ежесуточно (уровень 7).

**Данные для test из prod** (после появления данных в prod):
`bash infra/env/test-refresh.sh` — под блокировкой test, с вычисткой
привязок Telegram и Redis. Персональные данные prod окажутся в test — это
допустимо, пока test доступен только владельцу.

---

## Уровень 5. Метрики и логи (общие на оба контура)

Отдельные compose-проекты, по умолчанию **не поднимаются после перезагрузки**
(`restart: "no"`) — контуры от них не зависят.

```bash
# Prometheus + Grafana (Grafana :13000, Prometheus :19090)
bash infra/monitoring/up.sh

# OpenSearch + Dashboards (:15601), ~1,3 ГБ RAM
docker compose -f infra/logging/compose.yaml up -d
```

- Логин Grafana — `admin`, пароль в `~/.config/wallet-secrets/monitoring.env`
  (`GRAFANA_ADMIN_PASSWORD`; нет файла — `up.sh` создаст со случайным).
- `up.sh` метрик требует в `test/db.env` `PERF_READER_POSTGRES_PASSWORD`
  (роль `perf_reader` для дашборда «Perf History»); сети `wallet-prod` и
  `wallet-test` создаёт сам.
- Логи контейнеров пишутся в journald всегда; Fluent Bit при старте
  дочитывает пропущенное. Без стека смотреть:
  `journalctl CONTAINER_NAME=wallet-test-wallet-api-1 --since "2026-11-20 10:00 UTC"`.
- Стек логов — dev-стенд (security-плагин OpenSearch выключен), не выставлять
  наружу.

---

## Уровень 6. wallet-docs (необязательный модуль)

Справка по OpenSpec-спекам: гибридный поиск (полнотекст + pgvector) и ответ
LLM со ссылками. Включается **только после** уровня 2 (нужны LLM и модель
эмбеддингов). Порядок — сначала test, потом prod:

1. **pgvector.** Образ `db` уже `pgvector/pgvector:pg16`; на контуре,
   поднятом со старого alpine-образа, том надо пересоздать (индексы
   несовместимы из-за разной сортировки musl/glibc): дамп
   (`backup.sh <env> --label pre-pgvector`) → `down` → `docker volume rm
   wallet-<env>_db-data` → `up.sh` → восстановление / `test-refresh.sh`.
   На свежем контуре этот шаг не нужен.
2. **База.** В `db.env` добавить `DOCS_POSTGRES_USER/PASSWORD/DB`, затем
   `up.sh <env>` и `bash infra/env/migrate.sh <env> docs`.
3. **Сервис.** Тег `WALLET_DOCS_TAG=<тег>` в `tags.env` руками;
   `wallet-docs.env` (600): `INDEX_TOKEN`, `LLM_URL`, `LLM_MODEL`,
   `EMBED_MODEL`. Нет файла — вопросы и заливка отвечают 503.
4. **Включить профиль** — две строки **вместе** в `infra/env/<env>.env`:
   ```bash
   COMPOSE_PROFILES=docs
   WALLET_DOCS_URL=http://wallet-docs:8089
   ```
   `up.sh <env>`. Без профиля гейтвей отвечает `404 docs не подключён`, а
   клиенты прячут раздел.
5. **Индекс:** `bash infra/env/docs-index.sh <env> all` (источник — папки
   `openspec/` в соседних репозиториях); дальше — ночной job Jenkins.

Выключение — убрать обе строки и пересоздать контур.

---

## Уровень 7. Автоматика: Jenkins (BuildPlatform)

Выкат по git-тегам, ежесуточный бэкап prod, нагрузочные прогоны, ночная
заливка индекса docs.

```bash
cd BuildPlatform
cp jenkins/.env.example jenkins/.env
# поправить *_PATH под свою машину (проекты монтируются в Jenkins на ТЕ ЖЕ
# абсолютные пути, что на хосте — иначе docker-outside-of-docker сломается)
docker compose --env-file jenkins/.env up -d --build
```

Jenkins — `http://localhost:18081`; пароль:
`docker exec buildplatform-jenkins-1 cat /var/jenkins_home/secrets/initialAdminPassword`.
Плагины вшиты в образ. Jobs заводятся как «Pipeline script» одной строкой,
читающей `jobs/<имя>/Jenkinsfile` с диска (см. `BuildPlatform/jenkins/README.md`,
«Заводим новый job»).

Что нужно хосту дополнительно:

- токен GitHub для чтения тегов приватного wallet-infra (fine-grained,
  только `wallet-infra`, Contents — Read-only):
  ```bash
  install -m 600 /dev/null ~/.config/wallet-secrets/github-read.token
  $EDITOR ~/.config/wallet-secrets/github-read.token
  ```
- каталоги секретов и состояния смонтированы в контейнер Jenkins
  (`WALLET_SECRETS_ROOT`, `WALLET_STATE_ROOT`).

Ключевые job'ы: `env-release-watch` (раз в 5 минут: `release-watch.sh` →
`env-deploy`), `env-rollback`, `prod-backup`, `env-test-refresh`,
`docs-index`, `deploy-monitoring`, `deploy-logging`.

**Порядок выката:** тег `vX.Y.Z-rc.N` сервиса → CI публикует образ → test →
после smoke тот же digest разрешён в prod как `X.Y.Z`. Один за другим (rc-теги
dependent-сервисов выкатывать по очереди). Вручную — тот же скрипт:
`bash infra/env/deploy.sh <env> <сервис> <тег>`; откат —
`… <сервис> <прежний тег> --rollback`.

---

## Уровень 8. Android-клиент

Нужны JDK **17** (системный 21 ломает D8 — задайте `org.gradle.java.home`
в `~/.gradle/gradle.properties`, не в файле проекта) и Android SDK
(platform 34, build-tools 30.0.3); путь — в `local.properties` (`sdk.dir=…`).

```bash
cd android-wallet
./gradlew assembleDebug            # prod и qa: app/build/outputs/apk/{prod,qa}/debug/
./deploy-debug.sh [serial]         # собрать и поставить prod на устройство через adb
FLAVOR=qa ./deploy-debug.sh        # qa (смотрит на test-контур :8091); FLAVOR=all — оба
```

Два приложения рядом: `prod` (`:8090`) и `qa` (`:8091`), у каждого своя база.
Адрес сервера в LAN вводится в «Ещё → Интеграции». Вход Google в `qa` требует
Android OAuth client для пакета `com.example.wallettransactions.qa` с SHA-1
debug-ключа хоста.

---

## Частые грабли

| Симптом | Причина / решение |
| --- | --- |
| `docker compose up` падает на `${VAR:?}` | Голый compose не работает — только `infra/env/up.sh <env>`; при ручных командах — `env_compose` из `lib.sh` |
| `права … — NNN, нужно …` | `chmod 700` на каталог секретов, `600` на `*.env`, `644` на `.pem` |
| Сервис падает на старте «нет таблицы» | Не накатили миграции — `migrate.sh <env> <база>` (сервисы проверяют схему сами) |
| `up.sh` падает после правки паролей | В `db.env` символ вне `[A-Za-z0-9._~-]` (в т. ч. кириллица) |
| Пароли в `db.env` поменяли, а контур не принял | Роли заводятся только при ПЕРВОМ старте пустого тома; менять пароль надо и в самой БД |
| Бот отвечает 409 | Два процесса на одном токене — заведите отдельного бота на контур |
| `/api/mcp` → 401 | Нужен завершающий слэш: `/api/mcp/` |
| Хост завис по памяти | Не собирайте/не поднимайте несколько тяжёлых стеков параллельно; логи и метрики держите выключенными, когда не нужны |
| Вход Google: `redirect_uri_mismatch` | URI в `REDIRECT_URL` должен совпасть **символ в символ** с записью в Google Console |
