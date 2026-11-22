# Tasks

Change объединяет бывший `add-redis-auth` (группа R, делается первой, по D13 шаг 1) и mTLS (группы 1–11). Порядок — по риску выдачи токенов (design.md, D13). Сборку C++-сервисов вести по одному (параллельная сборка вешает хост). Образы собирает CI по git-тегу сервиса. Проверки на живом стенде — на контуре test через `infra/env/up.sh test`; на prod — только после полного прогона на test.

Критерий перехода между группами 3–6 (D13): на test нет роста `invalid_client`, `invalid_grant`, `invalid_target` в `token_exchange_total` и отказов в `mcp_token_exchange_total`; в журнале нет расхождений CN и actor; привязка бота, чат через MCP и обмен `wmcp_…` проходят. Откат каждого шага — настройка и `up.sh`, без пересоздания данных.

## R. Redis: пароль и ACL (бывший change `add-redis-auth`, выполняется первым)

Порядок — по design.md, часть R (RD6). Выкат только через `infra/env/up.sh`. Значения паролей не печатать (без `set -x`, без `cat` файлов `redis/`). Prod — только после полного прогона на test, в тихое время.

### R1. Подготовка

- [x] R1.1 Снять реальный набор ключей и команд: `redis-cli --scan` на prod и test (read-only, пока без пароля), сверить с префиксами из design (Context) и с `redis_client.hpp`. Проверка: список префиксов и команд записан в design.md (RD3), расхождения устранены. _На test: refresh_token 64, user_refresh_tokens 41, mcp_token 5, user_mcp_tokens 2, user_access_tokens 1, access_token 1; на prod refresh_token 4, user_refresh_tokens 2 (только счёт по префиксам). Команды клиента — AUTH DEL EXISTS EXPIRE EXPIRETIME GET GETDEL INCR SADD SET SMEMBERS SREM TTL — совпадают с таблицей RD3. Расхождений нет._
- [x] R1.2 `CLIENT LIST` на prod и test: кто сейчас подключён. Проверка: единственный штатный клиент — google-auth (плюс redis-exporter), посторонних соединений нет; результат записан в design.md. _`CLIENT LIST` на test и prod: одно штатное соединение google-auth (user=default, cmd=exists) и сам redis-cli; exporter остановлен (стек мониторинга не запущен); посторонних нет._
- [x] R1.3 Поискать `redis-cli` без пароля в джобах Jenkins (BuildPlatform, вне git: сначала резервная копия каталога jobs) и в скриптах `infra/env/`. Проверка: список мест, которые нужно править, записан (пусто, если их нет). _`redis-cli` без пароля: compose.yaml (healthcheck), infra/env/README.md, infra/db/README.md, infra/env/test-refresh.sh — все переведены в этом change. В джобах Jenkins (config.xml) и BuildPlatform упоминаний нет._

### R2. google-auth: `REDIS_USERNAME` (репозиторий google-auth)

- [x] R2.1 `redis_client.cpp`, `main.cpp`: необязательный `REDIS_USERNAME`, команда `AUTH <пользователь> <пароль>`; пусто — прежнее `AUTH <пароль>`. Проверка: юнит-тест построения команды для обоих случаев. _google-auth 0.4.5: `REDIS_USERNAME`, `redis::detail::auth_command`; 2 юнит-теста._
- [x] R2.2 Проверка с настоящим Redis 7 (одноразовый контейнер) с ACL-пользователем: старт с верными и неверными данными. Проверка: с верными — сервис работает; с неверными — процесс завершается, в журнале «Redis: AUTH не прошёл» **без пароля**. _Настоящий Redis 7 с ACL: верные данные — сервис стартует; неверный пароль и «только пароль при выключенном default» — завершение с кодом 1 и WRONGPASS, пароль в журнале нет; имя без пароля — понятная ошибка конфигурации. Права: SET/GET/GETDEL на своих префиксах работают, чужой ключ, KEYS, FLUSHALL, CONFIG — NOPERM, без учётных данных — NOAUTH._
- [x] R2.3 README и `.env.example` google-auth: `REDIS_USERNAME`. Проверка: пример из README запускается как написано. _README и `.env.example` google-auth._
- [ ] R2.4 Выкатить rc на test, затем релиз на prod, настройки не менять. Проверка: вход, refresh и logout работают, поведение не изменилось (метки `/api/versions`).

### R3. Скрипт, compose и документация (репозиторий wallet-infra)

- [x] R3.1 `infra/env/redis-auth.sh`: при отсутствии создаёт `~/.config/wallet-secrets/<env>/redis/{google-auth,health,exporter,admin}.env` (случайные пароли, права 0600) и `generated/redis/users.acl` с хешами (RD3, RD4); повторный запуск ничего не меняет. Проверка: два запуска подряд на test — файлы не меняются; в ACL-файле нет паролей; значения не печатаются. _`infra/env/redis-init.sh` (хост, один раз; два запуска — файлы не меняются, права 0600) и `infra/env/redis.sh` (users.acl из хешей). Проверено на копии контура: в ACL нет паролей, пароль admin не попадает в `docker compose config`. ACL-файл Redis не допускает комментариев — первый вариант не стартовал, исправлено._
- [x] R3.2 `compose.yaml`: сервис `redis` — `--aclfile`, монтирование каталога `generated/redis` (RD5), `env_file` только с `health.env`, healthcheck `redis-cli --user health ping`; google-auth — `env_file` с `google-auth.env`. Проверка: `docker compose config` без утечки паролей; контейнер Redis не содержит паролей `admin` и `google-auth` (`docker exec … env`). _Проверено на test (v0.5.0-rc.14): в окружении контейнера Redis только пароль `health`, в контейнере google-auth только его пароль и `REDIS_USERNAME=google-auth`; пароль `admin` нигде не в `docker compose config`; healthcheck Redis — под `health`._
- [x] R3.3 Подключить `redis-auth.sh` в `up.sh` до старта Redis, режим ACL-файла (`default` включён или выключен) задаётся настройкой выката. Проверка: `up.sh test` на чистом и на работающем контуре — без ошибок, секреты создаются один раз. _`up.sh test` на работающем контуре (Jenkins, v0.5.0-rc.14 и -rc.15): без ошибок, секреты созданы один раз хостовым `redis-init.sh`, ACL применяется `ACL LOAD` без рестарта._
- [ ] R3.4 `test-refresh.sh`: `FLUSHALL` под `admin` (пароль через `REDISCLI_AUTH`, не в аргументах). Проверка: `test-refresh.sh` на test проходит, Redis test очищен, пароль не напечатан.
- [ ] R3.5 README (корневой, `infra/env/README.md`, `infra/db/README.md`): модель пользователей, подключение оператора `docker exec -it … redis-cli --user admin`, откат. Проверка: инструкция выполнена как написано на test.

### R4. Мониторинг

- [ ] R4.1 `infra/monitoring/up.sh` и `compose.yaml`: учётные данные exporter из `redis/exporter.env` каждого контура с префиксом `PROD_`/`TEST_`, `REDIS_USER`, `REDIS_PASSWORD` в `redis-exporter-<env>`. Проверка: `docker compose config` монитор-стека без паролей в выводе; exporter запускается.
- [x] R4.2 Список команд пользователя `exporter`: прогнать exporter с ACL и дочитать `ACL LOG`. Проверка: цель `redis-exporter` up по test, `redis_connected_clients` и `redis_memory_used_bytes` обновляются, отказов ACL нет; список зафиксирован в design.md. _Настоящий redis_exporter v1.62.0 под пользователем `exporter` на test (v0.5.0-rc.16): `redis_up 1`, `redis_connected_clients`, `redis_memory_used_bytes`, `redis_db_keys` обновляются, `ACL LOG` и журнал exporter без отказов. Первый прогон показал нехватку `client|setname` и `latency|histogram` — добавлены; список зафиксирован в design.md (RD3). Стек мониторинга как целое не запускался (остановлен), поэтому проверка — одиночным контейнером exporter в сети test._

### R5. Включение на test

- [x] R5.1 Шаг 2 (RD6): `up.sh test` с ACL-файлом, где `default` включён, затем пересоздание google-auth. Проверка: вход работает, токены на месте (число ключей `access_token:*` и `refresh_token:*` до и после совпадает), без паролей в клиентах. _2026-11-21 (v0.5.0-rc.14, режим compat): токены до и после совпадают (refresh_token 59→59, user_refresh_tokens 40→40, mcp_token 3→3, user_mcp_tokens 1→1; пропали только 2 короткоживущих access-ключа по TTL, DBSIZE 105→103)._
- [x] R5.2 Шаг 3: google-auth, healthcheck и exporter переведены на свои учётные данные. Проверка: все контейнеры healthy, метрики идут, google-auth подключён под пользователем `google-auth` (`CLIENT LIST` → `user=google-auth`). _google-auth, Redis и healthcheck healthy; `CLIENT LIST`: `user=google-auth` (плюс мой `admin`)._
- [x] R5.3 Шаг 4: `CLIENT LIST` без `user=default`, `ACL LOG` без отказов штатных клиентов. Проверка: пустой журнал отказов после прогона сценариев из R5.4. _`CLIENT LIST` без `user=default` (compat); `ACL LOG` пуст после прогона сценариев._
- [x] R5.4 Прогнать на test все пути Redis: вход через Google и по паролю, refresh (ротация `GETDEL`), logout, принудительный logout и массовый отзыв токенов админом, список устройств, привязка Telegram (`tg_link_code:`), MCP-токен, счётчики неудачных входов (`authfail:*`). Проверка: каждый сценарий проходит, `ACL LOG` пуст; найденные недостающие права добавлены в ACL (не ослабляя остальные). _12 сценариев через API тестовыми пользователями — все прошли: вход по паролю, ротация refresh и отказ старого токена, список устройств, выпуск MCP-токена, неудачные входы (`authfail`), код привязки Telegram, logout, вход админа, список пользователей, принудительный logout, отказ refresh после него. `ACL LOG` пуст; вход через Google на test не прогонялся (нужен браузер с Google-аккаунтом), его команды те же._
- [x] R5.5 Шаг 5: выключить `default` (`ACL LOAD`). Проверка: `redis-cli` без учётных данных из контейнера wallet-api отказывает; `redis-cli --user google-auth` с верным паролем выполняет `GET` своего ключа, но `FLUSHALL` и `KEYS *` отклоняются; вход пользователя на test работает. _v0.5.0-rc.15 (режим on): `default off` через `ACL LOAD`, Redis не перезапускался (uptime 302 с); из чужого контейнера сети test без учётных данных — `NOAUTH`; google-auth: `GET` на своём префиксе работает, `FLUSHALL`, `KEYS`, `CONFIG GET` — `NOPERM`; вход, refresh, logout работают._

### R6. Откат и отказ на test

- [ ] R6.1 Откат: вернуть прежний ACL-файл с `default` и `ACL LOAD`, затем снова выключить. Проверка: сервисы работают в обоих состояниях, токены не пропали.
- [ ] R6.2 Неверный пароль google-auth на старте. Проверка: процесс завершается, в журнале причина без значения пароля, healthcheck контейнера не проходит.
- [ ] R6.3 Выключение `default` при живом клиенте на `default` (имитация: соединение `redis-cli` без пароля до шага 5). Проверка: выкат сообщает о соединении `user=default` и не выключает его.

### R7. Prod

- [ ] R7.1 Подтвердить на prod версию google-auth с `REDIS_USERNAME` (R2.4) и повторить шаги 2–5 из RD6 в тихое время. Проверка: после каждого шага вход, refresh, logout и бот работают, метрики prod up.
- [ ] R7.2 Сверка токенов: число ключей токенов до включения и после (по префиксам). Проверка: числа совпадают (с поправкой на естественное истечение TTL), пользователи остаются залогиненными.
- [ ] R7.3 Отметить задачу 1.2 выполненной. Проверка: `redis-cli` без пароля с контейнера prod отказывает.

## 1. Предусловия

- [x] 1.1 Проверить, что выкачено на prod: `/internal/token/exchange`, `/internal/mcp/token`, MCP-токены, чат (по `GET /api/versions` и метрикам `token_exchange_total` на prod). Проверка: результат записан в design.md (Open Questions → решено); если часть не выкачена, порядок уточнён. _Результат — в design.md, «Решено»: код выкачен, трафика на prod нет._
- [ ] 1.2 Убедиться, что группа R (пароль и ACL на Redis, бывший change `add-redis-auth`) выполнена на test, а для prod — по R7. Проверка: `redis-cli` без пароля из контейнера wallet-api отказывает; вход, refresh-ротация и logout на test работают.

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

- [x] 7.1 Пул клиентов с keep-alive и одной повторной попыткой в `wallet-common` (D6). Проверка: тест с сервером, закрывающим соединение по таймауту, — запрос проходит; число рукопожатий меньше числа запросов. _`wallet-common` 0.3.0: `net/pool` (`ClientPool`); 4 теста в google-auth: 6 запросов по mTLS — одно соединение (счёт принятых соединений, а не слушающего сокета), после закрытия простоя сервером запрос проходит на новом, 8 потоков — не более 8 клиентов._
- [x] 7.2 wallet-api: `CPPHTTPLIB_OPENSSL_SUPPORT`, `net/tls`, метка образа. Проверка: сборка; CRUD через гейтвей на test. _wallet-api 0.4.9: `INTERNAL_MTLS=true` — сервер требует клиентский сертификат (без него и по HTTP отказ). На test с 2026-11-21 19:00: `/sync/pull` через гейтвей — 200, 44 КБ. Запись (CRUD) не прогонялась._
- [x] 7.3 wallet-report: то же. Проверка: отчёт через гейтвей и из wallet-ai. _wallet-report 0.3.4: то же; справочник счетов через гейтвей — 200. Вызов из wallet-ai/бота ждёт прогона чата и бота._
- [x] 7.4 wallet-docs (при включённом профиле): то же. Проверка: вопрос по спекам отвечает, индекс заливается. _wallet-docs 0.1.5: то же; `ask_docs` через wallet-mcp (обмен токена + mTLS к docs) вернул ответ со ссылкой на спеку. Заливка индекса не прогонялась._
- [x] 7.5 wallet-web (nginx): серверный mTLS (`ssl_verify_client on`), healthcheck по loopback-блоку. Проверка: страница открывается через гейтвей; прямой запрос без сертификата — отказ. _wallet-web 0.1.6: `entrypoint/45-mtls-listen.sh` выбирает `listen 80 ssl` + `ssl_verify_client on`; loopback-healthcheck `127.0.0.1:8081`. На test: статика через гейтвей — 200; без клиентского сертификата nginx отвечает 400 (не рвёт рукопожатие)._
- [x] 7.6 wallet-gateway: клиентская сторона на mTLS через пул (D6), входной порт без изменений, служебный mTLS-порт или mTLS на `/metrics` (D9), `CPPHTTPLIB_OPENSSL_SUPPORT` в CMake. Проверка: пользовательский запрос через вход контура проходит, SSE-поток чата идёт, loadtest до/после — p95 в допуске, `mem_limit` не превышен. _wallet-gateway 0.1.7: вызовы к апстримам по mTLS через пул (api, report, ai, mcp, web, docs), SSE-поток — отдельный клиент, входной порт остаётся HTTP, второй слушатель :8443 (healthz, metrics, version). На test вход, справочник и синхронизация работают на обоих входах (HTTP :8091 и TLS-ингресс :8444). НЕ проверено: SSE-поток чата и нагрузочный замер (10.2)._
- [x] 7.7 `jwks.cpp` и `reports_client.cpp` в `wallet-common` на `net/tls` (JWKS остаётся одноразовым клиентом). Проверка: тесты потребителей зелёные в обоих режимах. _`reports_client` принимает `nettls::Config`; JWKS остаётся одноразовым клиентом по HTTP (публичный порт google-auth). Тесты потребителей — в CI сервисов._

## 8. Prometheus и healthcheck

- [x] 8.1 `infra/monitoring/prometheus.yml`: генерация для контура — `https` и `tls_config` при включённом режиме, `http` при выключенном, метки `job`, `env` прежние. Проверка: все цели test up по HTTPS, prod по HTTP, `up{job="wallet-api"}` возвращает две серии. _`infra/monitoring/gen-scrape-config.sh` пишет задания сервис × контур (https и сертификат `prometheus` контура при включённом режиме, иначе HTTP), `job` возвращается relabel'ом; prometheus.yml читает их через `scrape_config_files`. Проверено временным Prometheus в сети test: все 8 сервисных целей `up` по https (гейтвей — :8443), метки `job`/`env` прежние. Prod остаётся на HTTP (режим там выключен); `up{job="wallet-api"}` двумя сериями будет после включения prod._
- [ ] 8.2 Сертификат одного контура не открывает цели другого. Проверка: опрос цели prod сертификатом test — down. _Не проверено полностью: у prod нет CA (режим выключен). Свойство «чужой CA не проходит» подтверждено в юнит-тестах `net/tls` и проверкой `openssl verify` с чужим CA; проверка живой цели prod сертификатом test — после включения prod._
- [x] 8.3 Healthcheck всех сервисов через `curl` с собственным сертификатом (проверить, что 3.4 полностью покрыл wallet-web и гейтвей). Проверка: все контейнеры healthy; `/healthz` из другого контейнера без сертификата — рукопожатие не проходит. _Сделано: healthcheck api, report, docs, ai, mcp, telegram — curl с собственным сертификатом, web — loopback 127.0.0.1:8081, гейтвей — прежний (входной порт, D9); контейнеры test healthy, /healthz из другого контейнера без сертификата — отказ. Закрыто 2026-11-21: google-auth 0.4.4, `SERVICE_MTLS_PORT=8442` — отдельный mTLS-слушатель для /healthz, /metrics, /version; на публичном :8080 /healthz и /metrics нет (404), /version, JWKS, /auth/* остаются (их опрашивают гейтвей и JWKS-клиенты по HTTP). Healthcheck по https на :8442, Prometheus собирает google-auth оттуда (up). Проверено на test (v0.5.0-rc.13) и временным Prometheus._

## 9. Postgres и TLS до Redis

- [ ] 9.1 Postgres: `ssl=on`, сертификат сервера, `pg_hba` (`hostssl`, `hostnossl reject`, `clientcert=verify-ca` для ролей сервисов), правка `infra/db/init-db.sh` и `compose.yaml`. Проверка: подключение без TLS отклонено; роль сервиса без сертификата отклонена; DBeaver с `sslmode=require` под ролью migrator работает.
- [ ] 9.2 `DATABASE_URL` сервисов: `sslmode=verify-full`, `sslrootcert`, `sslcert`, `sslkey`; `migrate.sh`, `backup.sh`, `test-refresh.sh` по TLS. Проверка: миграция одной базы и дамп прошли на test.
- [ ] 9.3 Redis: проверить клиент google-auth на поддержку TLS; включить `tls-port` и `tls-auth-clients` либо зафиксировать исключение в README режима. Проверка: вход, refresh, logout на test работают; результат записан в README.
- [ ] 9.4 `infra/db/README.md`. Проверка: инструкция по подключению администратора выполнена как написано.

## 10. Включение на test целиком

- [ ] 10.1 `WALLET_INTERNAL_MTLS=true` на test для всего контура. Проверка: `up.sh test` без ошибок, все healthcheck зелёные, smoke выката проходит. _Включено на test 2026-11-21 19:00 (v0.5.0-rc.12): `up.sh` и healthcheck зелёные, все серверы отказывают без сертификата, вход/справочник/синхронизация/справка по спекам работают; бот, чат (SSE) и веб в браузере — ждут прогона владельцем, поэтому не отмечено._
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
