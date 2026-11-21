# Tasks

Порядок — по design.md (D6). Выкат только через `infra/env/up.sh`. Значения паролей не печатать (без `set -x`, без `cat` файлов `redis/`). Prod — только после полного прогона на test, в тихое время.

## 1. Подготовка

- [x] 1.1 Снять реальный набор ключей и команд: `redis-cli --scan` на prod и test (read-only, пока без пароля), сверить с префиксами из design (Context) и с `redis_client.hpp`. Проверка: список префиксов и команд записан в design.md (D3), расхождения устранены. _На test: refresh_token 64, user_refresh_tokens 41, mcp_token 5, user_mcp_tokens 2, user_access_tokens 1, access_token 1; на prod refresh_token 4, user_refresh_tokens 2 (только счёт по префиксам). Команды клиента — AUTH DEL EXISTS EXPIRE EXPIRETIME GET GETDEL INCR SADD SET SMEMBERS SREM TTL — совпадают с таблицей D3. Расхождений нет._
- [x] 1.2 `CLIENT LIST` на prod и test: кто сейчас подключён. Проверка: единственный штатный клиент — google-auth (плюс redis-exporter), посторонних соединений нет; результат записан в design.md. _`CLIENT LIST` на test и prod: одно штатное соединение google-auth (user=default, cmd=exists) и сам redis-cli; exporter остановлен (стек мониторинга не запущен); посторонних нет._
- [x] 1.3 Поискать `redis-cli` без пароля в джобах Jenkins (BuildPlatform, вне git: сначала резервная копия каталога jobs) и в скриптах `infra/env/`. Проверка: список мест, которые нужно править, записан (пусто, если их нет). _`redis-cli` без пароля: compose.yaml (healthcheck), infra/env/README.md, infra/db/README.md, infra/env/test-refresh.sh — все переведены в этом change. В джобах Jenkins (config.xml) и BuildPlatform упоминаний нет._

## 2. google-auth: `REDIS_USERNAME` (репозиторий google-auth)

- [x] 2.1 `redis_client.cpp`, `main.cpp`: необязательный `REDIS_USERNAME`, команда `AUTH <пользователь> <пароль>`; пусто — прежнее `AUTH <пароль>`. Проверка: юнит-тест построения команды для обоих случаев. _google-auth 0.4.5: `REDIS_USERNAME`, `redis::detail::auth_command`; 2 юнит-теста._
- [x] 2.2 Проверка с настоящим Redis 7 (одноразовый контейнер) с ACL-пользователем: старт с верными и неверными данными. Проверка: с верными — сервис работает; с неверными — процесс завершается, в журнале «Redis: AUTH не прошёл» **без пароля**. _Настоящий Redis 7 с ACL: верные данные — сервис стартует; неверный пароль и «только пароль при выключенном default» — завершение с кодом 1 и WRONGPASS, пароль в журнале нет; имя без пароля — понятная ошибка конфигурации. Права: SET/GET/GETDEL на своих префиксах работают, чужой ключ, KEYS, FLUSHALL, CONFIG — NOPERM, без учётных данных — NOAUTH._
- [x] 2.3 README и `.env.example` google-auth: `REDIS_USERNAME`. Проверка: пример из README запускается как написано. _README и `.env.example` google-auth._
- [ ] 2.4 Выкатить rc на test, затем релиз на prod, настройки не менять. Проверка: вход, refresh и logout работают, поведение не изменилось (метки `/api/versions`).

## 3. Скрипт, compose и документация (репозиторий wallet-infra)

- [x] 3.1 `infra/env/redis-auth.sh`: при отсутствии создаёт `~/.config/wallet-secrets/<env>/redis/{google-auth,health,exporter,admin}.env` (случайные пароли, права 0600) и `generated/redis/users.acl` с хешами (D3, D4); повторный запуск ничего не меняет. Проверка: два запуска подряд на test — файлы не меняются; в ACL-файле нет паролей; значения не печатаются. _`infra/env/redis-init.sh` (хост, один раз; два запуска — файлы не меняются, права 0600) и `infra/env/redis.sh` (users.acl из хешей). Проверено на копии контура: в ACL нет паролей, пароль admin не попадает в `docker compose config`. ACL-файл Redis не допускает комментариев — первый вариант не стартовал, исправлено._
- [x] 3.2 `compose.yaml`: сервис `redis` — `--aclfile`, монтирование каталога `generated/redis` (D5), `env_file` только с `health.env`, healthcheck `redis-cli --user health ping`; google-auth — `env_file` с `google-auth.env`. Проверка: `docker compose config` без утечки паролей; контейнер Redis не содержит паролей `admin` и `google-auth` (`docker exec … env`). _Проверено на test (v0.5.0-rc.14): в окружении контейнера Redis только пароль `health`, в контейнере google-auth только его пароль и `REDIS_USERNAME=google-auth`; пароль `admin` нигде не в `docker compose config`; healthcheck Redis — под `health`._
- [x] 3.3 Подключить `redis-auth.sh` в `up.sh` до старта Redis, режим ACL-файла (`default` включён или выключен) задаётся настройкой выката. Проверка: `up.sh test` на чистом и на работающем контуре — без ошибок, секреты создаются один раз. _`up.sh test` на работающем контуре (Jenkins, v0.5.0-rc.14 и -rc.15): без ошибок, секреты созданы один раз хостовым `redis-init.sh`, ACL применяется `ACL LOAD` без рестарта._
- [ ] 3.4 `test-refresh.sh`: `FLUSHALL` под `admin` (пароль через `REDISCLI_AUTH`, не в аргументах). Проверка: `test-refresh.sh` на test проходит, Redis test очищен, пароль не напечатан.
- [ ] 3.5 README (корневой, `infra/env/README.md`, `infra/db/README.md`): модель пользователей, подключение оператора `docker exec -it … redis-cli --user admin`, откат. Проверка: инструкция выполнена как написано на test.

## 4. Мониторинг

- [ ] 4.1 `infra/monitoring/up.sh` и `compose.yaml`: учётные данные exporter из `redis/exporter.env` каждого контура с префиксом `PROD_`/`TEST_`, `REDIS_USER`, `REDIS_PASSWORD` в `redis-exporter-<env>`. Проверка: `docker compose config` монитор-стека без паролей в выводе; exporter запускается.
- [ ] 4.2 Список команд пользователя `exporter`: прогнать exporter с ACL и дочитать `ACL LOG`. Проверка: цель `redis-exporter` up по test, `redis_connected_clients` и `redis_memory_used_bytes` обновляются, отказов ACL нет; список зафиксирован в design.md.

## 5. Включение на test

- [x] 5.1 Шаг 2 (D6): `up.sh test` с ACL-файлом, где `default` включён, затем пересоздание google-auth. Проверка: вход работает, токены на месте (число ключей `access_token:*` и `refresh_token:*` до и после совпадает), без паролей в клиентах. _2026-11-21 (v0.5.0-rc.14, режим compat): токены до и после совпадают (refresh_token 59→59, user_refresh_tokens 40→40, mcp_token 3→3, user_mcp_tokens 1→1; пропали только 2 короткоживущих access-ключа по TTL, DBSIZE 105→103)._
- [x] 5.2 Шаг 3: google-auth, healthcheck и exporter переведены на свои учётные данные. Проверка: все контейнеры healthy, метрики идут, google-auth подключён под пользователем `google-auth` (`CLIENT LIST` → `user=google-auth`). _google-auth, Redis и healthcheck healthy; `CLIENT LIST`: `user=google-auth` (плюс мой `admin`)._
- [x] 5.3 Шаг 4: `CLIENT LIST` без `user=default`, `ACL LOG` без отказов штатных клиентов. Проверка: пустой журнал отказов после прогона сценариев из 5.4. _`CLIENT LIST` без `user=default` (compat); `ACL LOG` пуст после прогона сценариев._
- [x] 5.4 Прогнать на test все пути Redis: вход через Google и по паролю, refresh (ротация `GETDEL`), logout, принудительный logout и массовый отзыв токенов админом, список устройств, привязка Telegram (`tg_link_code:`), MCP-токен, счётчики неудачных входов (`authfail:*`). Проверка: каждый сценарий проходит, `ACL LOG` пуст; найденные недостающие права добавлены в ACL (не ослабляя остальные). _12 сценариев через API тестовыми пользователями — все прошли: вход по паролю, ротация refresh и отказ старого токена, список устройств, выпуск MCP-токена, неудачные входы (`authfail`), код привязки Telegram, logout, вход админа, список пользователей, принудительный logout, отказ refresh после него. `ACL LOG` пуст; вход через Google на test не прогонялся (нужен браузер с Google-аккаунтом), его команды те же._
- [x] 5.5 Шаг 5: выключить `default` (`ACL LOAD`). Проверка: `redis-cli` без учётных данных из контейнера wallet-api отказывает; `redis-cli --user google-auth` с верным паролем выполняет `GET` своего ключа, но `FLUSHALL` и `KEYS *` отклоняются; вход пользователя на test работает. _v0.5.0-rc.15 (режим on): `default off` через `ACL LOAD`, Redis не перезапускался (uptime 302 с); из чужого контейнера сети test без учётных данных — `NOAUTH`; google-auth: `GET` на своём префиксе работает, `FLUSHALL`, `KEYS`, `CONFIG GET` — `NOPERM`; вход, refresh, logout работают._

## 6. Откат и отказ на test

- [ ] 6.1 Откат: вернуть прежний ACL-файл с `default` и `ACL LOAD`, затем снова выключить. Проверка: сервисы работают в обоих состояниях, токены не пропали.
- [ ] 6.2 Неверный пароль google-auth на старте. Проверка: процесс завершается, в журнале причина без значения пароля, healthcheck контейнера не проходит.
- [ ] 6.3 Выключение `default` при живом клиенте на `default` (имитация: соединение `redis-cli` без пароля до шага 5). Проверка: выкат сообщает о соединении `user=default` и не выключает его.

## 7. Prod

- [ ] 7.1 Подтвердить на prod версию google-auth с `REDIS_USERNAME` (задача 2.4) и повторить шаги 2–5 из D6 в тихое время. Проверка: после каждого шага вход, refresh, logout и бот работают, метрики prod up.
- [ ] 7.2 Сверка токенов: число ключей токенов до включения и после (по префиксам). Проверка: числа совпадают (с поправкой на естественное истечение TTL), пользователи остаются залогиненными.
- [ ] 7.3 Отметить в `add-internal-mtls` задачу 1.2 выполненной. Проверка: в tasks.md того change стоит ссылка на этот change, а `redis-cli` без пароля с контейнера prod отказывает.

## Workflow follow-up

- Дальше (отдельные changes): переподключение клиента Redis в google-auth после рестарта; TLS до Redis (`add-internal-mtls`, группа 9).
- Архивировать change после выката на prod и проверки.
