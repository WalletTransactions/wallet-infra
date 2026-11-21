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
  service-mesh, пароль и ACL на Redis (отдельный change, **зависимость**: Redis
  хранит access- и refresh-токены без пароля), отказ от `X-Service-Secret` в
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
- **Зависимости от других changes:** перед этим change — пароль и ACL на Redis
  (отдельный change). После него — client assertion JWT вместо
  `X-Service-Secret` (`TODO_service_auth_tls.md`, п. 1). Порядок работ внутри
  change определяется риском выдачи токенов и описан в design.md (D13).
