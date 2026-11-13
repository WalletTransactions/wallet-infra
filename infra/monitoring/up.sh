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
#
# Пароли Grafana — тоже не из репозитория (он публичный):
# - GRAFANA_ADMIN_PASSWORD — из $SECRETS_ROOT/monitoring.env (нет файла —
#   создаётся со случайным паролем, chmod 600);
# - PERF_READER_POSTGRES_PASSWORD — из db.env контура test (роль perf_reader,
#   источник "Perf History"; тот же пароль роли выставляет migrate.sh test perf).
# После старта пароль admin перезадаётся через grafana cli: переменная
# GF_SECURITY_ADMIN_PASSWORD действует только при создании базы Grafana.
set -euo pipefail

MONITORING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_ROOT="${WALLET_SECRETS_ROOT:-$HOME/.config/wallet-secrets}"

mon_env="$SECRETS_ROOT/monitoring.env"
if [[ ! -f "$mon_env" ]]; then
    echo "==> нет $mon_env — создаю со случайным паролем Grafana"
    ( umask 077; printf 'GRAFANA_ADMIN_PASSWORD=%s\n' "$(openssl rand -hex 16)" > "$mon_env" )
fi
GRAFANA_ADMIN_PASSWORD="$(sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' "$mon_env" | tail -n1)"
[[ -n "$GRAFANA_ADMIN_PASSWORD" ]] || { echo "ОШИБКА: в $mon_env не задан GRAFANA_ADMIN_PASSWORD" >&2; exit 1; }
export GRAFANA_ADMIN_PASSWORD

PERF_READER_POSTGRES_PASSWORD="$(sed -n 's/^PERF_READER_POSTGRES_PASSWORD=//p' "$SECRETS_ROOT/test/db.env" 2>/dev/null | tail -n1)"
[[ -n "$PERF_READER_POSTGRES_PASSWORD" ]] \
    || { echo "ОШИБКА: в $SECRETS_ROOT/test/db.env не задан PERF_READER_POSTGRES_PASSWORD (см. infra/db/.env.example)" >&2; exit 1; }
export PERF_READER_POSTGRES_PASSWORD

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

# Пароль admin — из monitoring.env и для уже существующего тома grafana-data.
# Через stdin, не аргументом: аргументы видны в списке процессов.
printf '%s\n' "$GRAFANA_ADMIN_PASSWORD" \
    | docker compose -f "$MONITORING_DIR/compose.yaml" exec -T grafana \
        grafana cli --homepath /usr/share/grafana admin reset-admin-password --password-from-stdin >/dev/null
echo "==> пароль admin Grafana задан из $mon_env"

docker compose -f "$MONITORING_DIR/compose.yaml" ps --format 'table {{.Service}}\t{{.Status}}'
