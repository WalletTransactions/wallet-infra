# diagrams

PlantUML-схемы взаимодействия сервисов WalletTransaction (контур
`wallet-<env>` из `compose.yaml`: google-auth, wallet-api, wallet-report,
wallet-ai, wallet-mcp, wallet-docs, wallet-telegram, wallet-gateway,
wallet-web, tls-proxy, db, redis — `wallet-bff` в этом составе больше нет,
см. README wallet-web, "Куда делся wallet-bff"). Номера портов на схемах —
порты внутри контейнеров; на хосте гейтвей — 8090 (prod) / 8091 (test),
TLS-прокси — 8443 / 8444.

- **`sequence.puml`** — детальный сиквенс: анонимный визит (SPA сама дёргает
  `GET /auth/me`, затем `GET /auth/methods`, чтобы решить, какие способы
  входа показать) → вход через Google (`redirect_uri` строится из
  `X-Forwarded-Host`/`Host` и сверяется с `ALLOWED_REDIRECT_URIS`; ветка с
  отложенным подтверждением регистрации, `POST /auth/google/confirm-signup`;
  ветка, где Google забирает неподтверждённый парольный аккаунт) **или** вход
  по паролю (`POST /auth/login`: только при `X-Forwarded-Proto: https`,
  счётчики неудач в Redis, `429`, единый `401`) → запись обоих токенов в Redis
  (хэши, TTL, индексы на пользователя) → SPA по `/auth/me` открывает «Отчёты»
  → защищённый вызов через JWT-гейт гейтвея с проверкой `aud`
  (`GET /api/reports/balance` в wallet-report; прежнего демо `/api/wallets`
  больше нет) → обновление access-токена через `POST /auth/refresh`
  (атомарная ротация через Redis `GETDEL`) → `/admin/users` (только
  `Role::Admin`, JSON с `active_sessions`) → логаут (`POST /auth/logout`,
  отзывает ОБА токена) → принудительный logout другого пользователя
  администратором (`POST /admin/users/:id/logout` — ВСЕ его токены через
  обратный индекс в Redis). Явно показывает, что мгновенный отзыв
  access-токена через Redis действует только для запросов В google-auth —
  остальные сервисы проверяют JWT по JWKS и узнают об отзыве по `exp`.
- **`components.puml`** — статическая схема компонентов контура: кто с кем
  говорит, таблица префиксов гейтвея (`/api/reports/`, `/api/ai/`,
  `/api/docs/`, `/api/mcp/` — раньше общего `/api/`; `aud` JWT-гейта на
  каждом маршруте, `/api/mcp/` без гейта), tls-proxy перед гейтвеем, проверка
  токена через JWKS (RS256, без общего секрета), служебный порт google-auth
  `/internal/*` в сети `auth-internal` (бот, wallet-mcp, wallet-ai — мимо
  гейтвея), чат wallet-ai через wallet-mcp, wallet-mcp → wallet-report и
  wallet-docs по JWT обмена, LM Studio на хосте (и необязательный Anthropic),
  ОДИН Postgres контура (`pgvector/pgvector:pg16`) с базой и ролью на сервис
  (`wallet-report` читает базу wallet ролью `wallet_reader`), Redis только у
  google-auth (AOF + volume; ключи токенов, MCP-токенов, кода связывания
  Telegram, счётчиков неудачных входов; ACL на test) и wallet-web (nginx),
  который сам JWT не трогает — включая приём `/join/<token>` через
  SPA-фолбэк `try_files`.
- **`internal-mtls-components.puml`** — взаимный TLS внутри контура (change
  `add-internal-mtls`, ещё открыт): CA контура и `mtls.sh` (сертификаты
  сервисов на 30 дней, read-only монтирование), что идёт по mTLS (вызовы между
  сервисами, гейтвей → апстримы, служебный порт google-auth `:8443` с
  проверкой идентичности, `:8442`/`:8443` для Prometheus), что остаётся HTTP
  (входной порт гейтвея — граница, публичный порт google-auth), Postgres
  (`ssl=on`, `hostnossl reject`, `verify-full`, без клиентского сертификата
  роли) и Redis (ACL без TLS — исключение). Отдельной note — состояние test и
  prod по `infra/env/<env>.env`.
- **`invite-sequence.puml`** — детальный сиквенс приглашения в леджер по
  одноразовой ссылке: владелец создаёт ссылку (`POST /api/ledger/invites` —
  сырой токен отдаётся ровно один раз, в БД только его `sha256`) →
  приглашённый открывает `/join/<token>` без сессии (SPA-фолбэк `nginx`, токен
  уходит в `localStorage`) → вход через Google (возврат всегда на `/`) или по
  паролю на том же экране (без перезагрузки) → `POST /api/invites/accept` с
  исходами `200`, `410` и `409` с `ledger_empty`: пустой собственный леджер
  можно заменить повтором с `replace_empty_ledger: true` (после
  `confirm`), непустой — нельзя, ссылка при `409` НЕ расходуется → отзыв
  ссылки владельцем. Почему приём одноразовый (`UPDATE ... WHERE used_at IS
  NULL ...` в одной транзакции с созданием `app_user`/`ledger_member`) и
  почему в ответе на создание нет поля `link`.
- **`sync-sequence.puml`** — офлайн-first синк Android ↔ wallet-api через
  wallet-gateway: 12 синхронизируемых таблиц (вкл. `counterparty`,
  `account_debt`, `account_asset`, `currency_conversion`, `operation_link`) →
  иконки по умолчанию только скачиваются, «свои» уходят с иконкой-заместителем
  (`server-managed-icons`); загрузка своих иконок — только при настройке на
  телефоне и `capabilities.icon_upload` от сервера (`LEDGER_ICON_UPLOAD`,
  `optional-icon-upload`): `HEAD`/`POST /sync/blobs` и ОТДЕЛЬНЫЙ push-батч на
  иконку, отказ `403 icon_upload_disabled` / `icons_rejected` выключает
  настройку → push циклом порций (≤1000 строк, `MAX_PUSH_BATCH_ROWS`, свой
  `batch_id` и транзакция на порцию, один `seq`, `kApplyOrder`), исходы
  `409`/`400` → `GET /sync/pull` постранично с `ledger_id`: курсоры запроса —
  подтверждение устройства, `reset`/`reset_reason` (`ahead`, `purged`) с
  вычисткой отсутствующего на клиенте, `capabilities` → чистка tombstone по
  горизонту подтверждений активных устройств (`purge-synced-tombstones`).
  Отдельными note — где живёт «отправлено/получено» по обе стороны и что
  чистка `sync_push_batch` по-прежнему не реализована.
- **`logging.puml`** — конвейер логов, а не запрос/ответ между сервисами:
  прикладные C++ сервисы пишут одну строку JSON на событие в stdout, у
  каждого сервиса контура `logging.driver: journald` → `dockerd` кладёт
  строки в `journald` хоста → `fluent-bit` (отдельный проект
  `wallet-logging`, по умолчанию не запущен, курсор журнала в томе)
  вычитывает журнал (`_COMM=dockerd`), whitelist по `CONTAINER_NAME`
  (`wallet-(prod|test)-…`; wallet-docs и tls-proxy в него не входят), поле
  `env`, разбор JSON (`app_json`), чистка служебных полей → индекс
  `wallet-logs-YYYY.MM.DD` в OpenSearch → Dashboards (Discover). Ротация —
  ISM-политика `wallet-logs-retention`, 14 дней.

### Telegram-бот и ИИ

Сервис — `wallet-telegram`; ИИ — `wallet-ai` (задания), инструменты чтения —
`wallet-mcp`.

- **`telegram-components.puml`** — компоненты: `wallet-telegram` (цикл
  поллинга, `Bot`, `Sessions`, ожидающие задания ИИ, служебный HTTP),
  Telegram Bot API (только исходящий HTTPS, long polling), google-auth
  (код связывания, `/internal/telegram/*` на служебном порту по mTLS, мимо
  гейтвея), wallet-report (команды чтения токеном бота), wallet-api
  (`/sync/push` — трата по кнопке), wallet-ai (задания `parse_expense` и
  `chat`, SSE, выбор провайдера) → wallet-mcp → wallet-report, LM Studio на
  хосте и необязательный Anthropic — только из wallet-ai, своя база
  `telegram`, Redis с кодом связывания, мониторинг.
- **`telegram-link-sequence.puml`** — подключение: «Подключить Telegram» в
  настройках веба → одноразовый код в Redis → ссылка и QR → `/start <код>` в
  Telegram → обмен кода на связку `tg_user_id → user_id` в google-auth (без
  токенов у бота) → настройки в `tg_link`; веб опрашивает
  `/auth/telegram/links` до появления связки. Отключение из веба (бот узнаёт
  по `404` на следующем запросе токена) и `/unlink` из Telegram.
- **`telegram-commands-sequence.puml`** — цикл `getUpdates` с offset в базе
  и пропуском «ядовитого» апдейта (ожидание сокращается до 1 с, пока есть
  задания ИИ); `/wallets` целиком: короткий токен бота
  (`/internal/telegram/token`, 5 мин, кеш), `404` → удаление связки, один
  повтор после `401` от wallet-report, справочник счетов без системных и
  долговых, «сегодня» в поясе пользователя; что происходит с сообщениями,
  пока бот лежит (24 ч в Telegram).
- **`telegram-llm-sequence.puml`** — реализованный путь ИИ в боте:
  маршрутизация текста (команда → строгий формат → вопрос → трата свободным
  текстом), задание `parse_expense` с опросом и карточкой подтверждения,
  запись `/sync/push` только по кнопке (UUIDv5 `batch_id`, «Проверить ещё
  раз» при неизвестном исходе), задание `chat` с обменом токена, агентным
  циклом wallet-ai через инструменты wallet-mcp и показом ответа по мере
  генерации (SSE `delta`/`tool`/`done`), выбор провайдера `/ai` с согласием
  на облачный.
- **`mcp-oauth-sequence.puml`** — **план, после v1**: MCP-клиент (Claude
  Code) получает JWT по OAuth 2.1 и задаёт вопрос `wallet-mcp`. Шаги:
  обнаружение по `401` + `WWW-Authenticate` (RFC 9728/8414) → регистрация
  публичного клиента (DCR или Client ID Metadata Document) → Authorization
  Code + PKCE в браузере с экраном согласия google-auth → обмен кода на access
  (`aud` `wallet-mcp`, 15 мин) и ротируемый refresh → `tools/call`, где
  `wallet-mcp` меняет клиентский JWT на свой для wallet-report (RFC 8693 —
  эта часть уже работает, `/internal/token/exchange`) → обновление по
  refresh и реакция на повторное использование → отзыв из «Моих устройств».
  Сейчас вместо шагов 1–4 — персональный токен `wmcp_…`. Предусловие HTTPS
  уже есть на test (TLS-вход).
- **`token-exchange-sequence.puml`** — обмен токена RFC 8693
  (`POST /internal/token/exchange` на служебном порту google-auth по mTLS):
  чат `wallet-ai` (из веба `POST /api/ai/jobs` или из Telegram-бота) меняет
  токен пользователя на JWT для `wallet-mcp` (`mcp:read`, `act` wallet-ai) →
  `wallet-mcp` проверяет его локально по JWKS и меняет на JWT для
  `wallet-report` (`reports:read`) или `wallet-docs` (`docs:ask`, инструмент
  `ask_docs`) → данные. Отказы (`invalid_client`, `403` проверки
  идентичности, `invalid_target`, `invalid_grant`, `401` у wallet-mcp с
  причиной в журнале), кеш, который не продлевает входящий JWT, и для
  сравнения путь персонального токена `wmcp_…`.

### TLS на входе и mTLS внутри контура

- **`tls-ingress-components.puml`** — TLS на входе контура (change
  `add-tls-ingress`): `tls-proxy` (Caddy) перед гейтвеем и три источника
  сертификата — CA Caddy (`internal`), файлы (`files`) и Let's Encrypt от
  `tailscaled` хоста (`tailscale`), какой сайт Caddyfile за какой режим
  отвечает, что из TLS-входа берёт google-auth (`redirect_uri`, `Secure`
  cookie, вход по паролю только по https) и где включено (test — да, prod —
  нет).
- **`tls-ingress-login-sequence.puml`** — вход через Google за TLS-прокси с
  двумя ветками рукопожатия по SNI: имя `.ts.net` (сертификат от
  `tailscaled`) и IP / nip.io (CA Caddy), плюс режим `files`; какие
  `redirect_uri` должны быть в Google Cloud Console для обеих веток.
- **`internal-mtls-components.puml`** — см. выше, в общем списке.

## Как отрендерить

**2026-09-09: впервые реально прогнаны через рендерер**, не только
вычитаны на синтаксис — локальный `podman` смог стянуть и запустить
`docker.io/plantuml/plantuml` (никакой Java/Graphviz руками ставить не
пришлось). Все пять файлов (включая новый `invite-sequence.puml`) собраны в
PNG без единой ошибки, картинки сверены глазами построчно с исходным
сценарием — контента наружу это не отправляет (образ работает целиком
локально в контейнере, в отличие от варианта 3 ниже). Сгенерированные `.png`/`.svg` НЕ закоммичены (как и раньше — источник
истины только `.puml`, картинка легко устаревает и молча расходится с
ним) — удалены сразу после проверки, генерируйте заново по мере надобности
той же командой. Команда, которой проверялось (Windows/git-bash,
`MSYS_NO_PATHCONV` — чтобы бэш не переписывал `-v`-путь):
```bash
podman run --rm -v "$(pwd)":/data -w /data docker.io/plantuml/plantuml \
    -tpng components.puml sequence.puml sync-sequence.puml \
    logging.puml invite-sequence.puml
```
Сейчас (Linux-хост, docker) — все схемы разом, SVG с именами из `@startuml`,
которые ждёт `index.html`:
```bash
docker run --rm -v "$PWD":/data -w /data docker.io/plantuml/plantuml -tsvg *.puml
```
Только проверка синтаксиса, без картинок — `-checkonly` вместо `-tsvg`.

Диаграммы выше ~4096px высотой (сиквенсы `sequence.puml`/`invite-sequence.puml`)
обрезаются PNG-рендерером по умолчанию — добавить `-e PLANTUML_LIMIT_SIZE=10000`
переменной окружения контейнера, если нужен рендер целиком, не только для
предпросмотра верхней части.

Другие варианты рендера, если `podman`/Docker недоступен:

1. **VS Code** — расширение "PlantUML" (jebbs.plantuml), `Alt+D` для
   превью. Само по себе тоже стучится на публичный сервер plantuml.com,
   если нет локального Graphviz — см. настройки расширения, если не
   хотите отправлять содержимое наружу.
2. **Локально** — `plantuml.jar` (нужна Java) + Graphviz (`dot`) в PATH:
   ```bash
   java -jar plantuml.jar sequence.puml components.puml sync-sequence.puml logging.puml invite-sequence.puml
   ```
   Сгенерирует `.png` рядом с исходниками.
3. **Онлайн** — [plantuml.com/plantuml](https://www.plantuml.com/plantuml/uml/)
   — вставить текст файла руками. Осознанно не делал этого автоматически
   за вас: это отправка содержимого на внешний публичный сервис, пусть
   даже без секретов — решать вам.

## Актуальность

Схемы обновлены после: (1) выделения CRUD кошельков в отдельный сервис
[wallet-api](https://github.com/WalletTransactions/wallet-api) со своей БД; (2) перевода `REDIRECT_URL` на
адрес гейтвея; (3) перехода фронтенда на SPA — [wallet-web](https://github.com/WalletTransactions/wallet-web)
(nginx, статика) вместо server-rendered `wallet-bff` (сервис упразднён
целиком), плюс новый `GET /auth/me` на google-auth и redirect на `/` вместо
своей HTML-страницы успеха после логина — 2026-08-26; (4) добавления Redis
в google-auth под активные access-токены (TTL = `ACCESS_TOKEN_TTL_SECS`),
`POST /auth/logout` отзывает их мгновенно, но только для проверок внутри
самого auth-сервиса; (5) переезда refresh-токенов из Postgres в тот же
Redis (AOF-персистентность + volume — обязательна для них, TTL 30 дней),
ротация через атомарный `GETDEL` вместо `DELETE ... RETURNING`; (6)
принудительного logout — `POST /admin/users/:id/logout` (только
`Role::Admin`), обратный индекс в Redis (`user_access_tokens:<id>`/
`user_refresh_tokens:<id>`) для поиска всех токенов пользователя по
`user_id`; (7) переноса `/admin/users` из server-rendered HTML в JSON API —
SPA (`wallet-web`) сама рисует таблицу, тем же приёмом, что и дашборд —
2026-08-28.
При следующих архитектурных изменениях (list/get/update в wallet-api,
автоматизация ротации ключа) — обновить вручную, авто-синхронизации с
кодом нет.

**`sync-sequence.puml`** добавлена 2026-09-05 отдельным файлом (не веткой в
`sequence.puml`) — другой протокол домена (`/sync/*`, wallet-api) и другой
клиент (Android, не браузер), общий у них только гейтвей на входе.

Обновлена тем же днём: push перестал быть одним HTTP-запросом на весь
`dirty`-набор — теперь клиент режет его на порции (`SyncEngine.
chunkIntoPortions`, ≤1000 строк, `MAX_PUSH_BATCH_ROWS`) и шлёт `POST
/sync/push` в цикле, по одной транзакции на порцию. Протокол `/sync/push`
не менялся вообще — порции для сервера неотличимы от независимых вызовов,
это чисто клиентское разбиение.

**`logging.puml`** добавлена 2026-09-05 — единственная схема здесь не про
HTTP/протокол между сервисами, а про конвейер логов (`infra/logging/
fluent-bit.conf`, `parsers.conf`, `compose.yaml`): stdout контейнеров →
journald podman-machine → fluent-bit → OpenSearch → Dashboards. При
изменении whitelist-регэкспа в fluent-bit.conf, набора полей JSON-лога
(`applog`) или появлении ISM/rollover-политики для `wallet-logs` — обновить
вручную.

**2026-09-09 — Фаза 6 (доступ и приглашения в леджер) плюс актуализация
накопившегося отставания от Фаз 2-8**, по прямому запросу ("актуализируй
остальные диаграммы"):

- **`invite-sequence.puml`** — новый файл, сиквенс приглашения по
  одноразовой ссылке целиком (создание → приём через веб-логин с обеими
  ветками localStorage → отзыв). См. описание выше.
- **`components.puml`** — до этой правки диаграмма всё ещё описывала
  wallet-api как демо-CRUD кошельков БЕЗ домена леджера/синка вообще и без
  `wallet-report` как отдельного сервиса (то есть отставала не только от
  Фазы 6, а от ВСЕХ архитектурных изменений с конца августа — Фаз 2-8, см.
  `org/docs/TODO_mobile_sync.md`). Актуализирована разом: добавлены
  `wallet-report` (CQRS-lite, читает ту же БД ролью `wallet_reader`),
  реальный домен wallet-api (`ledger`/`ledger_member`/`app_user`/`device` +
  новая `ledger_invite`), маршрутизация гейтвея на три бекенда, `/join/
  <token>` через SPA-фолбэк `wallet-web`.
- **`sequence.puml`**/**`sync-sequence.puml`** — точечные заметки-ссылки на
  `invite-sequence.puml` (вход через `/join/<token>` использует ТОТ ЖЕ
  Google-флоу; `ledger_member`/`ledger_invite` НЕ часть протокола push/pull)
  — сами сиквенсы логина и синка не переписывались, они не изменились.
- **`logging.puml`** — `wallet-report` добавлен в список JSON-логирующих
  сервисов (упущен ещё при выделении сервиса 2026-09-08, не связано с
  Фазой 6 — попутно исправлено при том же проходе).

Впервые за всю историю этого каталога все пять файлов прогнаны через
настоящий рендерер (см. "Как отрендерить" выше), не только вычитаны на
синтаксис — мелких PlantUML-опечаток, которые предыдущие проходы могли не
заметить, не нашлось.

**2026-11-22 — сверка всех схем с `compose.yaml`, `compose.*mtls*.yaml`,
`infra/env/*` и архивом OpenSpec-изменений всех репозиториев** (по
запросу «актуализируй диаграммы»):

- **`components.puml`** — добавлены wallet-docs, wallet-telegram, tls-proxy,
  служебный порт google-auth и сеть `auth-internal`, маршрут `/api/docs/`,
  `aud` на маршрутах гейтвея, связи чата (wallet-ai → wallet-mcp →
  wallet-report/wallet-docs), Anthropic как необязательный провайдер. Postgres
  показан как ОДИН инстанс контура с базой на сервис (раньше — две
  «отдельные» базы), убрано демо `/api/wallets`/`wallets`, порт wallet-web —
  80, ключи Redis дополнены (`mcp_token`, `tg_link_code`, `authfail:*`) и
  ACL.
- **`internal-mtls-components.puml`** — новая схема (change
  `add-internal-mtls`, состояние test/prod на эту дату).
- **`sequence.puml`** — вход по паролю и `GET /auth/methods`, выбор
  `redirect_uri` по заголовкам, `aud` у JWT-гейта; защищённый вызов теперь
  `GET /api/reports/balance` (демо-кошельков больше нет).
- **`sync-sequence.puml`** — таблицы синка (12), иконки только с сервера и
  необязательная загрузка своих (`HEAD`/`POST /sync/blobs`, отдельный
  батч, `icons_rejected`, `capabilities.icon_upload`), `ledger_id` в pull,
  подтверждения устройств, `reset_reason`, чистка tombstone, ответ `400
  invalid_row`.
- **`invite-sequence.puml`** — вход по паролю на экране приглашения,
  `409 ledger_empty` и `replace_empty_ledger`.
- **`logging.puml`** — podman/conmon → docker/dockerd, проекты
  `wallet-prod`/`wallet-test` и `wallet-logging`, whitelist из
  `fluent-bit.conf`, поле `env`, курсор journald.
- **Telegram** — `telegram-llm-sequence.puml` переписана из плана в
  реализованный путь через задания wallet-ai; в `telegram-components.puml`
  бот больше не ходит к LM Studio сам, `/sync/push` реализован; в
  link/commands — токен бота с `aud` wallet-ai и `ai:use`, служебный порт по
  mTLS, справочник без `kind=wallet`.
- **`token-exchange-sequence.puml`** — чат больше не план, ветка
  `ask_docs` (aud `wallet-docs`), отказ проверки идентичности.
- **`mcp-oauth-sequence.puml`** (по-прежнему план) — предусловие HTTPS
  отмечено как выполненное на test, обмен на шаге 5 — через
  `/internal/token/exchange`.
- **`tls-ingress-components.puml`** — wallet-docs в списке апстримов,
  состояние test/prod, HTTP-участок Caddy → гейтвей при mTLS.
- **`index.html`** — добавлены обе TLS-схемы (раньше их там не было) и
  схема mTLS.
