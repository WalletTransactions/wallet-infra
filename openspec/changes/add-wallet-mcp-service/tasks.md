# Tasks

## 1. Сервис в контуре

- [x] 1.1 `compose.yaml`: сервис `wallet-mcp` (образ `ghcr.io/wallettransactions/wallet-mcp:${WALLET_MCP_TAG:?}`, `<<: *service`, `mem_limit: 64m`, `environment` с `HOST=0.0.0.0`, `PORT=8088`, `AUTH_SERVICE_URL=http://google-auth:8080`, `WALLET_REPORT_URL=http://wallet-report:8084`, без `env_file`, `depends_on` google-auth и wallet-report `service_healthy`, healthcheck `curl -f http://127.0.0.1:8088/healthz`, alias `wallet-mcp-${WALLET_ENV}`, без `ports`) и комментарий над ним. Проверка: `bash infra/env/up.sh test` с `WALLET_MCP_TAG` в `tags.env` поднимает контур, `docker ps` показывает `wallet-test-wallet-mcp-1` healthy, а порт 8088 на хосте не слушается (`ss -ltn`).
  Выкат 2026-11-02: `WALLET_MCP_TAG=0.1.0-rc.1` в `tags.env` test, затем тег `v0.1.0-rc.5` → `env-release-watch` → `up.sh test` (history: `wallet-infra v0.1.0-rc.5 … ok`); `wallet-test-wallet-mcp-1` healthy, `/version` — 0.1.0 / 4038c3e6; `ss -ltn` — порт 8088 на хосте не слушается.
  Код — 43ef45c. Статически: `docker compose config` с фиктивными переменными для prod и test проходит, у `wallet-mcp` нет `ports` и `env_file`, alias `wallet-mcp-<env>`; без `WALLET_MCP_TAG` config падает с `required variable WALLET_MCP_TAG is missing a value`.
- [x] 1.2 Гейтвею — `WALLET_MCP_URL: http://wallet-mcp:8088` в `environment`, **без** `depends_on` на wallet-mcp (design, решение 2). Проверка: `docker stop wallet-test-wallet-mcp-1` → `curl -si -X POST http://localhost:8091/api/mcp/` даёт `502`, а `curl -s http://localhost:8091/healthz` — `200`. — Код — 43ef45c; проверено 2026-11-02 на test: 502 при остановленном wallet-mcp, /healthz 200 (WalletTransactions/wallet-gateway#3)
  Код — 43ef45c; проверка при выкате wallet-mcp в test. Статически: в `config` у гейтвея есть `WALLET_MCP_URL`, в `depends_on` гейтвея wallet-mcp нет.
- [x] 1.3 Корневой `README.md`: строка `wallet-mcp` в таблице сервисов (MCP-сервер `/api/mcp/*`, только чтение, без БД). `infra/env/README.md`: `WALLET_MCP_TAG` в примере `tags.env` «Первого запуска» и абзац «Новый сервис в контуре» (тег в `tags.env` до выката тега wallet-infra, сироты при откате). Проверка: шаги README воспроизводятся на test.
  Сверено 2026-11-02: строка wallet-mcp в таблице сервисов корневого README, WALLET_MCP_TAG и раздел «Новый сервис в контуре» в infra/env/README.md — по ним же шёл выкат в test (v0.1.0-rc.5).
  Код — 1c065b7; проверка при выкате wallet-mcp в test.
- [ ] 1.4 (добавлено при реализации) `infra/logging/fluent-bit.conf`: `wallet-mcp` в whitelist контейнеров `CONTAINER_NAME`, иначе его логи не попадают в OpenSearch. Проверка: после выката в test в OpenSearch Dashboards есть записи `container_name: wallet-test-wallet-mcp-1` с `env: test`.
  Код — e3ca996; проверка при выкате wallet-mcp в test. Статически: `fluent-bit --dry-run` (образ 3.1) — `configuration test is successful`, регулярка пропускает `wallet-{prod,test}-wallet-mcp-1`.

## 2. Выкат и smoke

- [ ] 2.1 `infra/env/lib.sh`: `WALLET_SERVICE_PORT[wallet-mcp]=8088`. Проверка: `bash infra/env/release-watch.sh` перечисляет `wallet-mcp` среди сервисов (при наличии rc-тега в ghcr — строка `test wallet-mcp <тег>`), `deploy.sh test nope 1.0.0` по-прежнему падает на «неизвестный сервис».
  Код — 266a028; проверка при выкате wallet-mcp в test. Статически: `bash -n`; после `source lib.sh` в ключах карты есть `wallet-mcp`, `tag_var wallet-mcp` → `WALLET_MCP_TAG`. `release-watch.sh` и `deploy.sh` не запускались (запрет на действия с контурами).
- [ ] 2.2 `infra/env/deploy.sh`: `smoke_extra <сервис>`; для `wallet-mcp` — `env_compose exec -T wallet-mcp curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8088/api/mcp/` ожидает `401`, иное — провал smoke с сообщением `smoke: wallet-mcp без токена ответил <код>, ожидался 401`. Вызов — после `smoke_version`, у прочих сервисов функция ничего не делает. Без печати секретов. Проверка: выкат rc-тега wallet-mcp в test проходит; выкат с подменённым образом, отвечающим `200` (проверка на локальном теге), откатывается с этим сообщением.
  Код — 266a028; проверка при выкате wallet-mcp в test. Запрос несёт тело `initialize` (спека `mcp-access`, «Без заголовка»). Статически: `bash -n`; `smoke_extra` прогнан с подменённым `env_compose`: `401` проходит, `200`/`502`/`000`/нет ответа — провал с этим сообщением, у других сервисов `env_compose` не вызывается.
- [ ] 2.3 BuildPlatform (вне git): `wallet-mcp` в `choices` параметра `SERVICE` в `jobs/env-deploy/Jenkinsfile` и `jobs/env-rollback/Jenkinsfile`, в списке `SERVICE` в `jenkins/README.md`. Проверка: в Jenkins `env-deploy` с `SERVICE=wallet-mcp`, `ENV=test` и rc-тегом выкатывает сервис, в `history` контура — строка `ok`.
  Код — правка файлов BuildPlatform (вне git): `jobs/env-deploy/Jenkinsfile`, `jobs/env-rollback/Jenkinsfile`, `jenkins/README.md`; проверка при выкате wallet-mcp в test. Новый choice Jenkins покажет после первого прогона job'а с обновлённым Jenkinsfile.

## 3. Мониторинг

- [ ] 3.1 `infra/monitoring/prometheus.yml`: `job_name: wallet-mcp`, цели `wallet-mcp-prod:8088` (`env: prod`) и `wallet-mcp-test:8088` (`env: test`). Проверка: в Prometheus Targets обе цели `UP`, `up{job="wallet-mcp"}` отдаёт 1 для каждого `env`.
  Код — 78237b2; проверка при выкате wallet-mcp в test (и в prod). Статически: `promtool check config` (prom/prometheus:v2.53.0) — SUCCESS. Стек метрик не перезапускался.
- [ ] 3.2 Grafana `wallet-overview.json`: строка «wallet-mcp» — вызовы инструментов по имени и исходу, обмены токена по результату, `up`, RSS контейнера. Имена метрик — по `service-endpoints` wallet-mcp. Проверка: после пары `tools/call` на test панели показывают ненулевые значения с переключателем `env`.
  Код — 78237b2; проверка при выкате wallet-mcp в test. Панели: вызовы по `tool`/`result`, обмен токена и кеш JWT, p95 инструмента, `up`, RSS (по `image`, переключатель `env` на него не действует — cAdvisor). Статически: `jq` — JSON валиден, id панелей уникальны; все выражения панелей (с `$env` → `prod`) проходят `promtool check rules`.

## 4. Сквозная проверка

- [ ] 4.1 На test после выката всей цепочки (google-auth, wallet-api, wallet-report, wallet-mcp, гейтвей, веб): выпустить токен в вебе, выполнить `initialize` и `tools/call list_wallets` через `http://localhost:8091/api/mcp/`. Проверка: ответ с кошельками; `docker stats` — RSS wallet-mcp в пределах 64 МБ; в логах выката (`history`, вывод Jenkins) нет значений токенов и секретов. — Тест: [wallet-infra#5](https://github.com/WalletTransactions/wallet-infra/issues/5)
  Кода нет; проверка при выкате всей цепочки в test.

## Workflow follow-up

- В prod — тем же порядком после проверки в test: `WALLET_MCP_TAG` финальным тегом в `tags.env` prod, затем финальный тег wallet-infra.
- Архивировать change после выката в prod; если `add-prod-test-environments` к тому времени не архивирован — после него.
