# servers

Серверная часть проекта на C++ — авторизация через Google, свой CRUD
кошельков, единый гейтвей и статика веб-кабинета (SPA). Прототип отчётов на Python
удалён 2026-09-30 — его логика переезжает сюда.

## Сервисы

| Сервис | Роль | README | OpenAPI |
| --- | --- | --- | --- |
| `google-auth` | "Sign in with Google", своя сессия (JWT), CRUD пользователей/ролей | [google-auth/README.md](https://github.com/WalletTransactions/google-auth/blob/main/README.md) | [openapi.yaml](https://github.com/WalletTransactions/google-auth/blob/main/openapi.yaml) |
| `wallet-api` | CRUD кошельков, своя БД, протокол синка `/sync/*` (write-сторона) | [wallet-api/README.md](https://github.com/WalletTransactions/wallet-api/blob/main/README.md) | [openapi.yaml](https://github.com/WalletTransactions/wallet-api/blob/main/openapi.yaml) |
| `wallet-report` | Отчёты `/api/reports/*` — CQRS-lite query-сторона, читает ТУ ЖЕ базу, что wallet-api, единственной read-only ролью | [wallet-report/README.md](https://github.com/WalletTransactions/wallet-report/blob/main/README.md) | [openapi.yaml](https://github.com/WalletTransactions/wallet-report/blob/main/openapi.yaml) |
| `wallet-ai` | LLM-функции `/api/ai/*`: разбор трат текстом, импорт выписок, чат. Ничего не пишет; LLM — LM Studio на хосте | [wallet-ai/README.md](https://github.com/WalletTransactions/wallet-ai/blob/main/README.md) | [openapi.yaml](https://github.com/WalletTransactions/wallet-ai/blob/main/openapi.yaml) |
| `wallet-gateway` | Единая точка входа: маршрутизация по префиксу, проверка JWT | [wallet-gateway/README.md](https://github.com/WalletTransactions/wallet-gateway/blob/main/README.md) | [openapi.yaml](https://github.com/WalletTransactions/wallet-gateway/blob/main/openapi.yaml) |
| `wallet-web` | Статика SPA-кабинета, отдаётся nginx (своего API нет) | [wallet-web/README.md](https://github.com/WalletTransactions/wallet-web/blob/main/README.md) | [openapi.yaml](https://github.com/WalletTransactions/wallet-web/blob/main/site/openapi.yaml) |

Схемы взаимодействия — [infra/diagrams](infra/diagrams) (`components.puml`,
`sequence.puml`, `sync-sequence.puml`).

**Каждый сервис отдаёт свою спеку сам**, на своём прямом порту —
`GET /openapi.yaml` (файл как есть) и `GET /docs` (Swagger UI поверх него,
вендоренный статический бандл, без CDN — см. `<сервис>/third_party/swagger-ui/README.md`,
у `wallet-web` — `site/vendor/swagger-ui/README.md`). У `wallet-gateway` это
СВОЯ спека (таблица маршрутизации), не переописание апстримов — она
единственная, что доступна через сам гейтвей (`/docs`/`/openapi.yaml`
апстримов через гейтвей не проксируются, см. его README).

**Правило: меняешь HTTP API сервиса — правь его `openapi.yaml` в том же
заходе.** Новый эндпоинт, новое поле запроса/ответа, новый код ответа,
смена формы ошибки — всё это сразу в спеку, не отложенным пунктом; иначе
она начинает врать так же тихо, как зеркало DDL без парного обновления
(см. `wallet-api/schema/README.md`, тот же принцип для схемы БД). Для
`wallet-gateway` (чистый прокси) правится только таблица маршрутизации в
его `openapi.yaml`, не переописание чужого протокола — контракт
форвардящихся операций живёт в openapi апстрима. После правки —
`python -m openapi_spec_validator servers/<сервис>/openapi.yaml` должен
проходить чисто.

**У каждого из 4 C++-сервисов (google-auth/wallet-api/wallet-report/
wallet-gateway) есть версия, проставляемая на билде** — не хардкодится в
исходниках. Источник — файл `VERSION` (semver) рядом с `CMakeLists.txt`
сервиса плюс git-хэш коммита (передаётся при сборке образа, см.
`compose.yaml`); видно через `GET /version`,
строку лога при старте и `build_info` в `GET /metrics` — см. README
google-auth, раздел "Версия", там же весь механизм подробно (у остальных
сервисов — краткая ссылка туда же).

Мобильный вход + синхронизация Android SQLite с сервером + веб-отчёты —
план работ в [TODO_mobile_sync.md](https://github.com/WalletTransactions/.github-private/blob/main/docs/TODO_mobile_sync.md). Мобильный вход и
протокол синка (`/sync/push`/`/sync/pull`/`/sync/blobs`, домен
`wallet-api/schema/`) уже реализованы на сервере и в Android-клиенте, но не
прогнаны вживую end-to-end (см. план, разделы "Не сделано"); веб-отчёты —
эндпоинты (`GET /api/reports/*`, сервис `wallet-report`) готовы и проверены
на живой базе, экран в SPA (`wallet-web`) тоже готов, но не прогнан вживую в
браузере.

## Инфраструктура — `infra/`

| Папка | Что внутри |
| --- | --- |
| `infra/db` | Конфиг инстанса Postgres: три + две служебные роли, `init-db.sh`, версионированные миграции (`migrations/{auth,wallet,perf}`) и `migrate.sh` — см. [infra/db/README.md](infra/db/README.md). `perf` — история прогонов нагрузочного контура (`test_run`/`test_result`, читается дашбордом Grafana "Perf History", см. `wallet-report/loadtest/README.md`) |
| `infra/k8s` | Манифесты для локального кластера (minikube/kind/Rancher Desktop), аналог `compose.yaml` — см. [infra/k8s/README.md](infra/k8s/README.md) |
| `infra/logging` | Конфиг Fluent Bit и сохранённые объекты OpenSearch Dashboards для дев-стенда логов — отдельный стек `wallet-logging`, [`infra/logging/compose.yaml`](infra/logging/compose.yaml) |
| `infra/monitoring` | Конфиг Prometheus + дашборд Grafana для дев-стенда метрик (CPU/RAM/RPS, latency p50/p95/p99, DB connections, DB latency, сеть, errors) — отдельный стек `wallet-monitoring`, [`infra/monitoring/compose.yaml`](infra/monitoring/compose.yaml), комментарии там же и в `infra/monitoring/prometheus.yml` |
| `infra/diagrams` | PlantUML-схемы (`components.puml`, `sequence.puml`, `sync-sequence.puml`) — см. [infra/diagrams/README.md](infra/diagrams/README.md) |

## Запуск

Локально через Docker Compose — весь стек описан в
[`compose.yaml`](compose.yaml) (комментарии в шапке файла — порядок первого
запуска, три Postgres-роли, зачем `--env-file`). Коротко:

```bash
cp infra/db/.env.example infra/db/.env
cp google-auth/.env.example google-auth/.env      # + Google OAuth креды
cp wallet-api/.env.example wallet-api/.env
cp wallet-report/.env.example wallet-report/.env
cp wallet-gateway/.env.example wallet-gateway/.env
openssl genrsa -out google-auth/jwt_signing_key.pem 2048
docker compose --env-file infra/db/.env up -d db         # сначала только db...
bash infra/db/migrate.sh auth up                          # ...накатить схему...
bash infra/db/migrate.sh wallet up
docker compose --env-file infra/db/.env up -d --build     # ...и уже потом всё остальное
```

Открыть `http://localhost:8090` (гейтвей).

Логи и метрики — два отдельных стека (свои compose-проекты, в Docker Desktop
видны как `wallet-logging` и `wallet-monitoring`), поднимаются после
приложения — метрикам нужна его сеть `wallet-net`:

```bash
docker compose -f infra/logging/compose.yaml up -d                             # OpenSearch Dashboards: http://localhost:15601
docker compose -f infra/monitoring/compose.yaml --env-file infra/db/.env up -d  # Grafana: http://localhost:13000
```

Метрики (Grafana поверх Prometheus — CPU/RAM/RPS/latency p50-p99/DB
connections/DB latency/сеть/errors, см. `infra/monitoring`): дашборд
"Wallet Transactions — Overview" заводится сам при первом старте —
`http://localhost:13000` (admin/admin, смените пароль при первом входе).
Сам Prometheus (PromQL-консоль, `/targets`) — `http://localhost:19090`.
DB-метрики (connections, латентность запросов через `pg_stat_statements`)
требуют роль `MONITORING_POSTGRES_USER`/`MONITORING_POSTGRES_PASSWORD` в
`infra/db/.env` (см. `.env.example`) — на уже существующем volume `db-data`
`init-db.sh` сам не перезапустится (см. его шапку), накатите вручную:
`docker exec -i <контейнер db> sh < infra/db/init-db.sh`, затем пересоздайте
`db` с новой командой запуска: `docker compose --env-file infra/db/.env up -d --build db`.

Для локального кластера — [infra/k8s/README.md](infra/k8s/README.md).

