# diagrams

PlantUML-схемы взаимодействия сервисов WalletTransaction
(google-auth, wallet-api, wallet-report, wallet-web, wallet-gateway —
`wallet-bff` в этом составе больше нет, см. README wallet-web, "Куда делся
wallet-bff").

- **`sequence.puml`** — детальный сиквенс: анонимный визит (SPA сама дёргает
  `GET /auth/me`, чтобы узнать, залогинен ли пользователь) → логин через
  Google (включая ветку с отложенным подтверждением регистрации нового
  пользователя, `POST /auth/google/confirm-signup`, и запись обоих токенов —
  access И refresh — в Redis с TTL) → redirect на `/` и SPA рисует дашборд
  по тому же `/auth/me` (теперь дополнительно проверяет отзыв access-токена
  в Redis) → защищённый API-вызов через JWT-гейт гейтвея (создание
  кошелька) → обновление access-токена через `POST /auth/refresh` (атомарная
  ротация refresh-токена через Redis `GETDEL`, вместо прежнего
  `DELETE ... RETURNING` в Postgres) → список пользователей `/admin/users`
  (только `Role::Admin`, теперь обычный JSON API — SPA сама рисует таблицу,
  см. `app.js::renderAdmin()`) → логаут (`POST /auth/logout` теперь напрямую
  с фронтенда, отзывает ОБА токена в Redis) → принудительный logout другого
  пользователя администратором (`POST /admin/users/:id/logout` — отзывает
  ВСЕ его активные токены через обратный индекс в Redis, не только один
  токен из cookie, как обычный `/auth/logout`). Явно показывает, что
  `redirect_uri` указывает на гейтвей, а не на auth-service напрямую, как
  гейтвей прозрачно проксирует сам OAuth callback (открытый префикс
  `/auth/*` — см. README google-auth, "Через гейтвей, не напрямую"), и что
  мгновенный отзыв access-токена через Redis действует только для запросов
  В auth-сервис — не для `/api/*` через гейтвей (см. README google-auth,
  "Мгновенный logout — только в auth-сервисе").
- **`components.puml`** — статическая схема компонентов: кто с кем говорит,
  какие префиксы гейтвей роутит куда (три бекенда — `wallet-report`
  проверяется ДО общего `/api/*`, иначе тот перехватил бы первым) и где
  именно у него JWT-гейт, как устроена проверка токена через JWKS (RS256,
  без общего секрета — см. README auth-сервиса/wallet-api/wallet-gateway,
  "Как убрали общий секрет"), три роли (user/support/admin), что у
  wallet-api — СВОЯ, отдельная от auth-сервиса Postgres-база с полным
  доменом леджера/синка (`ledger`/`ledger_member`/`ledger_invite`/
  `app_user`/`device` + данные операций — не только демо-`wallets`, см.
  README wallet-api, "Своя БД"), что `wallet-report` (CQRS-lite) читает ТУ
  ЖЕ базу отдельным read-only соединением ролью `wallet_reader`, что у
  auth-сервиса Postgres остался только под `users`, а ОБА токена (access и
  refresh) — в Redis с AOF-персистентностью + volume (см. note у `REDIS` на
  диаграмме про разную цену потери данных для каждого из них) плюс обратный
  индекс "все токены этого user_id" (нужен только для принудительного
  logout администратором), и что wallet-web (nginx) — единственный
  компонент, который вообще не трогает JWT (это делает браузерный `app.js`,
  а не сам nginx) — включая приём `/join/<token>` через тот же SPA-фолбэк
  `try_files`.
- **`invite-sequence.puml`** — детальный сиквенс приглашения в леджер по
  одноразовой ссылке (Фаза 6, `org/docs/TODO_mobile_sync.md`): владелец
  создаёт ссылку (`POST /api/ledger/invites` — сырой токен отдаётся ровно
  один раз, в БД только его `sha256`) → приглашённый открывает `/join/
  <token>` без сессии (SPA-фолбэк `nginx`, токен уходит в `localStorage` —
  google-auth ПОСЛЕ входа всегда возвращает на `/`, не на исходный путь) →
  вход через Google (тот же флоу, что `sequence.puml`, шаг 2, — не
  дублируется подробно) → возврат на `/`, `POST /api/invites/accept` с
  тремя исходами (`200` принято, `409` у принимающего уже есть свой леджер
  — ссылка НЕ расходуется, `410` истекла/отозвана/использована) → отзыв
  ссылки владельцем. Явно показывает, почему приём одноразовый (`UPDATE ...
  WHERE used_at IS NULL ...` в одной транзакции с созданием `app_user`/
  `ledger_member`) и почему в ответе на создание нет поля `link` — только
  `token` (ссылку строит сам браузер из своего `location.origin`).
- **`sync-sequence.puml`** — офлайн-first синк Android ↔ wallet-api через
  wallet-gateway: сбор `dirty`-строк по 9 синхронизируемым таблицам и
  отдельная заливка содержимого иконок (`POST /sync/blobs`, контент-
  адресуемо по SHA-256) → push НЕ одним запросом, а циклом порций (`Sync
  Engine.chunkIntoPortions`, ≤1000 строк на порцию, `MAX_PUSH_BATCH_ROWS`)
  → на КАЖДУЮ порцию свой `POST /sync/push` — идемпотентность по своему
  `batch_id`, вся `changes` этой порции одной Postgres-транзакцией
  (`sync_repo.cpp::push_batch`), один `seq` на порцию, применение таблиц
  порции в фиксированном порядке по FK-зависимостям (`kApplyOrder`), три
  исхода конфликта (дубль имени счёта с `existing_uuid`,
  `missing_reference`, прочий дубль без авто-разрешения — любой из них
  прерывает отправку ОСТАЛЬНЫХ порций этого цикла синка, уже отправленные
  остаются применёнными) → `GET /sync/pull` постранично (два независимых
  курсора — `ledger`/`reference`, `limit=500`, страница не разрезает
  группу с одинаковым `seq`), применение страницы в той же порядке
  зависимостей на клиенте (`TABLE_ORDER` в `SyncEngine.java`). Отдельными
  note на диаграмме — где именно живёт «отправлено/получено» по обе
  стороны (`dirty` — своя колонка на каждой из 9 таблиц клиента,
  `sync_push_batch` — единственная таблица-идемпотент на сервере, свой
  batch_id на КАЖДУЮ порцию, `ledgerSyncSeq`/`referenceSyncSeq` — не
  таблица вовсе, а два ключа в Android `SharedPreferences`, ось pull,
  независимая от `dirty`), и что порции режутся по факту (по границе
  таблицы И по лимиту строк одновременно, не жёстко «одна порция — одна
  таблица») — лимит клиентский, не протокольный, сервер о порциях вообще
  не знает.
- **`logging.puml`** — конвейер логов, а не запрос/ответ между сервисами:
  кто пишет (google-auth/wallet-api/wallet-gateway — одна строка JSON на
  событие через `applog`, в контейнерах на stdout, т.к. `LOG_DIR` в
  compose не задан; db/redis/wallet-web(nginx) — свой формат, не JSON) →
  podman (`conmon`) кладёт stdout/stderr контейнеров в `journald`
  podman-machine → `fluent-bit` вычитывает журнал (`INPUT systemd`,
  `_COMM=conmon`) и цепочкой фильтров: whitelist по `CONTAINER_NAME` (режет
  чужие compose-стеки этой podman-machine и сам стек логирования — иначе
  `opensearch*`/`dashboards-init`/`fluent-bit` лили бы сами себя в индекс),
  переименование полей, разбор JSON (`app_json`, успешно только для трёх
  прикладных сервисов — у остальных запись остаётся как есть), чистка
  служебных полей journald/conmon → `OUTPUT opensearch` в индекс
  `wallet-logs-YYYY.MM.DD` → OpenSearch Dashboards читает их для Discover
  (index pattern `wallet-logs*`/saved search, разово импортированы
  `dashboards-init`). Отдельной note — ротация: дневные индексы, ISM-
  политика `wallet-logs-retention` удаляет их через 14 дней (ставит
  `opensearch-init`, см. `infra/logging/opensearch-init.sh`),
  и что нативный (не в контейнере) запуск сервиса на Windows пишет в
  `./logs/*.log` собственной ротацией `applog` — мимо этого конвейера
  целиком.

### Telegram-бот и LM Studio (2026-09-29)

План — `org/docs/TODO_telegram_bot.md`, сервис — `wallet-telegram`.

- **`telegram-components.puml`** — компоненты: `wallet-telegram` (цикл
  поллинга, `Bot`, `Sessions`, служебный HTTP), Telegram Bot API (только
  исходящий HTTPS, long polling), google-auth (выдача кода связывания,
  `/internal/telegram/exchange` напрямую, мимо гейтвея, refresh/logout),
  wallet-report (команды чтения с Bearer пользователя), своя база
  `wallet_telegram`, Redis с кодом связывания, мониторинг. Пунктиром — план:
  `/sync/push` в wallet-api (шаг 6) и LM Studio на хосте через
  `host.docker.internal:1234` (фазы 3–4).
- **`telegram-link-sequence.puml`** — подключение: «Подключить Telegram» в
  вебе → одноразовый код в Redis → ссылка и QR → `/start <код>` в Telegram →
  обмен кода на device-сессию `platform=telegram` → зашифрованный refresh в
  `tg_link`; веб опрашивает `/auth/devices` до появления сессии. Отключение
  из веба (revoke, бот узнаёт на следующем refresh) и `/unlink` из Telegram.
- **`telegram-commands-sequence.puml`** — цикл `getUpdates` с offset в базе
  и пропуском «ядовитого» апдейта; `/wallets` целиком: кеш access, refresh с
  ротацией и немедленной записью нового токена, 401 → удаление связки,
  повтор после 401 от wallet-report, «сегодня» в поясе пользователя; что
  происходит с сообщениями, пока бот лежит (24 ч в Telegram).
- **`telegram-llm-sequence.puml`** — **план, в коде ещё нет**: маршрутизация
  (команда → строгий формат → LLM), трата свободным текстом через
  structured output LM Studio с карточкой подтверждения и записью только по
  кнопке, агентный цикл с read-only инструментами, тот же реестр как MCP.

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
