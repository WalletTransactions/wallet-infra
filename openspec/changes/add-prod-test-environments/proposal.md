# Proposal

## Why

Сейчас у стека одна среда: compose-проект `servers` на машине разработчика.
Он одновременно и «боевой» (реальные данные, @WalletTransaction_bot, Android-клиент),
и площадка для проверки. Выкат (`BuildPlatform/jobs/deploy-*`) пересобирает образы
из рабочей папки вместе с незакоммиченными правками и сразу катит их на живые
данные: проверить релиз и миграцию где-то до прода негде. k8s-манифесты
(`infra/k8s`) есть, но рассчитаны на одноразовый локальный кластер с образами `:local`
и так и не использовались.

## What Changes

- Два постоянных контура на хосте, оба — compose-проекты docker поверх одного `compose.yaml`:
  **prod** (`wallet-prod`) и **test** (`wallet-test`). Третьего (dev) контура нет.
  У каждого своя сеть docker, свой Postgres и Redis, свои секреты и свой адрес гейтвея.
  - prod остаётся на `http://<хост>:8090`, тот же адрес, что сейчас.
  - test открывается на `http://<хост>:8091`.
- `compose.yaml` перестаёт собирать образы (`build:` уходит) и параметризуется контуром:
  теги образов, порт гейтвея, тома, сеть, приоритет памяти. Различия контуров лежат
  в двух файлах настроек в git (`infra/env/{prod,test}.env`) и в секретах вне git.
- Образы собирает CI в `ghcr.io/walletransactions/<сервис>`, а не хост.
  - Git-тег `vX.Y.Z-rc.N` в репозитории сервиса выкатывается в test.
  - Тег `vX.Y.Z` на том же коммите выкатывается в prod. Это тот же образ
    (тот же digest), что прошёл test, без пересборки.
- Новые Jenkins job'ы следят за тегами и выкатывают их в нужный контур.
  Порядок выката: миграции, потом сервис, потом smoke-проверка. Если smoke
  не прошёл, автоматически возвращается предыдущий образ.
  - Перед миграциями в prod снимается дамп БД.
  - В prod попадает только digest, который прошёл smoke в test.
- В test свой Telegram-бот (отдельный токен), свой ключ подписи JWT, свои пароли БД.
  Google OAuth-клиент общий, к нему добавляется redirect URI для test.
- Данные test: по умолчанию пустая БД со схемой. По кнопке её можно перезалить
  из дампа prod с вычисткой сессий и Telegram-секретов.
- prod стартует с пустыми базами, как и test. Данные нынешнего стека `servers` фактически
  тестовые и не переносятся; его тома удаляются после подтверждения prod.
- Стек логов (OpenSearch) и метрик (Prometheus, Grafana) остаётся один на оба контура.
  Контур различается суффиксом: префикс контейнера `wallet-prod-`/`wallet-test-`
  даёт поле `env` в логах, alias'ы `<сервис>-prod`/`<сервис>-test` и метка `env`
  — в метриках.
- **BREAKING**:
  - `docker compose up --build` из рабочей папки больше не поднимает стек: образы
    берутся только из ghcr, а запуск идёт через `infra/env/up.sh <env>`.
    Проверка правок — через rc-тег в test.
  - Job'ы `deploy-*`, `deploy-all`, `deploy-servers` и `db-migrate` удаляются.
    Loadtest-job'ы перенацеливаются на test.
  - Сеть `wallet-net` и префикс логов `servers-` заменяются на сети и префиксы контуров.
  - `infra/k8s` и `apply.sh` удаляются.

## Capabilities

### New Capabilities

- `deployment-environments`: какие контуры есть, чем они изолированы друг от друга,
  по какому адресу открываются и какие внешние интеграции (бот, OAuth, LLM) у каждого.
- `release-promotion`: как версия сервиса попадает в test, а затем в prod. Сюда входят
  теги, единый образ, порядок миграций и сервисов, smoke, откат, дамп перед миграцией в prod.
- `test-data-refresh`: исходное наполнение test и перезаливка его данных из prod
  с обязательной вычисткой.
- `environment-observability`: общие логи и метрики обоих контуров с различением по контуру.

### Modified Capabilities

Нет: у `wallet-infra` пока нет спек.

## Impact

- **wallet-infra**:
  - `compose.yaml` переписывается под контуры: без `build:`, с переменными контура.
  - Новые `infra/env/`: настройки контуров, `up.sh`, `migrate.sh`, `deploy.sh`,
    `backup.sh`, `test-refresh.sh`.
  - `infra/db/init-db.sh`: роль `dumper`. `infra/db/migrate.sh` заменяется `infra/env/migrate.sh`.
  - `infra/logging` и `infra/monitoring` различают контуры.
  - Удаляется `infra/k8s`. Правятся README (корневой, `infra/db`, `infra/env`).
- **Хост**:
  - Ничего нового не ставится, всё на docker.
  - Секреты по контурам кладутся в `~/.config/wallet-secrets/{prod,test}/`,
    состояние выкатов — в `~/.local/state/wallet-envs/{prod,test}/`.
  - Расход памяти: около +400 МБ на контур test при 14 ГБ всего.
- **Репозитории сервисов** (google-auth, wallet-api, wallet-report, wallet-ai,
  wallet-gateway, wallet-web, wallet-telegram): в GitHub Actions добавляется
  push образа в ghcr по тегу и перетег rc в финальную версию; миграции кладутся в образ.
- **BuildPlatform** (не в git): новые job'ы:
  - `env-release-watch`;
  - `env-deploy` и `env-rollback`;
  - `env-test-refresh`;
  - `prod-backup`.

  Старые compose-job'ы удаляются, loadtest-job'ы смотрят в test.
- **Внешнее**:
  - Новый бот в BotFather для test.
  - Новый redirect URI в Google Cloud Console.
  - Токен `read:packages` для подтягивания образов из ghcr.
- **Вне объёма**:
  - Android-сборка, смотрящая в test.
  - Публичный домен и TLS.
  - Локальный запуск сервисов в контейнерах из рабочей папки.
