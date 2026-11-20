#!/bin/bash
# TLS на входе контура (openspec/changes/add-tls-ingress) — подключается из
# lib.sh, сам не запускается.
#
# Единственный переключатель — WALLET_TLS=true в infra/env/<env>.env (design
# D3). Из него env_tls_prepare выводит всё остальное, и выводит при КАЖДОМ
# вызове compose (env_compose), а не только в up.sh: иначе выкат одного
# гейтвея через deploy.sh пересоздал бы его с портом на всех интерфейсах или
# без доверия к X-Forwarded-*.
#
# Что выводится (state-каталог контура, generated/ — не править руками):
#   - профиль tls (COMPOSE_PROFILES, см. env_compose_profiles);
#   - WALLET_GATEWAY_BIND: «127.0.0.1:» при TLS, пусто без него (design D4);
#   - generated/google-auth.env: COOKIE_SECURE и настройки входа
#     WALLET_AUTH_METHODS/… — подключается ПОСЛЕ секрета google-auth.env и
#     перекрывает его;
#   - generated/wallet-gateway.env: TRUST_FORWARDED_HEADERS;
#   - generated/caddy/Caddyfile: блок на каждый источник сертификата
#     (tailscale / internal / files, design D7–D9);
#   - WALLET_TLS_CONFIG_HASH: метка tls-proxy — меняется Caddyfile или
#     сертификат files, compose пересоздаёт прокси;
#   - WALLET_TLS_FILES_SRC, WALLET_TAILSCALE_DIR: источники монтирования —
#     настоящие только в своём режиме, иначе пустой каталог generated/empty
#     (сокет tailscaled не попадает в прокси вне режима tailscale).

# env_setting <ключ> — значение из infra/env/<env>.env выкатанного описания
# контура (последнее, если ключ повторяется; пусто, если нет).
env_setting() {
    sed -n "s/^$1=//p" "$COMPOSE_DIR/infra/env/$ENV_NAME.env" 2>/dev/null | tail -n1
}

env_tls_enabled() {
    [[ "$(env_setting WALLET_TLS)" == "true" ]]
}

# env_compose_profiles — COMPOSE_PROFILES для этого вызова compose. База —
# COMPOSE_PROFILES процесса, если он задан (up.sh так выключает docs на один
# запуск), иначе из <env>.env; плюс tls, если включён TLS.
env_compose_profiles() {
    local profiles
    if [[ -v COMPOSE_PROFILES ]]; then
        profiles="$COMPOSE_PROFILES"
    else
        profiles="$(env_setting COMPOSE_PROFILES)"
    fi
    profiles="${profiles// /}"
    if env_tls_enabled && [[ ",$profiles," != *,tls,* ]]; then
        profiles="${profiles:+$profiles,}tls"
    fi
    echo "$profiles"
}

# _tls_write <файл> — stdin в файл атомарно (временный + mv): каталог
# смонтирован в контейнер, и он видит либо старый файл, либо новый целиком.
_tls_write() {
    local tmp
    tmp="$(mktemp "$1.XXXXXX")"
    cat > "$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$1"
}

_tls_is_ip() {
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$1" == *:* ]]
}

# _tls_check_choice <ключ> <значение> <допустимые...>
_tls_check_choice() {
    local key="$1" value="$2" ok
    shift 2
    for ok in "$@"; do
        [[ "$value" == "$ok" ]] && return 0
    done
    die "$key=$value в infra/env/$ENV_NAME.env — допустимо: $*"
}

# _tls_auth_settings — строки настроек входа для generated/google-auth.env.
# Задано в <env>.env — перекрывает секрет; не задано — строки нет, и
# действует значение из google-auth.env (или умолчание google-auth).
_tls_auth_settings() {
    local v
    v="$(env_setting WALLET_AUTH_METHODS)"
    if [[ -n "$v" ]]; then
        _tls_check_choice WALLET_AUTH_METHODS "$v" password google both
        echo "AUTH_METHODS=$v"
    fi
    v="$(env_setting WALLET_REGISTRATION)"
    if [[ -n "$v" ]]; then
        _tls_check_choice WALLET_REGISTRATION "$v" open closed
        echo "REGISTRATION=$v"
    fi
    v="$(env_setting WALLET_ALLOW_INSECURE_AUTH)"
    if [[ -n "$v" ]]; then
        _tls_check_choice WALLET_ALLOW_INSECURE_AUTH "$v" true false
        echo "ALLOW_INSECURE_AUTH=$v"
    fi
}

# _tls_check_tailscale <имя .ts.net> — tailscaled есть, имя — этого узла,
# HTTPS Certificates в tailnet включены. В контейнере Jenkins сокета хоста не
# видно (он монтируется только в tls-proxy) — там проверка пропускается с
# предупреждением, а bind-mount всё равно резолвит демон на хосте.
_tls_check_tailscale() {
    local want="$1" sock status self certs
    sock="${WALLET_TAILSCALE_SOCKET:-/var/run/tailscale/tailscaled.sock}"
    if [[ ! -S "$sock" ]]; then
        if [[ -e /.dockerenv ]]; then
            echo "==> [$ENV_NAME] tls: сокет $sock не виден в этом контейнере — проверка имени узла Tailscale пропущена" >&2
            return 0
        fi
        die "WALLET_TLS_MODE=tailscale: нет сокета tailscaled $sock (tailscale не установлен или не запущен; другой путь — WALLET_TAILSCALE_SOCKET)"
    fi
    status="$(curl -fsS --unix-socket "$sock" http://local-tailscaled.sock/localapi/v0/status)" \
        || die "WALLET_TLS_MODE=tailscale: tailscaled не ответил на $sock"
    self="$(jq -r '.Self.DNSName // empty' <<<"$status")"
    self="${self%.}"
    [[ "$want" == "$self" ]] \
        || die "WALLET_TLS_HOST: '$want' — не имя этого узла; tailscaled выдаёт сертификат только на '$self'"
    certs="$(jq -r '(.CertDomains // []) | join(" ")' <<<"$status")"
    [[ " $certs " == *" $self "* ]] \
        || die "в tailnet не включены HTTPS Certificates (админка Tailscale → DNS: MagicDNS и HTTPS Certificates)"
}

# _tls_join <адрес...> — адреса сайта Caddyfile: «a, b, c».
_tls_join() {
    local joined
    joined="$(IFS=,; echo "$*")"
    echo "${joined//,/, }"
}

# _tls_caddy_site <адреса через ", "> <строки tls-директивы...>
_tls_caddy_site() {
    local addrs="$1"
    shift
    echo
    echo "$addrs {"
    printf '\t%s\n' "$@"
    printf '\treverse_proxy wallet-gateway:8090\n'
    echo "}"
}

# env_tls_prepare — выводит и записывает всё, что зависит от WALLET_TLS (см.
# шапку файла). Один раз на процесс; ошибки настройки — die до любых
# действий с контуром.
env_tls_prepare() {
    [[ "${WALLET_TLS_PREPARED:-}" == "$ENV_NAME" ]] && return 0
    local gen="$STATE_DIR/generated" auth
    mkdir -p "$gen/caddy" "$gen/empty"
    export WALLET_GENERATED_DIR="$gen"
    export WALLET_TLS_FILES_SRC="$gen/empty"
    export WALLET_TAILSCALE_DIR="$gen/empty"

    if ! env_tls_enabled; then
        local tls
        tls="$(env_setting WALLET_TLS)"
        [[ -z "$tls" || "$tls" == "false" ]] \
            || die "WALLET_TLS=$tls в infra/env/$ENV_NAME.env — допустимо: true, false"
        export WALLET_GATEWAY_BIND=""
        export WALLET_TLS_CONFIG_HASH="off"
        auth="$(_tls_auth_settings)" || exit 1
        printf 'COOKIE_SECURE=false\n%s' "${auth:+$auth$'\n'}" | _tls_write "$gen/google-auth.env"
        echo "TRUST_FORWARDED_HEADERS=false" | _tls_write "$gen/wallet-gateway.env"
        export WALLET_TLS_PREPARED="$ENV_NAME"
        return 0
    fi

    local mode raw h first_ip="" hash_extra=""
    local -a hosts=() ts_hosts=() other_hosts=()
    mode="$(env_setting WALLET_TLS_MODE)"
    mode="${mode:-internal}"
    _tls_check_choice WALLET_TLS_MODE "$mode" internal files tailscale
    [[ -n "$(env_setting WALLET_TLS_PORT)" ]] \
        || die "WALLET_TLS=true, но нет WALLET_TLS_PORT в infra/env/$ENV_NAME.env"

    raw="$(env_setting WALLET_TLS_HOST)"
    IFS=',' read -ra hosts <<<"${raw// /}"
    for h in "${hosts[@]}"; do
        [[ -n "$h" ]] || continue
        [[ "$h" =~ ^[A-Za-z0-9.:-]+$ ]] || die "WALLET_TLS_HOST: недопустимый адрес '$h'"
        if _tls_is_ip "$h"; then
            [[ -n "$first_ip" ]] || first_ip="$h"
        fi
        if [[ "$mode" == "tailscale" && "$h" == *.ts.net ]]; then
            ts_hosts+=("$h")
        else
            other_hosts+=("$h")
        fi
    done
    [[ $(( ${#ts_hosts[@]} + ${#other_hosts[@]} )) -gt 0 ]] \
        || die "WALLET_TLS=true, но WALLET_TLS_HOST пуст — адреса, по которым клиенты открывают контур (через запятую)"

    local caddyfile
    caddyfile="$(
        echo "# Сгенерирован infra/env/tls.sh для контура $ENV_NAME — не править руками."
        echo "{"
        # :80 не слушаем: редирект на https некуда публиковать.
        printf '\tauto_https disable_redirects\n'
        # Корень CA ставят на устройства вручную (export-ca.sh), не в контейнер.
        printf '\tskip_install_trust\n'
        # У CA Caddy и Let's Encrypt OCSP нет — без попыток и предупреждений в журнале.
        printf '\tocsp_stapling off\n'
        # Подключения по IP приходят без SNI (design D9).
        [[ -n "$first_ip" ]] && printf '\tdefault_sni %s\n' "$first_ip"
        # Без HTTP/3: UDP-порт не публикуется, Alt-Svc звал бы клиентов в никуда.
        printf '\tservers {\n\t\tprotocols h1 h2\n\t}\n'
        echo "}"
        case "$mode" in
            internal)
                _tls_caddy_site "$(_tls_join "${other_hosts[@]}")" "tls internal"
                ;;
            files)
                _tls_caddy_site "$(_tls_join "${other_hosts[@]}")" \
                    "tls /tls/fullchain.pem /tls/privkey.pem"
                ;;
            tailscale)
                [[ ${#ts_hosts[@]} -eq 1 ]] \
                    || die "WALLET_TLS_MODE=tailscale: в WALLET_TLS_HOST нужно ровно одно имя .ts.net (имя этого узла), сейчас ${#ts_hosts[@]}"
                _tls_caddy_site "${ts_hosts[0]}" "tls {" "	get_certificate tailscale" "}"
                if [[ ${#other_hosts[@]} -gt 0 ]]; then
                    _tls_caddy_site "$(_tls_join "${other_hosts[@]}")" "tls internal"
                fi
                ;;
        esac
    )" || exit 1

    case "$mode" in
        files)
            local dir="$SECRETS_DIR/tls" f m
            for f in fullchain.pem privkey.pem; do
                [[ -f "$dir/$f" ]] \
                    || die "WALLET_TLS_MODE=files: нет $dir/$f (ожидаются $dir/fullchain.pem и $dir/privkey.pem)"
            done
            m="$(stat -c %a "$dir/privkey.pem")"
            [[ "$m" == "600" ]] || die "права $dir/privkey.pem — $m, нужно 600 (chmod 600)"
            for h in "${other_hosts[@]}"; do
                if _tls_is_ip "$h"; then
                    openssl x509 -in "$dir/fullchain.pem" -noout -checkip "$h" 2>/dev/null | grep -q 'does match'
                else
                    openssl x509 -in "$dir/fullchain.pem" -noout -checkhost "$h" 2>/dev/null | grep -q 'does match'
                fi || die "WALLET_TLS_HOST: адреса '$h' нет в сертификате $dir/fullchain.pem"
            done
            export WALLET_TLS_FILES_SRC="$dir"
            # Продлённый сертификат — новая метка, compose пересоздаст прокси.
            hash_extra="$(sha256sum "$dir/fullchain.pem" | cut -c1-64)"
            ;;
        tailscale)
            _tls_check_tailscale "${ts_hosts[0]}"
            local sock="${WALLET_TAILSCALE_SOCKET:-/var/run/tailscale/tailscaled.sock}"
            # Каталог, а не сам сокет: tailscaled пересоздаёт сокет при
            # перезапуске, и смонтированный файл остался бы мёртвым.
            export WALLET_TAILSCALE_DIR="${sock%/*}"
            ;;
    esac

    printf '%s\n' "$caddyfile" | _tls_write "$gen/caddy/Caddyfile"
    export WALLET_GATEWAY_BIND="127.0.0.1:"
    export WALLET_TLS_CONFIG_HASH
    WALLET_TLS_CONFIG_HASH="$(printf '%s\n%s\n%s' "$caddyfile" "$mode" "$hash_extra" | sha256sum | cut -c1-16)"
    auth="$(_tls_auth_settings)" || exit 1
    printf 'COOKIE_SECURE=true\n%s' "${auth:+$auth$'\n'}" | _tls_write "$gen/google-auth.env"
    echo "TRUST_FORWARDED_HEADERS=true" | _tls_write "$gen/wallet-gateway.env"
    export WALLET_TLS_PREPARED="$ENV_NAME"
}
