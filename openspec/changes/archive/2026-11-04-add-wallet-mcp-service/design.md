# Design

## Context

Стенд описан change'ем `add-prod-test-environments` (артефакты готовы,
задачи 39/44): один `compose.yaml` на контуры `wallet-prod`/`wallet-test`,
запуск только через `infra/env/up.sh`. Теги образов лежат в
`~/.local/state/wallet-envs/<env>/tags.env`, их пишет только `deploy.sh`;
секреты — в `~/.config/wallet-secrets/<env>/<сервис>.env`. Выкат общий для
всех сервисов: Jenkins `env-release-watch` → `env-deploy` → `deploy.sh <env>
<сервис> <тег>`. Список сервисов, которые катятся по тегам, — карта
`WALLET_SERVICE_PORT` в `infra/env/lib.sh` (по ней `release-watch.sh` ищет
теги в ghcr, а `deploy.sh` проверяет имя). Smoke в `deploy.sh` общий:
`/healthz` гейтвея и `GET /version` сервиса. Цели Prometheus — по alias
`<сервис>-<env>`. Почему появляется wallet-mcp — proposal.md.

## Goals / Non-Goals

**Goals:**
- wallet-mcp живёт в обоих контурах на общих правилах: образ по тегу,
  выкат и откат через `deploy.sh`, метрики с меткой `env`.
- Падение wallet-mcp не мешает подняться остальному контуру.

**Non-Goals:**
- Публикация wallet-mcp на хост: он доступен только через гейтвей.
- Отдельный Jenkins-job под wallet-mcp. Выкат общий, сервис нужно только
  зарегистрировать (решение 3).
- Дашборд Grafana с нуля: только панели в существующих (решение 5).

## Decisions

**1. Сервис без секретов и без `env_file`.** Вся конфигурация wallet-mcp —
адреса соседей и `HOST`/`PORT` — задаётся в `environment` compose.yaml:
`HOST=0.0.0.0`, `PORT=8088`, `AUTH_SERVICE_URL=http://google-auth:8080`,
`WALLET_REPORT_URL=http://wallet-report:8084`. Секрета у сервиса нет:
обмен токена в google-auth доказывается самим MCP-токеном пользователя.
Поэтому `wallet-mcp.env` не добавляется в `env_check_secrets` и в шаги
«Первого запуска».
*Альтернатива:* пустой `wallet-mcp.env` для единообразия. Отвергнута:
появился бы обязательный файл, который ничего не хранит, и лишняя ошибка
`up.sh` на пустом контуре.

**2. Гейтвей не зависит от wallet-mcp в `depends_on`.** У гейтвея есть
`depends_on` на всех апстримов с `service_healthy`. wallet-mcp — функция
второго плана: если он не поднялся, гейтвей всё равно стартует и отдаёт
`502` на `/api/mcp/*`, а сайт, бот и синк работают. Порядок старта не
важен: гейтвей ходит к апстриму на каждый запрос.
*Альтернатива:* `depends_on: wallet-mcp: service_healthy`, как у wallet-ai.
Отвергнута: сбой MCP-сервиса не должен класть вход в контур.
wallet-mcp сам зависит от `google-auth` и `wallet-report` (`service_healthy`).

**3. Регистрация в общем выкате вместо нового job.** В `lib.sh`
добавляется `WALLET_SERVICE_PORT[wallet-mcp]=8088`. Отсюда `tag_var` даёт
`WALLET_MCP_TAG`, `release-watch.sh` начинает видеть теги в ghcr, а
`deploy.sh` — принимать сервис. В BuildPlatform `wallet-mcp` добавляется в
выбор `SERVICE` у `env-deploy` и `env-rollback` и в список в
`jenkins/README.md`. Отдельные `deploy-<сервис>` job'ы — старый способ до
контуров, их не трогаем.

**4. Smoke wallet-mcp проверяет и отказ без токена.** После общего smoke
`deploy.sh` для `wallet-mcp` выполняет `curl` изнутри контейнера
wallet-mcp: `POST http://127.0.0.1:8088/api/mcp/` без заголовка
`Authorization` должен вернуть `401`. Проверка идёт напрямую, а не через
гейтвей, потому что при первом выкате гейтвей может ещё не знать
`/api/mcp/`. Ответ `200` на анонимный запрос — провал smoke и автооткат:
такой образ раскрыл бы данные без токена. Реализация — функция
`smoke_extra <сервис>` в `deploy.sh`. Для остальных сервисов она пустая,
так что поведение не меняется.

**5. Мониторинг.** Prometheus: `job_name: wallet-mcp`, цели
`wallet-mcp-prod:8088` и `wallet-mcp-test:8088` с `env`. Grafana: строка в
`wallet-overview.json` (вызовы инструментов по имени и исходу, обмены
токена, `up`). Метрики `/api/mcp/*` гейтвея в `api-endpoints.json` уже
видны по метке маршрута `proxy /api/mcp/*`.

**6. Ресурсы.** `mem_limit: 64m`, как у wallet-report/wallet-ai.
Ожидаемый RSS — единицы МБ: нет БД, нет LLM, кеш JWT — десятки строк. На
два контура это меньше 130 МБ лимита, при 14 ГБ RAM хоста. GPU не
использует. Сборка — как у остальных C++-сервисов: в CI, а на хосте — по
одной за раз.

## Risks / Trade-offs

- [compose.yaml с `${WALLET_MCP_TAG:?}` приходит в контур (выкат тега
  wallet-infra), а в `tags.env` переменной ещё нет → `up.sh` падает на всём
  контуре] → в Migration Plan тег записывается в `tags.env` **до** выката
  тега wallet-infra. Это общий порядок для нового сервиса, он описан в
  README.
- [Новый гейтвей без `WALLET_MCP_URL` не стартует] → переменная уходит в
  compose.yaml вместе с сервисом, то есть до выката гейтвея с маршрутом.
  Старый гейтвей лишнюю переменную игнорирует.
- [`/internal/mcp/token` google-auth виден по сети контура всем контейнерам]
  → как и `/internal/telegram/*`, защищён только сетью контура
  (`org/docs/TODO_service_auth_tls.md`, п. 3). Токен 256 бит, перебор
  нереален.
- [Анонимный трафик на `/api/mcp/` доходит до wallet-mcp, мимо JWT-гейта]
  → smoke (решение 4) блокирует выкат образа, который не отвечает `401`.

## Migration Plan

Порядок выката фичи: google-auth и wallet-api (миграция) → wallet-report →
wallet-mcp → гейтвей → wallet-web. Для wallet-infra внутри шага «wallet-mcp»:

1. Опубликовать первый образ wallet-mcp (`v0.1.0-rc.1`) в ghcr (CI
   репозитория wallet-mcp).
2. В обоих контурах вписать в `tags.env` строку `WALLET_MCP_TAG=0.1.0-rc.1`
   (для prod — после проверки в test, финальным тегом). Это единственная
   ручная правка `tags.env`, дальше её ведёт `deploy.sh`.
3. Выкатить тег wallet-infra с сервисом, `WALLET_MCP_URL` у гейтвея,
   регистрацией в `lib.sh`, smoke и Prometheus: сначала test, потом prod.
   `up.sh` поднимает wallet-mcp, smoke гейтвея проходит.
4. BuildPlatform: `wallet-mcp` в выборе `SERVICE` (`env-deploy`,
   `env-rollback`). Следующие теги wallet-mcp катит `env-release-watch` сам.
5. Откат: тег wallet-infra без сервиса — `deploy.sh <env> wallet-infra
   <прежний тег>`. Контейнер wallet-mcp при этом остаётся сиротой, его
   убирает `docker compose up --remove-orphans` или ручной `docker rm`. Это
   записано в README.
