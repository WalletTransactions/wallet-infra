#!/bin/bash
# Взаимный TLS внутри контура (openspec/changes/add-internal-mtls, design D2, D3,
# D8) — подключается из lib.sh, сам не запускается.
#
# Два независимых переключателя в infra/env/<env>.env (design D10):
#   - WALLET_INTERNAL_MTLS=true — весь контур (compose.mtls.yaml). Подразумевает
#     и второй переключатель для всех трёх клиентов;
#   - WALLET_AUTH_MTLS_CLIENTS=wallet-telegram[,wallet-mcp,wallet-ai] — только
#     служебный порт google-auth для перечисленных клиентов (compose.auth-mtls.yaml):
#     критичный путь выдачи токенов защищается раньше остального контура, клиенты
#     переносятся по одному. WALLET_AUTH_IDENTITY — режим проверки идентичности
#     на этом порту (INTERNAL_IDENTITY google-auth, по умолчанию observe).
# Оба выключены (по умолчанию) — этот файл ничего не создаёт, дополнительные
# compose-файлы не подключаются, и `docker compose config` такой же, как без режима.
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

# Клиенты служебного порта google-auth (/internal/*, сеть auth-internal).
# shellcheck disable=SC2034
WALLET_AUTH_MTLS_ALL=(wallet-telegram wallet-mcp wallet-ai)

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
    if [[ ! -s "$dir/ca.key" || ! -s "$dir/ca.crt" ]]; then
        # Jenkins монтирует секреты только на чтение: CA создаётся один раз на хосте
        # (infra/env/mtls-init.sh), выкат его только читает.
        [[ -w "$SECRETS_DIR" ]] \
            || die "mtls: нет CA контура ($dir), а каталог секретов недоступен для записи (в Jenkins он read-only). Создайте CA один раз на хосте: bash infra/env/mtls-init.sh $ENV_NAME"
        mkdir -p "$dir"
        chmod 700 "$dir"
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

# _mtls_load_clients — разбирает WALLET_AUTH_MTLS_CLIENTS в массив
# WALLET_AUTH_MTLS_SELECTED (не в подоболочке: die должен завершать скрипт). При
# WALLET_INTERNAL_MTLS=true — все клиенты. Идентичность проверяется здесь же.
_mtls_load_clients() {
    [[ "${WALLET_AUTH_MTLS_LOADED:-}" == "$ENV_NAME" ]] && return 0
    WALLET_AUTH_MTLS_SELECTED=()
    local value
    value="$(env_setting WALLET_INTERNAL_MTLS)"
    [[ -z "$value" || "$value" == "true" || "$value" == "false" ]] \
        || die "WALLET_INTERNAL_MTLS=$value в infra/env/$ENV_NAME.env — допустимо: true, false"
    if [[ "$value" == "true" ]]; then
        WALLET_AUTH_MTLS_SELECTED=("${WALLET_AUTH_MTLS_ALL[@]}")
    else
        local raw c ok a
        raw="$(env_setting WALLET_AUTH_MTLS_CLIENTS)"
        raw="${raw// /}"
        local -a items=()
        IFS=',' read -ra items <<<"$raw"
        for c in "${items[@]}"; do
            [[ -n "$c" ]] || continue
            ok=0
            for a in "${WALLET_AUTH_MTLS_ALL[@]}"; do
                [[ "$a" == "$c" ]] && ok=1
            done
            [[ $ok -eq 1 ]] || die "WALLET_AUTH_MTLS_CLIENTS: '$c' — допустимо: ${WALLET_AUTH_MTLS_ALL[*]}"
            WALLET_AUTH_MTLS_SELECTED+=("$c")
        done
    fi
    local identity
    identity="$(env_setting WALLET_AUTH_IDENTITY)"
    if [[ -n "$identity" ]]; then
        local mode='(off|observe|enforce-tls|enforce)'
        [[ "$identity" =~ ^${mode}?(,(telegram|mcp-token|exchange)=${mode})*$ ]] \
            || die "WALLET_AUTH_IDENTITY=$identity в infra/env/$ENV_NAME.env — режим (off, observe, enforce-tls, enforce) и исключения вида telegram=enforce"
    fi
    # Не export: массив WALLET_AUTH_MTLS_SELECTED в дочерние процессы не передаётся, и
    # флаг «загружено» из окружения родителя оставил бы потомка без массива (set -u).
    WALLET_AUTH_MTLS_LOADED="$ENV_NAME"
}

# env_auth_mtls_enabled — включён mTLS служебного порта (хотя бы один клиент).
env_auth_mtls_enabled() {
    _mtls_load_clients
    [[ ${#WALLET_AUTH_MTLS_SELECTED[@]} -gt 0 ]]
}

# env_mtls_prepare — см. шапку файла. Один раз на процесс; ошибки — die до действий с контуром.
env_mtls_prepare() {
    [[ "${WALLET_MTLS_PREPARED:-}" == "$ENV_NAME" ]] && return 0
    _mtls_load_clients
    if ! env_mtls_enabled && ! env_auth_mtls_enabled; then
        export WALLET_MTLS_PREPARED="$ENV_NAME"
        return 0
    fi
    command -v openssl >/dev/null || die "mtls: нужен openssl"
    local gen="${WALLET_GENERATED_DIR:-$STATE_DIR/generated}" ca_dir name out var
    ca_dir="$(_mtls_ca)" || exit 1
    mkdir -p "$gen/mtls"
    chmod 755 "$gen/mtls"
    local -a names=()
    if env_mtls_enabled; then
        names=("${WALLET_MTLS_NAMES[@]}")
    else
        names=(google-auth "${WALLET_AUTH_MTLS_SELECTED[@]}")
    fi
    for name in "${names[@]}"; do
        out="$gen/mtls/$name"
        if _mtls_needs_issue "$name" "$out" "$ca_dir/ca.crt"; then
            _mtls_issue "$name" "$ca_dir" "$out"
        fi
        _mtls_install "$ca_dir/ca.crt" "$out/ca.pem" 644
        var="$(_mtls_hash_var "$name")"
        export "$var=$(sha256sum "$out/tls.crt" "$out/ca.pem" | sha256sum | cut -c1-16)"
    done
    export WALLET_MTLS_DIR="$gen/mtls"
    # Переменные compose.auth-mtls.yaml для каждого из трёх клиентов: включённому —
    # его сертификат и https-адрес служебного TLS-порта, остальным — пустой каталог и
    # пустые значения (compose подставит прежние).
    local c suffix on
    for c in "${WALLET_AUTH_MTLS_ALL[@]}"; do
        suffix="${c#wallet-}"
        suffix="${suffix^^}"
        on=0
        for name in "${WALLET_AUTH_MTLS_SELECTED[@]}"; do
            [[ "$name" == "$c" ]] && on=1
        done
        if [[ $on -eq 1 ]]; then
            export "WALLET_AUTHTLS_SRC_$suffix=$gen/mtls/$c"
            export "WALLET_AUTHTLS_CERT_$suffix=/etc/wallet-tls/tls.crt"
            export "WALLET_AUTHTLS_KEY_$suffix=/etc/wallet-tls/tls.key"
            export "WALLET_AUTHTLS_CA_$suffix=/etc/wallet-tls/ca.pem"
            export "WALLET_AUTHTLS_URL_$suffix=https://google-auth-internal:8443"
            export "WALLET_AUTHTLS_HASH_$suffix=$(_mtls_hash_value "$c")"
        else
            export "WALLET_AUTHTLS_SRC_$suffix=$gen/empty"
            export "WALLET_AUTHTLS_CERT_$suffix="
            export "WALLET_AUTHTLS_KEY_$suffix="
            export "WALLET_AUTHTLS_CA_$suffix="
            export "WALLET_AUTHTLS_URL_$suffix="
            export "WALLET_AUTHTLS_HASH_$suffix=off"
        fi
    done
    export WALLET_MTLS_PREPARED="$ENV_NAME"
}

# _mtls_hash_value <имя> — значение хэша сертификата (после env_mtls_prepare).
_mtls_hash_value() {
    local var
    var="$(_mtls_hash_var "$1")"
    echo "${!var}"
}

# env_mtls_check_images [сервис[:тег]...] — режим включён: у каждого образа есть метка
# org.wallet.mtls=1 (design D8). Без аргументов проверяются образы, которым режим нужен:
# весь контур при WALLET_INTERNAL_MTLS=true, иначе google-auth и выбранные клиенты
# служебного порта. Без :тег — тег из tags.env (deploy.sh передаёт выкатываемый тег).
# Образа нет на хосте — скачивается. Режимы выключены — no-op.
env_mtls_check_images() {
    _mtls_load_clients
    env_mtls_enabled || env_auth_mtls_enabled || return 0
    local -a svcs=("$@") bad=()
    local s tag image label name a
    if [[ ${#svcs[@]} -eq 0 ]]; then
        if env_mtls_enabled; then
            for s in "${!WALLET_SERVICE_PORT[@]}"; do
                [[ "$s" == "wallet-docs" ]] && ! env_docs_enabled && continue
                svcs+=("$s")
            done
        else
            svcs=(google-auth "${WALLET_AUTH_MTLS_SELECTED[@]}")
        fi
    else
        # Выкатывают один сервис: проверять его нужно, только если режим его касается.
        local -a relevant=()
        for s in "${svcs[@]}"; do
            name="${s%%:*}"
            if env_mtls_enabled || [[ "$name" == "google-auth" ]]; then
                relevant+=("$s")
                continue
            fi
            for a in "${WALLET_AUTH_MTLS_SELECTED[@]}"; do
                [[ "$a" == "$name" ]] && relevant+=("$s")
            done
        done
        svcs=("${relevant[@]}")
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
        || die "mTLS включён, но образы без метки org.wallet.mtls=1 (собраны без поддержки): ${bad[*]}. Выкатите версии с поддержкой или выключите режим (design D8)"
}
