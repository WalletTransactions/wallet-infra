# Design

## Context

Мотивация описана в proposal.md, раздел «Why». Ниже то, что есть сейчас и что ограничивает решение.

- **Живая среда.** Это compose-проект `servers` (`wallet-infra/compose.yaml`). Его выкатывает Jenkins:
  - `BuildPlatform/jobs/lib/deploy_services.sh` пересобирает образы на хосте из рабочей папки;
  - `migrate_all.sh` накатывает миграции через `infra/db/migrate.sh`;
  - оба скрипта берут блокировку `flock` `/tmp/wallet-transactions-deploy.lock`.
- **Сеть и наблюдаемость.** Сеть приложения называется `wallet-net`, имя зафиксировано: к ней как
  `external` подключается стек метрик (`infra/monitoring/compose.yaml`, Prometheus и экспортёры
  db/redis). Стек логов (`infra/logging`) берёт из journald только контейнеры с префиксом
  `servers-`. Loadtest-job'ы Jenkins подключаются к `wallet-net` и бьют в живой стек.
- **`infra/k8s`.** Это 11 YAML и `apply.sh` под namespace `wallet-transaction` с образами `:local`.
  Кластера на хосте нет, манифесты не используются.
- **CI.** GitHub Actions в каждом репозитории сервиса уже собирает образ, но не публикует его
  (`org/docs/TODO_ci.md`, шаг 1). Хэш коммита попадает в образ через build-arg `GIT_COMMIT`,
  semver берётся из файла `VERSION`. Runtime-образы — `debian:bookworm-slim` (есть `sh` и `cp`).
- **Хост.**
  - Одна машина: 12 ядер, 14 ГБ RAM (под нагрузкой IDE и Chrome свободно около 7 ГБ).
  - На `/` свободно 13 ГБ из 94; из них 9,7 ГБ кэша сборки docker и 3 ГБ образов освобождаются.
  - Рабочая папка на NTFS.
  - docker и compose v5.6 (поддерживают `!reset`, обязательные переменные `${VAR:?}`).
  - LM Studio на хосте, порт 1234, GPU один.
  - Jenkins работает в контейнере с `docker.sock`.
- **Состояние сервисов.**
  - Сессии и refresh-токены google-auth хранятся в Redis.
  - Привязки Telegram лежат в `auth.telegram_links` и `telegram.tg_link`, offset getUpdates —
    в `telegram.tg_update_offset`. Бот и google-auth доверяют друг другу по общему
    `TELEGRAM_SERVICE_SECRET`; токенов бот не хранит.
  - Роль `wallet_reader` (wallet-report) создаёт миграция wallet-api с паролем-литералом
    для локальной разработки; остальные роли — `init-db.sh` из переменных окружения.
  - wallet-telegram допускает только один процесс на токен.

## Goals / Non-Goals

**Goals:**
- Требования из specs/ выполнены на одной машине без ручных шагов при обычном выкате.
- Описание сервисов одно на оба контура, различия контуров видны в git.
- Ничего нового на хост не ставится.
- Старый стек `servers` снесён до переключения prod (решение владельца 2026-10-24: его данные
  тестовые); отката на него нет — откат prod идёт по версиям сервисов (D5).

**Non-Goals:**
- Третий (dev) контур и запуск сервисов в контейнерах из рабочей папки. Правка проверяется
  rc-тегом в test.
- Публикация наружу (домен, TLS) и HA.
- Android-сборка, которая смотрит в test. Её можно сделать позже, адрес `:8091` уже будет.
- Kubernetes. Рассматривался (k3s) и отклонён, см. D1.
- Отказ от Jenkins в пользу self-hosted runner (вопрос 2 в TODO_ci.md остаётся открытым).

## Decisions

### D1. Контур — compose-проект docker
Каждый контур — отдельный compose-проект поверх одного `compose.yaml`: `wallet-prod` и `wallet-test`.
Изоляцию даёт отдельная bridge-сеть проекта, приоритет при нехватке памяти — `oom_score_adj`,
перезапуск после ребута — `restart: unless-stopped`.
- *Почему не k3s:* рассматривался в первой версии этого change. Отклонён:
  - +500–600 МБ RAM на сам кластер и второй containerd с отдельным хранилищем образов на тесном `/`;
  - установка через sudo, пороги kubelet, `fail-swap-on=false` при активном swap;
  - kustomize, NetworkPolicy, ServiceAccount и kubeconfig для Jenkins;
  - то, что k8s давал сверх compose (rollout с откатом, QoS), на одной машине заменяется
    скриптом выката (D5) и `oom_score_adj` (D10).
- *Почему без dev-контура:* так решил владелец. Меньше расход памяти и нет риска, что ручной
  `up --build` из рабочей папки снова попадёт в живую среду.

### D2. Один `compose.yaml`, настройки контура в env-файлах
`compose.yaml` переписывается:
- `name: wallet-${WALLET_ENV:?…}`. Без `WALLET_ENV` compose падает с понятной ошибкой,
  поэтому случайный запуск без контура невозможен;
- `build:` удаляется; `image: ghcr.io/wallettransactions/<сервис>:${<СЕРВИС>_TAG:?}`;
- на хост публикуется только гейтвей: `${WALLET_GATEWAY_PORT:?}:8090`. Остальные `ports:` удаляются;
- `env_file` и PEM-ключ берутся из `${WALLET_SECRETS_DIR}/…` вместо `../<сервис>/.env`;
- сеть — `wallet-${WALLET_ENV}`, `external: true` (её создаёт `up.sh`, чтобы стек метрик
  мог к ней подключиться независимо от порядка запуска);
- тома `db-data`, `redis-data` — обычные тома проекта (`wallet-<env>_db-data`, …);
- у каждого сервиса alias `<сервис>-${WALLET_ENV}` в сети контура (D11);
- `mem_limit` по сервисам и `oom_score_adj: ${WALLET_OOM_ADJ}` (D10).

Настройки контура в git:
- `infra/env/prod.env`, `infra/env/test.env` — `WALLET_ENV`, порт гейтвея,
  `WALLET_OOM_ADJ`, `LLM_URL`;
- `~/.local/state/wallet-envs/<env>/tags.env` — текущие теги образов (D6), пишет только выкат.

Секреты вне git — `${WALLET_SECRETS_DIR}/<env>/` (D7).

Запуск только через `infra/env/up.sh <env>`:
`docker compose --env-file infra/env/<env>.env --env-file <state>/tags.env --env-file <secrets>/db.env up -d`.
- *Альтернатива:* общий файл плюс оверлей (`compose.env.yaml` с `!reset build`). Нужна была
  только для dev-контура, без него лишняя.

### D3. Образы: CI публикует в ghcr, финальный тег делается перетегом
- **Тег `vX.Y.Z-rc.N`.** Workflow сборки сервиса:
  - проверяет, что `VERSION` равен `X.Y.Z`;
  - собирает образ с `GIT_COMMIT`;
  - публикует `ghcr.io/wallettransactions/<сервис>:X.Y.Z-rc.N`.
- **Тег `vX.Y.Z`.** Workflow ищет `git tag --points-at HEAD` вида `vX.Y.Z-rc.*` и берёт старший.
  Образ получает новый тег без пересборки:
  `skopeo copy --preserve-digests docker://…:X.Y.Z-rc.N docker://…:X.Y.Z`.
  Не `docker buildx imagetools create`: одиночный манифест он заворачивает в новый
  индекс с другим digest (проверено на google-auth 0.1.0), и гейт prod его не узнаёт.
  Если rc не найден, workflow падает.
- **Pull на хосте.** `docker login ghcr.io` токеном `read:packages` один раз на хосте
  (и в контейнере Jenkins — тот же `~/.docker/config.json`).
- *Альтернатива:* собирать на хосте. Отклонена: хост компилирует C++ (параллельная сборка
  уже вешала машину), в test и prod попадали бы разные сборки, вернулась бы проблема
  «катится рабочая папка».

### D4. Миграции едут внутри образа сервиса
В Containerfile google-auth, wallet-api, wallet-telegram и wallet-ai добавляется
`COPY migrations /migrations`. `infra/env/migrate.sh <env> <база> <образ>`:
1. образ сервиса нужной версии копирует `/migrations` во временный docker-том
   (`docker run --user 0 --entrypoint cp`). Не в каталог на диске: в Jenkins скрипт работает
   в контейнере, и его `/tmp` docker на хосте не видит;
2. `docker run --rm --network wallet-<env> migrate/migrate:v4.18.3 … up` против db контура ролью мигратора;
3. после наката базы wallet — `ALTER ROLE wallet_reader PASSWORD` значением
   `READER_POSTGRES_PASSWORD` из `db.env` контура (D7).

Схема всегда соответствует выкатываемому коду, Jenkins не нужен checkout репозиториев сервисов.
Заменяет `infra/db/migrate.sh` (он ищет контейнер db по лейблу проекта `servers`).
- **Обратная совместимость.** Ручной откат сервиса миграции не откатывает (спека
  release-promotion, «Ручной откат»). Поэтому миграции пишутся по схеме expand/contract:
  удаление столбца делается отдельным релизом после того, как код перестал его читать.
  Это правило фиксируется в `infra/db/README.md`.

### D5. Выкат: скрипты в wallet-infra, Jenkins следит за ghcr
Логика выката лежит в `wallet-infra/infra/env/*.sh` (в git, версионируется вместе с `compose.yaml`).
Jenkins держит на хосте checkout wallet-infra по выкатанному тегу в `<state>/<env>/infra`
и вызывает скрипты оттуда; Jenkinsfile'ы — тонкие обёртки.
- **`env-release-watch`** (cron `H/5`):
  - читает список тегов каждого образа через API ghcr и теги `wallet-infra` через `git ls-remote`;
  - сравнивает с `tags.env` контуров;
  - на каждый новый тег запускает `env-deploy`.

  Опрашивать ghcr, а не git, выбрано потому, что выкатить можно только то, что уже
  опубликовано. Webhook не подходит: Jenkins в LAN, и GitHub до него не достучится.
- **`env-deploy`** (ENV, SERVICE, TAG) → `infra/env/deploy.sh`:
  1. `flock` `<state>/<env>.lock` — в каталоге состояния, общем для хоста и
     контейнера Jenkins (у контейнера свой `/tmp`, блокировка там не видна хосту);
  2. `docker pull`, digest образа;
  3. для prod — гейт по digest и дамп (D6);
  4. миграции (D4), если у сервиса есть база;
  5. запись нового тега в `tags.env`, `up -d --no-deps --wait --wait-timeout 180 <сервис>`;
  6. smoke: `/healthz` гейтвея контура и `/version` сервиса (через `docker exec` в контейнер
     гейтвея по имени сервиса) отдаёт ожидаемую версию;
  7. при ошибке — прежний тег обратно в `tags.env` и `up -d --no-deps --wait <сервис>`;
  8. при успехе — digest в `<state>/<env>/verified`, строка в `<state>/<env>/history`.

  Для SERVICE=`wallet-infra`: checkout тега в `<state>/<env>/infra`, затем `up.sh <env>`.
  Теги сервисов берутся из `tags.env`, поэтому выкат манифестов версии сервисов не меняет;
  compose пересоздаёт только контейнеры, чьё описание поменялось. При ошибке smoke — checkout
  прежнего тега и `up.sh` ещё раз.
- **`env-rollback`** (ENV, SERVICE, TAG): тот же `deploy.sh` без миграций и без гейта.
  Список доступных тегов — из `history`.
- **wallet-telegram** перезапускается через `up -d` с остановкой старого контейнера до старта
  нового (compose так и делает для одной реплики), двух процессов бота нет.
- *Альтернатива:* Argo CD/Flux или Watchtower. Отклонены: ещё один сервис на хосте, нет
  гейта по digest и порядка «миграции → сервис → smoke».

### D6. Гейт prod, состояние и дампы
- **Состояние** контура — `~/.local/state/wallet-envs/<env>/` на ext4:
  `tags.env`, `verified` (digest'ы, прошедшие smoke), `history` (время, сервис, тег, digest, итог),
  `infra/` (checkout wallet-infra).
- **Гейт.** Перед выкатом в prod `deploy.sh` ищет digest образа в `test/verified`.
  Если его нет, выкат падает с «digest не проверен в test».
- **Дамп.** `pg_dump -Fc` нужной базы через `docker exec` в db prod ролью мигратора.
  Файл пишется в `${WALLET_BACKUP_DIR}/prod/<база>/<время>_<тег>.dump`. Каталог по умолчанию
  лежит на диске DATA (`sda`, HDD): это другой физический диск, чем SSD (`sdb`), на котором
  лежат тома docker. Хранятся последние 3 дампа с выкатов плюс ежесуточные от `prod-backup` за 7 дней.

### D7. Секреты контуров
Секреты лежат в `~/.config/wallet-secrets/{prod,test}/` на ext4 (права 700/600):
`db.env` (бывший `infra/db/.env`), `google-auth.env`, `wallet-api.env`, `wallet-report.env`,
`wallet-telegram.env`, `wallet-ai.env`, `wallet-gateway.env`, `jwt_signing_key.pem`.

Оба контура стартуют с пустыми базами (данные стека `servers` тестовые, не переносятся),
поэтому сохранять прежние ключи не нужно: каждый контур получает свои новые пароли БД,
RSA-ключ и `TELEGRAM_SERVICE_SECRET` (одно значение в `google-auth.env` и `wallet-telegram.env`
контура).
- **wallet_reader.** Пароль-литерал из миграции wallet-api в контурах не используется:
  `db.env` задаёт `READER_POSTGRES_PASSWORD`, `migrate.sh` перезадаёт им пароль роли после
  каждого наката базы wallet (D4), а `compose.yaml` собирает из него `REPORTS_DATABASE_URL`.
  Так у всех ролей Postgres пароли свои в каждом контуре, без правок в репозиториях сервисов.
- **prod:** токен @WalletTransaction_bot, `REDIRECT_URL=http://localhost:8090/auth/google/callback`.
- **test:** токен нового бота, `REDIRECT_URL=http://localhost:8091/auth/google/callback`.

Google OAuth-клиент общий: в Console добавляется второй redirect URI.
- **Jenkins.** compose читает `env_file` в контейнере Jenkins, а пути bind-монтирований
  разрешает docker на хосте. Поэтому `~/.config/wallet-secrets`, `~/.local/state/wallet-envs`
  и `${WALLET_BACKUP_DIR}` монтируются в Jenkins по тем же абсолютным путям, что на хосте.

### D8. Сеть и LLM
- **Сеть.** У каждого контура своя bridge-сеть `wallet-<env>`. Контейнеры разных контуров
  друг друга не видят. На хост публикуются гейтвей и Postgres — последний только на
  `127.0.0.1` (prod 15555, test 15432) для DBeaver/psql с этой машины, вход по паролям ролей
  из `db.env` (решение владельца 2026-10-24). Redis — только `docker exec`.
- **LM Studio.** wallet-ai prod ходит по `LLM_URL=http://host.docker.internal:1234/v1`
  (`extra_hosts: host-gateway` уже есть). LM Studio должен слушать не только `127.0.0.1`.
- **LLM в test.** По умолчанию `LLM_URL` в test пуст, поэтому `enabled=false`. GPU один:
  фоновые задания test отнимали бы его у интерактивных запросов prod.
  Решение владельца 2026-10-24: в test ИИ включён явной настройкой (`infra/env/test.env`,
  тот же LM Studio, `LLM_API_KEY` в секретах test) — это и есть «явная настройка контура
  test» из спеки; конкуренция за GPU с prod принимается.

### D9. Данные контуров
- **Сид** (prod и test одинаково). Это только миграции: роли создаёт `auth/000001`, админ появляется при первом входе
  по `ADMIN_EMAILS`. Демо-данных нет. Если понадобятся, это отдельный SQL в `infra/db/seed/`.
- **Перезаливка** (`infra/env/test-refresh.sh`, job `env-test-refresh`, под блокировкой test):
  1. `docker compose stop` для всех сервисов test, кроме db и redis;
  2. `pg_dump -Fc` четырёх баз prod новой ролью `dumper` с `pg_read_all_data`. Её заводит
     `init-db.sh`. `wallet_reader` не подходит: у него доступ только к базе wallet;
  3. `pg_restore --clean --if-exists` в test;
  4. миграции test (D4) из образов, выкатанных в test;
  5. `TRUNCATE telegram_links`, `tg_link`, `tg_update_offset`;
  6. `FLUSHALL` Redis test;
  7. `up.sh test`.

  Персональные финансовые данные при этом копируются в test на ту же машину того же
  владельца. Это допустимо, пока test LAN-only и не открыт другим людям.

### D10. Память
Замер `docker stats` 2026-10-23, стек `servers`: db 246 МБ, wallet-api 54 МБ, остальные 7 сервисов
по 5–18 МБ, всего ~380 МБ. Контур test добавляет около 400 МБ.

Kubelet нет, выселять поды некому; при нехватке памяти решает ядерный OOM-killer.
- **prod:** `oom_score_adj: -900`, OOM-killer обходит его почти до конца.
- **test:** `oom_score_adj: 500`, под давлением памяти умирает первым.
- **`mem_limit`** одинаковый в обоих контурах: db 384m, redis 64m, wallet-api 128m, остальные
  по 64m, wallet-web 32m. Потолок не даёт утечке одного сервиса съесть хост.

Swap хоста работает как раньше. Диск: перед первым pull — `docker builder prune` и
`docker image prune` (около 12 ГБ); образов ghcr на версию ~25 МБ на сервис поверх общего слоя.

### D11. Наблюдаемость: один стек на оба контура
- **Логи.** fluent-bit читает journald по имени контейнера. Белый список префиксов
  `servers-` меняется на `wallet-prod-` и `wallet-test-`; из префикса выводится поле `env`
  (`prod`/`test`). Индекс OpenSearch один, фильтр по `env`.
- **Метрики.** Prometheus подключается к сетям `wallet-prod` и `wallet-test` как `external`.
  Внутри сетей имена сервисов одинаковые, поэтому Prometheus скрейпит по alias'ам
  `<сервис>-prod`/`<сервис>-test` и ставит метку `env` (имена job не меняются — дашборды
  не ломаются). Экспортёры postgres и redis — по одному на контур, каждый только в сети
  своего контура (`db-<env>`, `redis-<env>`); роль мониторинга — из `db.env` контура,
  её подставляет `infra/monitoring/up.sh` как `PROD_*`/`TEST_*` (одинаковые имена двух
  `db.env` через `--env-file` не развести). cAdvisor, node-exporter и Grafana — в своей
  сети `monitoring`; Grafana ещё в `wallet-test` (база `perf_history` есть только там).
  Метрики контейнеров (cAdvisor) метки `env` не несут: cAdvisor видит контейнер по id.
  Дашборды Grafana получают переменную `env`, фильтр `env=~"$env"` стоит у метрик
  `http_*`, `pg_*`, `redis_*`, `tg_*`.
- **Риск.** Prometheus оказывается в обеих сетях. Пакеты между сетями он не маршрутизирует,
  но его компрометация дала бы доступ к обоим контурам. Принимается так же, как Jenkins с `docker.sock`.

## Risks / Trade-offs

- **[Ручной `docker compose up` в каталоге wallet-infra]** → без `WALLET_ENV` и тегов compose
  падает на `${VAR:?}`. Запуск только через `up.sh`.
- **[Нет dev-контура]** Каждая проверка правки — rc-тег и сборка в CI (минуты).
  → Это осознанный выбор. Юнит- и интеграционные тесты сервисов по-прежнему идут в CI.
- **[Место на `/`]** Тома docker и образы лежат в `/var/lib/docker`.
  → Prune перед первым pull, чистка старых образов в `deploy.sh` (оставлять 3 версии на сервис),
  дампы на DATA.
- **[OOM-killer убивает prod]** Chrome, LLM или локальная сборка C++ съедают память хоста.
  → `oom_score_adj` (D10): первым умирает test; `restart: unless-stopped` поднимает убитое.
  Локальные сборки C++ по-прежнему идут по одной.
- **[Квота GitHub Packages]** → чистка старых версий (`actions/delete-package-versions`,
  оставлять 10 последних). Если квоты не хватит, `registry:2` на хосте; меняется только
  префикс образа в `compose.yaml`.
- **[Откат кода без отката схемы]** → правило expand/contract (D4) и дамп перед каждой
  миграцией prod (D6).
- **[Двойной бот]** Два процесса на токене @WalletTransaction_bot получают 409.
  → Стек `servers` снесён до переключения; токен prod-бота только в секретах prod.
- **[Нет отката на старый стек]** `servers` и его данные удалены 2026-10-24 до подъёма prod.
  → Если prod не поднимется, его чинят на месте (версии сервисов — `deploy.sh --rollback`,
  описание контура — откат тега wallet-infra); данных, которые жалко, в нём ещё нет.
- **[Перезаливка тащит prod-данные в test]** → вычистка сессий и привязок (спека
  test-data-refresh). Права только на чтение при дампе.
- **[Jenkins с `docker.sock`]** Компрометация Jenkins даёт доступ к обоим контурам.
  Риск принимается, как сейчас.
- **[Loadtest по prod]** Нынешние loadtest-job'ы бьют в живой стек.
  → Перенацеливаются на сеть `wallet-test`.

## Migration Plan

Данные стека `servers` были тестовыми и не переносятся: prod стартует с пустыми базами.

1. ✅ Prune docker, `docker login ghcr.io`, секреты test (2026-10-24).
2. ✅ Первые rc всех сервисов в ghcr, test поднят через `up.sh test` (2026-10-24).
   Осталось: ручной сценарий через `:8091` (задача 5.4).
3. ✅ Старый стек `servers` снесён: контейнеры, тома `servers_db-data` и `servers_redis-data`,
   образы `servers-*` (2026-10-24). Сеть `wallet-net` остаётся, пока к ней подключён стек
   метрик (раздел 8). @WalletTransaction_bot и `:8090` офлайн до шага 4.
4. Подъём prod:
   1. секреты prod, финальные теги, проверенные в test;
   2. `up.sh prod` (миграции четырёх баз на пустых томах, затем сервисы);
   3. обновить стек логов и метрик под новые сети и префиксы;
   4. smoke через `:8090`, вход в веб, синк с Android, привязка @WalletTransaction_bot заново.

   Пользователи входят заново, привязки бота делаются заново. Android-клиенту на Pixel
   нужно выйти и войти: его прежний токен подписан старым ключом.
5. **Если prod не поднялся:** отката на старый стек нет. Чинится на месте: сервис —
   `deploy.sh prod <сервис> <прежний тег> --rollback`, описание контура — прежний тег
   wallet-infra; в крайнем случае `env_compose down -v` и `up.sh prod` заново (данных ещё нет).

## Open Questions

- Имя test-бота (`@WalletTransactionTest_bot` или другое) — решается при регистрации в BotFather.
- Нужны ли демо-данные в сиде test. Пока нет, `infra/db/seed/` добавляется по необходимости.
- Текущая квота GitHub Packages организации — проверяется в Settings → Billing до задачи 3.
