# Proposal

## Why

В стек добавляется новый сервис `wallet-mcp` (репозиторий
`WalletTransactions/wallet-mcp`): MCP-сервер только на чтение, через который
LM Studio, а позже любой MCP-клиент отвечает на вопросы о тратах. Его нужно
поднять в обоих контурах (prod и test), подключить к гейтвею и мониторингу и
выкатывать тем же конвейером CI → Jenkins, что и остальные сервисы.

## What Changes

- Сервис `wallet-mcp` в `compose.yaml`: образ
  `ghcr.io/wallettransactions/wallet-mcp:${WALLET_MCP_TAG:?}`, порт 8088 внутри
  сети контура (наружу не публикуется), alias `wallet-mcp-${WALLET_ENV}`,
  `mem_limit` как у лёгких сервисов. Своей БД нет, Redis не нужен.
  Окружение: `AUTH_SERVICE_URL=http://google-auth:8080` (обмен токена и JWKS),
  `WALLET_REPORT_URL=http://wallet-report:8084`.
- Гейтвей получает `WALLET_MCP_URL=http://wallet-mcp:8088` (change
  `wallet-gateway/openspec/changes/add-mcp-route`).
- Тег образа `WALLET_MCP_TAG` в `tags.env` контура (его ведёт `deploy.sh`,
  первый раз — руками), healthcheck по `/healthz`.
- Prometheus: цели `wallet-mcp-prod:8088` и `wallet-mcp-test:8088` с меткой
  `env`. В Grafana — панель вызовов инструментов и обменов токена.
- Выкат: Jenkins-job для тегов `wallet-mcp` по образцу остальных сервисов
  (миграций нет, остаётся smoke `/healthz` и `401` на `/api/mcp/` без токена).
- Порядок выката фичи: google-auth и wallet-api (миграция) → wallet-report →
  wallet-mcp → гейтвей с `WALLET_MCP_URL` → wallet-web.

## Capabilities

### New Capabilities
<!-- нет -->

### Modified Capabilities
<!-- нет: требования стенда (два контура, изоляция данных и токенов, единый
     мониторинг, конвейер выката) не меняются — wallet-mcp становится ещё одним
     сервисом под те же правила. MCP-токены изолированы по контурам
     автоматически: у test свой ключ подписи JWT и свой Redis. Поэтому change
     помечен skip_specs: true. -->

## Impact

- **wallet-infra:** `compose.yaml`, `infra/env/lib.sh`, `infra/env/deploy.sh`,
  `infra/env/README.md`, `infra/monitoring/prometheus.yml` и дашборд,
  whitelist контейнеров в `infra/logging/fluent-bit.conf`, корневой `README.md`.
- **Зависимость:** change `add-prod-test-environments` (контуры, теги образов,
  Jenkins-job'ы по тегам). Если он ещё не завершён, wallet-mcp
  подключается в его текущем виде.
- **BuildPlatform (Jenkins, вне git):** новый job выката `wallet-mcp`.
- **GitHub Actions:** сборка образа в репозитории `wallet-mcp`.
- **Ресурсы хоста:** лёгкий C++-сервис без БД и без GPU, RAM в пределах
  десятков МБ на контур. Сборка — как у остальных C++-сервисов, по одной за раз.
