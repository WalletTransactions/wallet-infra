#!/bin/bash
# Поднимает стек метрик (Prometheus, Grafana, экспортёры) для обоих контуров.
#
# Использование:
#   bash infra/monitoring/up.sh
#
# Экспортёрам postgres нужна роль мониторинга КАЖДОГО контура — она в
# ~/.config/wallet-secrets/<env>/db.env (WALLET_SECRETS_ROOT переопределяет
# корень, как у infra/env). Скрипт берёт оттуда только три значения на
# контур и отдаёт их compose.yaml как PROD_*/TEST_*: одинаковые имена
# переменных двух db.env через --env-file не развести. Значения не печатает.
#
# Сети wallet-prod/wallet-test создаёт, если их ещё нет (контур поднимается
# позже) — compose.yaml держит их как external.
set -euo pipefail

MONITORING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_ROOT="${WALLET_SECRETS_ROOT:-$HOME/.config/wallet-secrets}"

for env in prod test; do
    db_env="$SECRETS_ROOT/$env/db.env"
    [[ -f "$db_env" ]] || { echo "ОШИБКА: нет $db_env (см. infra/env/README.md)" >&2; exit 1; }
    prefix="${env^^}"
    for var in MONITORING_POSTGRES_USER MONITORING_POSTGRES_PASSWORD MIGRATOR_POSTGRES_DB; do
        value="$(sed -n "s/^${var}=//p" "$db_env" | tail -n1)"
        [[ -n "$value" ]] || { echo "ОШИБКА: в $db_env не задан $var" >&2; exit 1; }
        export "${prefix}_${var}=$value"
    done
    if ! docker network inspect "wallet-$env" >/dev/null 2>&1; then
        echo "==> создаю сеть wallet-$env"
        docker network create "wallet-$env" >/dev/null
    fi
done

docker compose -f "$MONITORING_DIR/compose.yaml" up -d --remove-orphans
docker compose -f "$MONITORING_DIR/compose.yaml" ps --format 'table {{.Service}}\t{{.Status}}'
