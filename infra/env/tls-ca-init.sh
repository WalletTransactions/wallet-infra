#!/bin/bash
# Кладёт корень CA контура для TLS на входе в секреты (change tls-ca-in-secrets):
# <secrets>/tls-ca/root.crt и root.key (600). Выполняется ОДИН РАЗ на хосте, не в
# Jenkins: тот монтирует секреты только на чтение.
#
#   bash infra/env/tls-ca-init.sh <prod|test>
#
# Если в томе wallet-<env>_tls-data уже есть CA Caddy, переносится ЭТОТ ЖЕ корень:
# установленный на устройства корень остаётся годным. Иначе создаётся новый.
# Повторный запуск ничего не меняет, если корень в секретах уже есть.
# Закрытый ключ не печатается; ключ в томе остаётся (Caddy его больше не читает).
# Подхватывается следующим up.sh / выкатом wallet-infra.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

env_init "${1:-}"
dir="$SECRETS_DIR/tls-ca"

fingerprint() {
    openssl x509 -in "$dir/root.crt" -noout -fingerprint -sha256 | cut -d= -f2
}

if [[ -e "$dir" ]]; then
    _tls_ca_check "$dir"
    echo "корень CA контура $ENV_NAME уже в секретах: $dir/root.crt (SHA-256 $(fingerprint))"
    exit 0
fi

[[ -d "$SECRETS_DIR" ]] || die "нет каталога секретов $SECRETS_DIR (см. infra/env/README.md)"
[[ -w "$SECRETS_DIR" ]] || die "каталог секретов $SECRETS_DIR недоступен для записи — запустите на хосте"

tmp="$(mktemp -d "$SECRETS_DIR/.tls-ca.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"

volume="wallet-${ENV_NAME}_tls-data"
pki=/data/caddy/pki/authorities/local
image="$(sed -n 's/^ *image: *\(docker.io\/library\/caddy:[^ ]*\).*/\1/p' "$WALLET_INFRA_DIR/compose.yaml" | head -n1)"
[[ -n "$image" ]] || die "не нашёл образ Caddy в compose.yaml"

# read_volume <файл> — файл из тома CA, через одноразовый контейнер (том только на чтение).
read_volume() {
    docker run --rm --network none -v "$volume:/data:ro" --entrypoint cat "$image" "$pki/$1"
}

if docker volume inspect "$volume" >/dev/null 2>&1 && read_volume root.crt > "$tmp/root.crt" 2>/dev/null; then
    echo "==> [$ENV_NAME] переношу корень CA из тома $volume"
    ( umask 077; read_volume root.key > "$tmp/root.key" ) \
        || die "в томе $volume есть root.crt, но не удалось прочитать root.key"
else
    echo "==> [$ENV_NAME] CA в томе нет — создаю новый корень"
    ( umask 077; openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/root.key" ) \
        || die "не удалось создать ключ CA"
    openssl req -x509 -new -key "$tmp/root.key" -sha256 -days 3650 \
        -subj "/CN=wallet-$ENV_NAME TLS root" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -out "$tmp/root.crt" 2>/dev/null || die "не удалось создать сертификат CA"
fi

chmod 600 "$tmp/root.key"
chmod 644 "$tmp/root.crt"
_tls_ca_check "$tmp"
mv "$tmp" "$dir"
trap - EXIT

echo "корень CA контура $ENV_NAME: $dir/root.crt"
echo "  SHA-256 $(fingerprint)"
echo "  до $(openssl x509 -in "$dir/root.crt" -noout -enddate | cut -d= -f2)"
echo "Применить: up.sh $ENV_NAME или выкат wallet-infra. Корень для устройств — https://<адрес>:<порт>/ca.crt"
