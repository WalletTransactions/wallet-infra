# Proposal

## Why

Внутри контура всё ходит по обычному HTTP: Bearer-токены и cookie пользователей,
персональные токены MCP, обмен токена бота — открытым текстом между
контейнерами, а `/internal/*` в google-auth защищён только тем, что гейтвей его
не маршрутизирует. На одной машине в LAN это допустимо; при выходе контура за её
пределы (второй хост, k8s, недоверенный сегмент сети) — нет. Сервисы между собой
не аутентифицируются: любой контейнер в сети `wallet-<env>` может вызвать
`/internal/telegram/token` и любой другой внутренний эндпоинт. Закрыть это нужно
до выхода из LAN, а не после (см. `org/docs/TODO_service_auth_tls.md`, п. 2).

## What Changes

- Необязательный режим «mTLS внутри контура», включается одной настройкой
  контура (`WALLET_INTERNAL_MTLS=true` в `infra/env/<env>.env`). Выключен — стенд
  работает как раньше, по обычному HTTP.
- Свой мини-CA для каждого контура (отдельный от CA ingress из
  `add-tls-ingress`) и сертификаты ECDSA P-256 на каждый сервис, выпускаемые и
  обновляемые скриптом `infra/env/`; закрытый ключ CA остаётся вне контейнеров.
  Сертификат сервиса покрывает оба имени: `<сервис>` и `<сервис>-<env>`.
- Серверы и клиенты HTTP-сервисов используют TLS с обязательной проверкой
  сертификата противоположной стороны; сервис без действительного
  сертификата не принимается.
- **Критичный путь «токен по токену» идёт первым.** `/internal/telegram/token`,
  `/internal/token/exchange`, `/internal/mcp/token` выдают токены по общему
  `X-Service-Secret` (actor определяется секретом) и сегодня ходят открытым
  текстом. Они выделяются в google-auth на **отдельный порт** в отдельной сети
  `auth-internal` (google-auth, telegram, mcp, ai) и переводятся на mTLS раньше
  остального контура, по одному клиенту.
- google-auth на `/internal/*` проверяет идентичность клиента (CN/SAN) по списку
  «какой сервис какие эндпоинты может вызывать» и сверяет её с actor, который
  определяется секретом. Включается в два этапа: сначала **наблюдение**
  (расхождения в журнал и метрику, запросы не отклоняются), затем **отказ**.
  Секрет остаётся вторым фактором, пока его не заменит отдельный change.
- `/healthz` и `/metrics` тоже только по mTLS: healthcheck контейнера
  выполняется с собственным сертификатом сервиса, Prometheus получает свой
  клиентский сертификат.
- Горячие связи (гейтвей → api, report, ai, mcp) используют постоянные
  соединения (keep-alive), чтобы handshake выполнялся не на каждый запрос.
- Отдельным поздним этапом: TLS до Postgres и Redis.
- **Вне объёма:** LM Studio на `host.docker.internal`, `api.telegram.org`, k8s и
  service-mesh, TLS до Redis кроме группы 9 (пароль и ACL на Redis — часть R этого change), отказ от `X-Service-Secret` в
  пользу client assertion JWT (отдельный change после этого).

## Capabilities

### New Capabilities
- `internal-service-tls`: взаимная TLS-аутентификация между сервисами контура —
  включение и отключение режима, выпуск и обновление сертификатов, проверка
  сертификатов обеими сторонами, права сервисов на `/internal/*`, доступность
  health и метрик, TLS до баз.

### Modified Capabilities
- `environment-observability`: Prometheus собирает метрики сервисов контура и
  при включённом mTLS; требование «Метрики помечены контуром» не меняется, но
  добавляется требование доступности `/metrics` в этом режиме.

## Impact

- **wallet-infra**: `compose.yaml` (монтирование сертификатов, переменные TLS,
  healthcheck), `infra/env/` (скрипт CA и выпуска, подключение в `up.sh` и
  `deploy.sh`), `infra/env/<env>.env`, `infra/monitoring/prometheus.yml`,
  README (корневой и `infra/env`).
- **wallet-common** (вендорится во все сервисы): общий слой TLS для httplib
  (создание сервера и клиента из `TLS_CERT`, `TLS_KEY`, `TLS_CA`), пул клиентов
  с keep-alive; правки `util/jwks.cpp` и `clients/reports_client.cpp`.
- **Сервисы** — по одной правке `scripts/vendor.sh` и сборки каждого:
  google-auth, wallet-api, wallet-report, wallet-ai, wallet-gateway,
  wallet-mcp, wallet-telegram, wallet-docs. У wallet-api, wallet-report,
  wallet-mcp, wallet-docs сейчас нет `CPPHTTPLIB_OPENSSL_SUPPORT` в CMake.
- **BuildPlatform** (Jenkins, вне git): healthcheck и smoke-проверки выката.
- **Порядок выката:** сначала версии сервисов с поддержкой TLS (по умолчанию
  выключено), потом включение режима на test, потом prod.
- **RAM/CPU**: TLS добавляет единицы МБ на сервис и доли миллисекунды на
  handshake с ECDSA; лимиты `mem_limit` пересматриваются по замеру, GPU не
  затрагивается.
- **Compose**: сеть `auth-internal` и второй порт google-auth для `/internal/*`
  (google-auth, wallet-telegram, wallet-mcp, wallet-ai); основная сеть
  `wallet-<env>` остаётся для остального.
- **Зависимости от других changes:** перед mTLS в этом же change выполняется часть R — пароль и ACL на Redis. После него — client assertion JWT вместо
  `X-Service-Secret` (`TODO_service_auth_tls.md`, п. 1). Порядок работ внутри
  change определяется риском выдачи токенов и описан в design.md (D13).

---

## Часть R. Redis: пароль и ACL (бывший change `add-redis-auth`)

Объединено с `add-internal-mtls` 2026-11-22: пароль Redis — шаг 1 порядка D13, и вести его отдельным change не имело смысла. Старое имя `add-redis-auth` остаётся в комментариях кода и скриптов (google-auth, `compose.redis-auth.yaml`, `infra/env/redis*.sh`) — это ссылка на эту часть; спека `redis-access-control` перенесена сюда же.

### Why

Redis контуров prod и test хранит активные access- и refresh-токены google-auth
(refresh живёт 30 дней), персональные MCP-токены, одноразовые коды привязки
Telegram и счётчики неудачных входов. Он запущен **без пароля**: порт наружу не
публикуется, но любой контейнер сети `wallet-<env>` может прочитать эти токены,
подделать их или отозвать чужие сессии. Это самая дешёвая из открытых дыр на
критичном пути «токен по токену» и условие `add-internal-mtls` (design D13,
шаг 1): без пароля Redis защита `/internal/*` и mTLS на нём не имеет смысла.

### What Changes

- Redis контура требует аутентификацию: ни одна команда без неё не выполняется.
- Вместо одного общего пароля — **ACL-пользователи** с минимальными правами:
  - `google-auth`: только команды и префиксы ключей, которые использует сервис
    (`refresh_token:`, `access_token:`, `user_*_tokens:`, `mcp_token:`,
    `tg_link_code:`, `authfail:`), без `FLUSHALL`, `CONFIG`, `KEYS`;
  - `exporter`: только чтение статистики для redis-exporter;
  - `health`: только `PING` для healthcheck контейнера;
  - `admin`: все права, для оператора и `test-refresh.sh` (`FLUSHALL`).
  Пользователь `default` выключается последним шагом выката.
- Пароли генерируются скриптом, у каждого контура и пользователя свои, лежат в
  секретах контура вне git (`~/.config/wallet-secrets/<env>/redis/`, по одному
  файлу на потребителя, чтобы пароль не попадал в чужие контейнеры), в
  ACL-файле контура хранятся только SHA-256-хеши.
- google-auth получает необязательную настройку `REDIS_USERNAME` (сейчас клиент
  умеет только `AUTH <пароль>`, то есть пользователя `default`); без неё
  поведение прежнее.
- Redis-exporter (стек метрик), healthcheck, `test-refresh.sh` и инструкции для
  оператора (`docker exec … redis-cli`) переводятся на свои учётные данные.
- Выкат без потери токенов и без остановки входа дольше одного рестарта
  Redis: сначала версия google-auth с `REDIS_USERNAME`, затем Redis с ACL и
  включённым `default` (совместимость), затем переключение клиентов, затем
  выключение `default`. Откат на любом шаге — возврат прежнего ACL-файла.
- **Вне объёма:** TLS до Redis (`add-internal-mtls`, группа 9), смена
  значения токенов или формата ключей, пул соединений в google-auth,
  Redis Sentinel или кластер.

### Capabilities

### New Capabilities
- `redis-access-control`: аутентификация и права доступа к Redis контура —
  пользователи и их права, хранение учётных данных, выключение
  безымянного доступа, порядок включения без потери токенов, откат, доступ
  оператора, доступность метрик и healthcheck.

### Modified Capabilities

(нет: требования существующих спек не меняются; `deployment-environments`
«Изоляция секретов и токенов» остаётся в силе, новая спека её дополняет)

### Impact

- **wallet-infra**: `compose.yaml` (сервис `redis`: ACL-файл, healthcheck;
  google-auth: переменные `REDIS_USERNAME`, `REDIS_PASSWORD`), новый скрипт
  `infra/env/redis-auth.sh` (генерация секретов и ACL-файла, вызывается из
  `up.sh`), `infra/env/test-refresh.sh` (`FLUSHALL` под `admin`),
  `infra/monitoring/compose.yaml` и `up.sh` (учётные данные exporter), README
  (корневой, `infra/env`, `infra/db`: команды для оператора).
- **google-auth** (репозиторий google-auth): `redis_client.cpp` и `main.cpp`
  (`AUTH <пользователь> <пароль>`), README, `.env.example`, юнит-тест.
  Версия выкатывается **раньше** включения Redis-пароля.
- **BuildPlatform (Jenkins)**: проверить, нет ли в джобах `redis-cli` без
  пароля (бэкап, smoke); при наличии — править вне git, с резервной копией.
- **Хост**: один рестарт контейнера Redis на контур (AOF и том сохраняются),
  RAM и диск не растут, GPU не затрагивается.
- **Порядок:** выполняется **до** `add-internal-mtls`; задача 1.2 того change
  ссылается на этот.
