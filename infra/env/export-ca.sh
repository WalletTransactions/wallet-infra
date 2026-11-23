#!/bin/bash
# Выгружает ПУБЛИЧНЫЙ корневой сертификат CA контура (режимы internal и
# tailscale, change add-tls-ingress) — для установки на устройства:
# браузеры, Android («Сертификат ЦС»). Корень берётся из секретов контура
# (<secrets>/tls-ca/root.crt, change tls-ca-in-secrets), а до переноса — из тома
# wallet-<env>_tls-data. Читается только root.crt; в выгруженном файле
# проверяется, что ключа нет. Тот же файл прокси отдаёт по https://<адрес>/ca.crt.
#
# Использование:
#   infra/env/export-ca.sh <prod|test> [файл]   (по умолчанию ./wallet-<env>-root.crt)
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

env_init "${1:-}"
out="${2:-./wallet-$ENV_NAME-root.crt}"

env_tls_enabled || die "TLS в контуре $ENV_NAME выключен (WALLET_TLS в infra/env/$ENV_NAME.env)"
mode="$(env_setting WALLET_TLS_MODE)"
[[ "${mode:-internal}" != "files" ]] \
    || die "WALLET_TLS_MODE=files: своего CA у прокси нет — корень выдаёт тот, кто выпустил сертификат"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if [[ -s "$SECRETS_DIR/tls-ca/root.crt" ]]; then
    # Корень в секретах (tls-ca-in-secrets): читается только публичный root.crt.
    cat "$SECRETS_DIR/tls-ca/root.crt" > "$tmp"
else
    # До переноса (tls-ca-init.sh) корень есть только в томе прокси.
    env_compose exec -T tls-proxy cat /data/caddy/pki/authorities/local/root.crt > "$tmp" \
        || die "не удалось прочитать root.crt из tls-proxy (контур поднят? CA появляется после первого запуска прокси)"
fi
openssl x509 -in "$tmp" -noout 2>/dev/null || die "выгруженный файл — не сертификат X.509"
! grep -q PRIVATE "$tmp" || die "в выгруженном файле закрытый ключ — файл не сохранён"
mv "$tmp" "$out"
chmod 644 "$out"
trap - EXIT

echo "==> корень CA контура $ENV_NAME: $out"
openssl x509 -in "$out" -noout -subject -enddate -fingerprint -sha256
