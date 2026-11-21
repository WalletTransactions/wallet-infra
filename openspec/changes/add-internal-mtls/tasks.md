# Tasks

Порядок — по риску выдачи токенов (design.md, D13). Сборку C++-сервисов вести по одному (параллельная сборка вешает хост). Образы собирает CI по git-тегу сервиса. Проверки на живом стенде — на контуре test через `infra/env/up.sh test`; на prod — только после полного прогона на test.

Критерий перехода между группами 3–6 (D13): на test нет роста `invalid_client`, `invalid_grant`, `invalid_target` в `token_exchange_total` и отказов в `mcp_token_exchange_total`; в журнале нет расхождений CN и actor; привязка бота, чат через MCP и обмен `wmcp_…` проходят. Откат каждого шага — настройка и `up.sh`, без пересоздания данных.

## 1. Предусловия

- [x] 1.1 Проверить, что выкачено на prod: `/internal/token/exchange`, `/internal/mcp/token`, MCP-токены, чат (по `GET /api/versions` и метрикам `token_exchange_total` на prod). Проверка: результат записан в design.md (Open Questions → решено); если часть не выкачена, порядок уточнён. _Результат — в design.md, «Решено»: код выкачен, трафика на prod нет._
- [ ] 1.2 Убедиться, что change `add-redis-auth` (пароль и ACL на Redis) выполнен на test, а для prod — по его группе 7. Проверка: `redis-cli` без пароля из контейнера wallet-api отказывает; вход, refresh-ротация и logout на test работают.

## 2. Служебный порт google-auth и сеть `auth-internal` (без TLS)

- [x] 2.1 google-auth (репозиторий google-auth): второй слушатель (порт задаётся настройкой), на нём только `/internal/*`; `/internal/*` пока остаётся и на публичном порту. Проверка: юнит- и интеграционные тесты маршрутов; `curl` на служебный порт отдаёт `/internal/token/exchange` (401 без секрета), `/auth/*` на нём 404. _Сделано в google-auth 0.4.1 (`INTERNAL_PORT`); автотестов маршрутов нет — проверено вручную: служебный порт 401 на `/internal/token/exchange`, 404 на `/auth/*` и `/healthz`._
- [x] 2.2 `compose.yaml`: сеть `auth-internal` (google-auth, wallet-telegram, wallet-mcp, wallet-ai), служебный порт не публикуется на хост; обновить `up.sh`, если нужно создавать сеть. Проверка: `docker compose config`; из контейнера wallet-api `curl` на служебный порт google-auth не проходит. _Сделано в wallet-infra v0.5.0-rc.2; на test: из wallet-api служебный порт не отвечает, из wallet-ai — 401._
- [x] 2.3 Клиенты `/internal/*` (wallet-telegram, wallet-mcp, wallet-ai) переключить на служебный адрес по настройке (`AUTH_INTERNAL_URL`, пустое значение — прежний `AUTH_SERVICE_URL`). Проверка: на test привязка бота, обмен токена в чате и MCP-токен проходят через служебный порт (в логах google-auth виден порт). _Сделано (telegram 0.2.3, mcp 0.3.4, ai 0.2.3); на test: привязка бота и трата текстом, чат с `ledger_overview`, `token_exchange` wallet-ai→wallet-mcp→wallet-report — ok, отказов нет._
- [x] 2.4 README google-auth и `infra/env/README.md`: служебный порт и сеть. Проверка: инструкция выполнена как написано на test. _README google-auth, `infra/env/README.md`, `.env.example` клиентов._

## 3. Фундамент mTLS (режим выключен)

- [x] 3.1 В `wallet-common`: прочитать вендоренный `httplib.h` и зафиксировать в design.md API серверного конструктора с CA клиента, чтения peer-сертификата и клиентского сертификата. Проверка: в design.md ссылки на строки `httplib.h`, расхождения с D1 и D4 исправлены. _API и расхождения с D1/D4 — в design.md, «Решено»._
- [x] 3.2 `wallet-common`, модуль `net/tls`: сервер и клиент по `TLS_CERT`, `TLS_KEY`, `TLS_CA`; пусто — plain HTTP; сервер требует клиентский сертификат, клиент проверяет сертификат и имя; чтение CN вызывающего (`peer_service()`). Проверка: юнит-тест с временными ключами — handshake проходит с верным сертификатом и падает без сертификата, с чужим CA, с чужим именем; `peer_service()` возвращает CN. _`wallet-common` 0.2.1, `net/tls`; 11 тестов в `google-auth/tests/test_net_tls.cpp` (рукопожатие, без сертификата, чужой CA, чужое имя, HTTP, просроченный)._
- [x] 3.3 `infra/env/mtls.sh`: CA контура (ключ в `~/.config/wallet-secrets/<env>/mtls-ca/`, не монтируется), сертификаты ECDSA P-256 сервисов и `prometheus`, SAN `<сервис>` и `<сервис>-<env>`, срок 30 дней (пересмотреть по Open Questions), обновление при остатке менее половины, повторяем. Проверка: два запуска подряд — сертификаты не меняются; `openssl verify` проходит; сертификат test не проходит проверку CA prod. _Проверено на копии контура test: два запуска без изменений, `openssl verify`, чужой CA отклоняет, перевыпуск при остатке менее половины срока._
- [x] 3.4 `WALLET_INTERNAL_MTLS`, подключение `mtls.sh` в `up.sh` и `deploy.sh`, метка `wallet.mtls-config`, условные монтирования и переменные `TLS_*` в `compose.yaml`, healthcheck через `curl` с сертификатом, проверка метки образа `org.wallet.mtls=1` (D8). Проверка: `up.sh test` без настройки не создаёт сертификатов и не меняет `docker compose config`; образ без метки при включённом режиме — отказ с понятным сообщением. _`compose.mtls.yaml` подключается только при включённом режиме; без настройки `compose config` не меняется; образ без метки — отказ. Метку `org.wallet.mtls=1` добавляют образы по шагам 4–7._
- [x] 3.5 README (корневой и `infra/env/README.md`): режим, настройка, выпуск, откат. Проверка: инструкция выполнена с нуля на test. _`infra/env/README.md`, «mTLS внутри контура», и корневой README._

## 4. Пилот: google-auth ↔ wallet-telegram

- [x] 4.1 google-auth: `net/tls` на служебном порту, `CPPHTTPLIB_OPENSSL_SUPPORT` (уже есть), метка образа; три состояния observe / enforce-tls / enforce (D12), настройка; таблица прав по CN (D4); журнал и метрика расхождений. Проверка: юнит-тесты таблицы прав и состояний; сборка образа CI. _google-auth 0.4.2: `INTERNAL_TLS_PORT` (:8443), `INTERNAL_IDENTITY` по группам ручек, права D4, метрика `internal_identity_total`; 18 тестов, в т.ч. на реальном mTLS-сервере._
- [x] 4.2 wallet-telegram: `net/tls` для вызовов к google-auth на служебном порту, метка образа. Проверка: сборка; привязка и команда бота на test. _wallet-telegram 0.2.4: `TLS_CERT/KEY/CA` для вызовов `/internal/*`; метка `org.wallet.mtls=1` у обоих образов._
- [x] 4.3 Включить observe на test для служебного порта. Проверка: бот работает как раньше, в журнале google-auth каждый запрос бота с CN `wallet-telegram`, расхождений нет. _На test с 2026-11-21 16:20 (`WALLET_AUTH_MTLS_CLIENTS=wallet-telegram`, `WALLET_AUTH_IDENTITY=observe`): запросы бота идут на :8443, в журнале `group=telegram finding=ok cn=wallet-telegram`, расхождений нет; привязка, трата текстом и токен работают. Критерий суток наблюдения для 4.4 ещё не пройден._
- [ ] 4.4 После критерия перехода включить enforce-tls, затем enforce. Проверка: `curl` без сертификата на служебный порт — рукопожатие не проходит; `/internal/telegram/token` с сертификатом wallet-api — 403; бот работает.

## 5. Цепочка обмена: wallet-ai → google-auth → wallet-mcp → google-auth

- [x] 5.1 wallet-ai: `net/tls` для вызовов `/internal/token/exchange`, метка образа; observe на test. Проверка: чат на test отвечает, в журнале CN `wallet-ai` совпадает с actor по секрету. _wallet-ai 0.2.4 (`net/tls`, метка образа). На test с 2026-11-21 16:55 в observe: `exchange ok cn="wallet-ai"`, чат отвечает (`outcome: answer`, 3 шага)._
- [x] 5.2 wallet-mcp: `CPPHTTPLIB_OPENSSL_SUPPORT` в CMake, `net/tls` для вызовов `/internal/token/exchange` и `/internal/mcp/token`, метка образа; observe на test. Проверка: вызов инструмента MCP через `/api/mcp/` с JWT и с `wmcp_…`, цепочка `act {sub: wallet-mcp, act {sub: wallet-ai}}` в выданном JWT неизменна. _wallet-mcp 0.3.5: `CPPHTTPLIB_OPENSSL_SUPPORT` в CMake, `net/tls`, метка образа. На test в observe: `mcp-token ok cn="wallet-mcp"` (вызов по `wmcp_…`, 200), `exchange ok cn="wallet-mcp"` (аудитория wallet-report, `credential: jwt`); `token_exchange_total` — только `ok`._
- [ ] 5.3 enforce-tls и enforce для звеньев `wallet-ai` и `wallet-mcp` по одному, по критерию перехода. Проверка: сертификат wallet-mcp с секретом wallet-ai — отказ и обе идентичности в журнале; чат и MCP работают.
- [x] 5.4 README сервисов (telegram, ai, mcp, google-auth): переменные `TLS_*`, `AUTH_INTERNAL_URL`, состояния D12. Проверка: пример запуска из README работает локально. _README wallet-ai, wallet-mcp, wallet-telegram, google-auth и `.env.example` описывают `TLS_*`, `AUTH_INTERNAL_URL` и режимы._

## 6. Закрыть остаточные пути `/internal/*`

- [x] 6.1 Убрать `/internal/*` с публичного порта google-auth. Проверка: `curl http://google-auth:8080/internal/token/exchange` — 404, `/auth/*` и JWKS работают, весь критичный путь (бот, чат, MCP) на test проходит. _google-auth 0.4.3: `INTERNAL_ON_PUBLIC_PORT=false` (по умолчанию true, prod не затронут). На test с 2026-11-21 17:40 (`WALLET_AUTH_INTERNAL_PUBLIC=false`, v0.5.0-rc.9): `/internal/*` на :8080 — 404, `/auth/*`, JWKS, healthz, metrics работают; MCP и обмен токена проходят. Выполнено по решению владельца без суток наблюдения._
- [x] 6.2 Выключить переходный приём plain на служебном порту. Проверка: `curl http://…` на служебный порт не отвечает; все клиенты работают. _`WALLET_AUTH_INTERNAL_PLAIN=false` (v0.5.0-rc.10): `INTERNAL_PORT=0`, :8081 не слушается (отказ соединения), на :8443 каждый клиент проходит с сертификатом и не проходит без; ошибок в клиентах нет. Требует всех трёх клиентов на mTLS (проверяет mtls.sh)._

## 7. Гейтвей и остальные серверы

- [ ] 7.1 Пул клиентов с keep-alive и одной повторной попыткой в `wallet-common` (D6). Проверка: тест с сервером, закрывающим соединение по таймауту, — запрос проходит; число рукопожатий меньше числа запросов.
- [ ] 7.2 wallet-api: `CPPHTTPLIB_OPENSSL_SUPPORT`, `net/tls`, метка образа. Проверка: сборка; CRUD через гейтвей на test.
- [ ] 7.3 wallet-report: то же. Проверка: отчёт через гейтвей и из wallet-ai.
- [ ] 7.4 wallet-docs (при включённом профиле): то же. Проверка: вопрос по спекам отвечает, индекс заливается.
- [ ] 7.5 wallet-web (nginx): серверный mTLS (`ssl_verify_client on`), healthcheck по loopback-блоку. Проверка: страница открывается через гейтвей; прямой запрос без сертификата — отказ.
- [ ] 7.6 wallet-gateway: клиентская сторона на mTLS через пул (D6), входной порт без изменений, служебный mTLS-порт или mTLS на `/metrics` (D9), `CPPHTTPLIB_OPENSSL_SUPPORT` в CMake. Проверка: пользовательский запрос через вход контура проходит, SSE-поток чата идёт, loadtest до/после — p95 в допуске, `mem_limit` не превышен.
- [ ] 7.7 `jwks.cpp` и `reports_client.cpp` в `wallet-common` на `net/tls` (JWKS остаётся одноразовым клиентом). Проверка: тесты потребителей зелёные в обоих режимах.

## 8. Prometheus и healthcheck

- [ ] 8.1 `infra/monitoring/prometheus.yml`: генерация для контура — `https` и `tls_config` при включённом режиме, `http` при выключенном, метки `job`, `env` прежние. Проверка: все цели test up по HTTPS, prod по HTTP, `up{job="wallet-api"}` возвращает две серии.
- [ ] 8.2 Сертификат одного контура не открывает цели другого. Проверка: опрос цели prod сертификатом test — down.
- [ ] 8.3 Healthcheck всех сервисов через `curl` с собственным сертификатом (проверить, что 3.4 полностью покрыл wallet-web и гейтвей). Проверка: все контейнеры healthy; `/healthz` из другого контейнера без сертификата — рукопожатие не проходит.

## 9. Postgres и TLS до Redis

- [ ] 9.1 Postgres: `ssl=on`, сертификат сервера, `pg_hba` (`hostssl`, `hostnossl reject`, `clientcert=verify-ca` для ролей сервисов), правка `infra/db/init-db.sh` и `compose.yaml`. Проверка: подключение без TLS отклонено; роль сервиса без сертификата отклонена; DBeaver с `sslmode=require` под ролью migrator работает.
- [ ] 9.2 `DATABASE_URL` сервисов: `sslmode=verify-full`, `sslrootcert`, `sslcert`, `sslkey`; `migrate.sh`, `backup.sh`, `test-refresh.sh` по TLS. Проверка: миграция одной базы и дамп прошли на test.
- [ ] 9.3 Redis: проверить клиент google-auth на поддержку TLS; включить `tls-port` и `tls-auth-clients` либо зафиксировать исключение в README режима. Проверка: вход, refresh, logout на test работают; результат записан в README.
- [ ] 9.4 `infra/db/README.md`. Проверка: инструкция по подключению администратора выполнена как написано.

## 10. Включение на test целиком

- [ ] 10.1 `WALLET_INTERNAL_MTLS=true` на test для всего контура. Проверка: `up.sh test` без ошибок, все healthcheck зелёные, smoke выката проходит.
- [ ] 10.2 Loadtest до (режим выключен) и после (включён), результаты сохранить. Проверка: p95 гейтвея в пределах допуска из спеки, ни один сервис не превысил `mem_limit` (`docker stats`, OOM в `journalctl`).
- [ ] 10.3 Откат: выключить режим, `up.sh test`. Проверка: сервисы на HTTP, пользователи остались в системе, данные на месте, токены обмена выдаются.
- [ ] 10.4 Обновление сертификатов: подменить дату так, чтобы осталось менее половины срока, `up.sh test`. Проверка: сертификаты перевыпущены, пересозданы только нужные контейнеры.

## 11. Prod

- [ ] 11.1 Выкатить версии сервисов с поддержкой TLS на prod релизными тегами по одному, режим выключен. Проверка: prod работает как раньше, метки образов `org.wallet.mtls=1`.
- [ ] 11.2 Повторить на prod порядок групп 2, 4, 5, 6 с теми же критериями перехода, затем 7–9. Проверка: после каждой группы — привязка бота, чат через MCP, обмен `wmcp_…`, вход и refresh; метрики prod up.
- [ ] 11.3 Записать итог замера и решения в `design.md` (Open Questions → решено). Проверка: открытых вопросов в design.md не осталось.

## Workflow follow-up

- Отдельный change после этого: client assertion JWT вместо `X-Service-Secret` (`TODO_service_auth_tls.md`, п. 1). После его выкатки идентичность на критичном пути держится только на сертификате и подписи.
- Архивировать change после выката на prod и проверки, что режим работает.
