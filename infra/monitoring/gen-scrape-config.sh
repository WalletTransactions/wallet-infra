#!/bin/bash
# Генерирует scrape-конфиг сервисов проекта для Prometheus (change add-internal-mtls, задача 8.1).
#
#   bash infra/monitoring/gen-scrape-config.sh [каталог-вывода]
#
# Зачем отдельно от prometheus.yml: при взаимном TLS (WALLET_INTERNAL_MTLS=true в контуре)
# сервисы отдают /metrics только по https с клиентским сертификатом `prometheus` ЭТОГО контура
# (у каждого контура свой CA — сертификат test не годится для prod, и наоборот). `tls_config` в
# Prometheus задаётся на задание целиком, поэтому задания делаются на пару сервис × контур
# (wallet-api-test, wallet-api-prod), а метка `job` возвращается relabel'ом к имени сервиса —
# дашборды и запросы видят то же, что и раньше (job, env).
#
# Режим контура читается из развёрнутого описания (<state>/<env>/infra/infra/env/<env>.env), а не
# из рабочей копии: мониторинг следует за тем, что реально выкачено. Выключен — те же цели по
# обычному HTTP, что и всегда. Включён — https, ca_file/cert_file/key_file из
# <state>/<env>/generated/mtls/prometheus (монтируется в контейнер Prometheus, см. compose.yaml).
# Исключения (design D9): гейтвей отдаёт метрики на служебном mTLS-порту :8443 (входной порт
# остаётся HTTP); google-auth — на служебном mTLS-порту :8442 (SERVICE_MTLS_PORT), публичный :8080
# остаётся HTTP для гейтвея и JWKS, но /metrics на нём нет.
#
# Печатает на stdout пути для compose: PROM_SCRAPE_DIR, PROM_MTLS_TEST_DIR, PROM_MTLS_PROD_DIR.
set -euo pipefail

STATE_ROOT="${WALLET_STATE_ROOT:-$HOME/.local/state/wallet-envs}"
OUT_DIR="${1:-$STATE_ROOT/monitoring/scrape}"
ENVS="${WALLET_MON_ENVS:-prod test}"
mkdir -p "$OUT_DIR"

# имя:порт:порт-при-mTLS (гейтвей на mTLS — служебный порт)
SERVICES=(
    "google-auth:8080:8442"
    "wallet-api:8082:8082"
    "wallet-report:8084:8084"
    "wallet-gateway:8090:8443"
    "wallet-telegram:8086:8086"
    "wallet-ai:8087:8087"
    "wallet-mcp:8088:8088"
    "wallet-docs:8089:8089"
)

mtls_on() {
    local env="$1" f="$STATE_ROOT/$1/infra/infra/env/$1.env"
    [[ -f "$f" ]] && [[ "$(sed -n 's/^WALLET_INTERNAL_MTLS=//p' "$f" | tail -n1)" == "true" ]]
}

empty_dir="$STATE_ROOT/monitoring/empty"
mkdir -p "$empty_dir"
declare -A MTLS_DIR=([prod]="$empty_dir" [test]="$empty_dir")

tmp="$(mktemp "$OUT_DIR/services.yml.XXXXXX")"
{
    echo "# Сгенерирован infra/monitoring/gen-scrape-config.sh — не править руками."
    echo "# HTTP-сервисы проекта: RPS/latency/errors на /metrics (src/util/metrics.hpp в каждом сервисе)."
    echo "# wallet-docs — необязательный модуль: без профиля docs цель просто down, это штатно."
    echo "scrape_configs:"
    for env in $ENVS; do
        tls=0
        if mtls_on "$env"; then
            tls=1
            dir="$STATE_ROOT/$env/generated/mtls/prometheus"
            for f in ca.pem tls.crt tls.key; do
                [[ -s "$dir/$f" ]] || { echo "ОШИБКА: в контуре $env включён mTLS, но нет $dir/$f (выполните up.sh $env)" >&2; exit 1; }
            done
            MTLS_DIR[$env]="$dir"
        fi
        for entry in "${SERVICES[@]}"; do
            IFS=: read -r svc port mport <<<"$entry"
            use_tls=$tls
            p="$port"
            [[ $use_tls -eq 1 ]] && p="$mport"
            echo "  - job_name: $svc-$env"
            if [[ $use_tls -eq 1 ]]; then
                echo "    scheme: https"
                echo "    tls_config:"
                echo "      ca_file: /etc/prometheus/mtls/$env/ca.pem"
                echo "      cert_file: /etc/prometheus/mtls/$env/tls.crt"
                echo "      key_file: /etc/prometheus/mtls/$env/tls.key"
            fi
            echo "    static_configs:"
            echo "      - targets: [\"$svc-$env:$p\"]"
            echo "        labels: {env: $env}"
            echo "    relabel_configs:"
            echo "      - target_label: job"
            echo "        replacement: $svc"
        done
    done
} > "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$OUT_DIR/services.yml"

echo "PROM_SCRAPE_DIR=$OUT_DIR"
echo "PROM_MTLS_TEST_DIR=${MTLS_DIR[test]}"
echo "PROM_MTLS_PROD_DIR=${MTLS_DIR[prod]}"
