#!/bin/bash
# Взаимный TLS внутри контура (openspec/changes/add-internal-mtls, design D2, D3,
# D8) — подключается из lib.sh, сам не запускается.
#
# Единственный переключатель — WALLET_INTERNAL_MTLS=true в infra/env/<env>.env.
# Выключен (по умолчанию) — этот файл ничего не создаёт, compose.mtls.yaml не
# подключается, и `docker compose config` такой же, как без режима.
#
# Включён — env_mtls_prepare при КАЖДОМ вызове compose (env_compose, как
# env_tls_prepare):
#   - CA контура: $SECRETS_DIR/mtls-ca/{ca.key,ca.crt}. Закрытый ключ CA живёт
#     только там и в контейнеры не монтируется. Свой CA на контур — сертификат
#     test не проходит проверку prod;
#   - ECDSA P-256 сертификат на каждый сервис и клиентский для prometheus:
#     $STATE_DIR/generated/mtls/<имя>/{tls.crt,tls.key,ca.pem}. SAN — `<имя>` и
#     `<имя>-<env>` (алиас для Prometheus), срок WALLET_MTLS_DAYS (30), CN — имя;
#   - повторный запуск ничего не меняет, пока осталось больше половины срока,
#     CA тот же и SAN прежние; иначе сертификат перевыпускается;
#   - WALLET_MTLS_DIR и метки WALLET_MTLS_HASH_<СЕРВИС> (хэш сертификата) для
#     compose.mtls.yaml: изменился сертификат — compose пересоздаёт только его
#     контейнер.
#
# Файлы ключей читаемы всем на хосте (644): контейнер работает под другим uid, а
# монтируется только своя пара. Граница — пользователь хоста, не права файлов.

# Имена сертификатов: сервисы контура и клиент Prometheus. wallet-docs выпускается
# всегда (дёшево), используется только при включённом профиле docs.
# shellcheck disable=SC2034  # используют скрипты, подключающие lib.sh
WALLET_MTLS_NAMES=(google-auth wallet-api wallet-report wallet-ai wallet-gateway
    wallet-telegram wallet-mcp wallet-docs wallet-web prometheus)
WALLET_MTLS_DAYS="${WALLET_MTLS_DAYS:-30}"

env_mtls_enabled() {
    [[ "$(env_setting WALLET_INTERNAL_MTLS)" == "true" ]]
}

# _mtls_hash_var <имя> — google-auth → WALLET_MTLS_HASH_GOOGLE_AUTH.
_mtls_hash_var() {
    local s="${1^^}"
    echo "WALLET_MTLS_HASH_${s//-/_}"
}

# _mtls_ca — создаёт CA контура, если его нет; печатает путь к каталогу CA.
_mtls_ca() {
    local dir="$SECRETS_DIR/mtls-ca"
    mkdir -p "$dir"
    chmod 700 "$dir"
    if [[ ! -s "$dir/ca.key" || ! -s "$dir/ca.crt" ]]; then
        echo "==> [$ENV_NAME] mtls: создаю CA контура ($dir)" >&2
        (
            umask 077
            openssl ecparam -name prime256v1 -genkey -noout -out "$dir/ca.key"
        ) || die "mtls: не удалось создать ключ CA"
        openssl req -x509 -new -key "$dir/ca.key" -sha256 -days 3650 \
            -subj "/CN=wallet-$ENV_NAME-internal-ca" \
            -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
            -addext "keyUsage=critical,keyCertSign,cRLSign" \
            -out "$dir/ca.crt" 2>/dev/null || die "mtls: не удалось создать сертификат CA"
        chmod 600 "$dir/ca.key"
        chmod 644 "$dir/ca.crt"
    fi
    openssl x509 -in "$dir/ca.crt" -noout -checkend $((365 * 86400)) >/dev/null \
        || die "mtls: сертификат CA $dir/ca.crt истекает менее чем через год — пересоздайте CA (удалите $dir и перезапустите: сертификаты всех сервисов выпустятся заново)"
    echo "$dir"
}

# _mtls_needs_issue <имя> <каталог> <ca.crt> — 0, если сертификат нужно (пере)выпустить.
_mtls_needs_issue() {
    local name="$1" out="$2" ca="$3" half=$((WALLET_MTLS_DAYS * 86400 / 2))
    [[ -s "$out/tls.crt" && -s "$out/tls.key" ]] || return 0
    openssl verify -CAfile "$ca" "$out/tls.crt" >/dev/null 2>&1 || return 0
    openssl x509 -in "$out/tls.crt" -noout -checkend "$half" >/dev/null 2>&1 || return 0
    local host
    for host in "$name" "$name-$ENV_NAME"; do
        openssl x509 -in "$out/tls.crt" -noout -checkhost "$host" 2>/dev/null \
            | grep -q 'does match' || return 0
    done
    return 1
}

# _mtls_install <файл-источник> <назначение> <права> — атомарно, только если содержимое изменилось.
_mtls_install() {
    local src="$1" dst="$2" mode="$3"
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        chmod "$mode" "$dst"
        return 0
    fi
    local tmp
    tmp="$(mktemp "$dst.XXXXXX")"
    cp "$src" "$tmp"
    chmod "$mode" "$tmp"
    mv "$tmp" "$dst"
}

# _mtls_issue <имя> <каталог CA> <каталог результата> — выпускает сертификат сервиса.
_mtls_issue() {
    local name="$1" ca_dir="$2" out="$3" tmp
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064  # tmp нужен именно сейчас
    trap "rm -rf '$tmp'" RETURN
    openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/k.pem" \
        || die "mtls: не удалось создать ключ $name"
    openssl req -new -key "$tmp/k.pem" -subj "/CN=$name" -out "$tmp/r.csr" \
        || die "mtls: не удалось создать запрос $name"
    cat > "$tmp/ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=DNS:$name,DNS:$name-$ENV_NAME
EOF
    openssl x509 -req -in "$tmp/r.csr" -CA "$ca_dir/ca.crt" -CAkey "$ca_dir/ca.key" \
        -set_serial "0x$(openssl rand -hex 8)" -days "$WALLET_MTLS_DAYS" -sha256 \
        -extfile "$tmp/ext" -out "$tmp/c.pem" 2>/dev/null \
        || die "mtls: не удалось выпустить сертификат $name"
    mkdir -p "$out"
    chmod 755 "$out"
    # Ключ раньше сертификата: сервис не должен увидеть новый сертификат со старым ключом.
    _mtls_install "$tmp/k.pem" "$out/tls.key" 644
    _mtls_install "$tmp/c.pem" "$out/tls.crt" 644
    echo "==> [$ENV_NAME] mtls: выпущен сертификат $name (до $(openssl x509 -in "$out/tls.crt" -noout -enddate | cut -d= -f2))" >&2
}

# env_mtls_prepare — см. шапку файла. Один раз на процесс; ошибки — die до действий с контуром.
env_mtls_prepare() {
    [[ "${WALLET_MTLS_PREPARED:-}" == "$ENV_NAME" ]] && return 0
    local value
    value="$(env_setting WALLET_INTERNAL_MTLS)"
    [[ -z "$value" || "$value" == "true" || "$value" == "false" ]] \
        || die "WALLET_INTERNAL_MTLS=$value в infra/env/$ENV_NAME.env — допустимо: true, false"
    if ! env_mtls_enabled; then
        export WALLET_MTLS_PREPARED="$ENV_NAME"
        return 0
    fi
    command -v openssl >/dev/null || die "mtls: нужен openssl"
    local gen="${WALLET_GENERATED_DIR:-$STATE_DIR/generated}" ca_dir name out
    ca_dir="$(_mtls_ca)" || exit 1
    mkdir -p "$gen/mtls"
    chmod 755 "$gen/mtls"
    for name in "${WALLET_MTLS_NAMES[@]}"; do
        out="$gen/mtls/$name"
        if _mtls_needs_issue "$name" "$out" "$ca_dir/ca.crt"; then
            _mtls_issue "$name" "$ca_dir" "$out"
        fi
        _mtls_install "$ca_dir/ca.crt" "$out/ca.pem" 644
        local var
        var="$(_mtls_hash_var "$name")"
        export "$var=$(sha256sum "$out/tls.crt" "$out/ca.pem" | sha256sum | cut -c1-16)"
    done
    export WALLET_MTLS_DIR="$gen/mtls"
    export WALLET_MTLS_PREPARED="$ENV_NAME"
}

# env_mtls_check_images [сервис[:тег]...] — режим включён: у каждого образа есть
# метка org.wallet.mtls=1 (design D8). Без аргументов — все сервисы контура с тегом
# в tags.env; без :тег — тег из tags.env (deploy.sh передаёт выкатываемый тег).
# Образа нет на хосте — скачивается. Выключен — no-op.
env_mtls_check_images() {
    env_mtls_enabled || return 0
    local -a svcs=("$@") bad=()
    local s tag image label
    if [[ ${#svcs[@]} -eq 0 ]]; then
        for s in "${!WALLET_SERVICE_PORT[@]}"; do
            [[ "$s" == "wallet-docs" ]] && ! env_docs_enabled && continue
            svcs+=("$s")
        done
    fi
    for s in "${svcs[@]}"; do
        tag=""
        if [[ "$s" == *:* ]]; then
            tag="${s#*:}"
            s="${s%%:*}"
        fi
        [[ -n "$tag" ]] || tag="$(current_tag "$s")"
        [[ -n "$tag" ]] || continue
        image="$(image_of "$s" "$tag")"
        docker image inspect "$image" >/dev/null 2>&1 || docker pull -q "$image" >/dev/null \
            || die "mtls: не удалось скачать $image для проверки метки"
        label="$(docker image inspect --format '{{index .Config.Labels "org.wallet.mtls"}}' "$image" 2>/dev/null || true)"
        [[ "$label" == "1" ]] || bad+=("$s:$tag")
    done
    [[ ${#bad[@]} -eq 0 ]] \
        || die "WALLET_INTERNAL_MTLS=true, но образы без метки org.wallet.mtls=1 (собраны без поддержки mTLS): ${bad[*]}. Выкатите версии с поддержкой или выключите режим (design D8)"
}
