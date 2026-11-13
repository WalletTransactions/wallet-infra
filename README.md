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
| `wallet-mcp` | MCP-сервер `/api/mcp/*` для LM Studio и других MCP-клиентов: вопросы о тратах инструментами поверх wallet-report. Только чтение, без БД; доступ по MCP-токену из веб-кабинета | [wallet-mcp/README.md](https://github.com/WalletTransactions/wallet-mcp/blob/main/README.md) | [openapi.yaml](https://github.com/WalletTransactions/wallet-mcp/blob/main/openapi.yaml) |
| `wallet-docs` | **Необязательный модуль** (профиль `docs`): справка `/api/docs/*` по OpenSpec-спекам репозиториев — гибридный поиск (полнотекст + pgvector) и ответ LLM со ссылками. Своя база `docs`, индекс не бэкапится; без модуля гейтвей отвечает 404, а клиенты прячут раздел | [wallet-docs/README.md](https://github.com/WalletTransactions/wallet-docs/blob/main/README.md) | [openapi.yaml](https://github.com/WalletTransactions/wallet-docs/blob/main/openapi.yaml) |
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
сервисов — краткая ссылка туда же). Сводка версий всех сервисов контура —
`GET /api/versions` гейтвея (только роль `admin`, бейдж версии в углу веба);
бота гейтвей опрашивает по `WALLET_TELEGRAM_URL` из `compose.yaml`, не
публикуя его.

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
| `infra/env` | Контуры prod и test: настройки (`prod.env`, `test.env`), `up.sh`, `migrate.sh`, выкат — см. [infra/env/README.md](infra/env/README.md) |
| `infra/db` | Конфиг инстанса Postgres: роли, `init-db.sh`, миграции базы `perf` — см. [infra/db/README.md](infra/db/README.md). `perf` — история прогонов нагрузочного контура (`test_run`/`test_result`, читается дашбордом Grafana "Perf History", см. `wallet-report/loadtest/README.md`) |
| `infra/logging` | Конфиг Fluent Bit и сохранённые объекты OpenSearch Dashboards для дев-стенда логов — отдельный стек `wallet-logging`, [`infra/logging/compose.yaml`](infra/logging/compose.yaml) |
| `infra/monitoring` | Prometheus + Grafana для обоих контуров (метка и переменная `env`), запуск — `infra/monitoring/up.sh`; метрики (CPU/RAM/RPS, latency p50/p95/p99, DB connections, DB latency, сеть, errors) — отдельный стек `wallet-monitoring`, [`infra/monitoring/compose.yaml`](infra/monitoring/compose.yaml), комментарии там же и в `infra/monitoring/prometheus.yml` |
| `infra/diagrams` | PlantUML-схемы (`components.puml`, `sequence.puml`, `sync-sequence.puml`) — см. [infra/diagrams/README.md](infra/diagrams/README.md) |

## Запуск

Стек работает в двух постоянных контурах на одной машине, оба — compose-проекты
docker по одному [`compose.yaml`](compose.yaml):

| Контур | Проект | Адрес | Что катится |
| --- | --- | --- | --- |
| **prod** | `wallet-prod` | `http://<хост>:8090` | git-тег сервиса `vX.Y.Z` (тот же образ, что прошёл test) |
| **test** | `wallet-test` | `http://<хост>:8091` | git-тег сервиса `vX.Y.Z-rc.N` |

Образы собирает CI в `ghcr.io/wallettransactions/<сервис>`; на хосте ничего не
собирается, `docker compose up --build` из рабочей папки больше не работает.
Выкат по тегам делает Jenkins (`env-release-watch` → `env-deploy`), руками —
`infra/env/up.sh <prod|test>`. Первый запуск, секреты, миграции, откат и
перезаливка test — [infra/env/README.md](infra/env/README.md).

Снаружи открыт только гейтвей контура; Postgres — только на `127.0.0.1` этой машины
(prod `:15555`, test `:15432`); redis — `docker exec`
(см. [infra/db/README.md](infra/db/README.md), «Подключение к базе контура»).

Логи и метрики — общие на оба контура стеки `wallet-logging` и
`wallet-monitoring` (контур различается полем/меткой `env`). По умолчанию
оба выключены (`restart: "no"`, после перезагрузки не поднимаются) и
запускаются вручную, когда нужны; контуры от них не зависят — логи всё
время пишутся в journald, Fluent Bit при запуске дочитывает пропущенное:

```bash
docker compose -f infra/logging/compose.yaml up -d      # OpenSearch Dashboards: http://localhost:15601
bash infra/monitoring/up.sh                             # Grafana: http://localhost:13000, Prometheus: http://localhost:19090
```

Дашборд Grafana "Wallet Transactions — Overview" заводится сам при первом
старте. Логин `admin`, пароль — в `~/.config/wallet-secrets/monitoring.env`
(`GRAFANA_ADMIN_PASSWORD`; нет файла — `up.sh` создаст его со случайным
паролем). Поменять пароль — правка этого файла и повторный `up.sh`.

