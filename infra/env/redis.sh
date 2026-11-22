#!/bin/bash
# Аутентификация и права доступа к Redis контура (openspec/changes/add-redis-auth, design D1–D6) —
# подключается из lib.sh, сам не запускается.
#
# Единственный переключатель — WALLET_REDIS_AUTH в infra/env/<env>.env:
#   off (по умолчанию) — Redis без пароля, как раньше; этот файл ничего не создаёт, compose.redis-auth.yaml
#                        не подключается, `docker compose config` не меняется;
#   compat             — Redis с ACL-файлом (пользователи google-auth, exporter, health, admin), а `default`
#                        ЕЩЁ включён без пароля: старые клиенты и откат работают (design D6, шаги 2–3);
#   on                 — то же, `default` выключен (шаг 5): без учётных данных Redis ничего не выполняет.
#
# Пароли — по файлу на потребителя в $SECRETS_DIR/redis/ (0600), их создаёт ОДИН РАЗ хостовый скрипт
# infra/env/redis-init.sh (Jenkins монтирует секреты только на чтение, как у CA mTLS). Здесь они только
# читаются; в $STATE_DIR/generated/redis/users.acl пишутся хеши SHA-256, не пароли. Значения не печатаются.

# Пользователи и права (design D3). Ключи — только префиксы google-auth.
_REDIS_KEY_PATTERNS="~refresh_token:* ~access_token:* ~user_refresh_tokens:* ~user_access_tokens:* ~mcp_token:* ~user_mcp_tokens:* ~tg_link_code:* ~authfail:*"
_REDIS_GOOGLE_AUTH_CMDS="-@all +set +get +getdel +del +exists +sadd +srem +smembers +expire +expiretime +incr +ttl"
# exporter: команды чтения статистики redis_exporter; точный список уточняется по ACL LOG на test (design D3).
_REDIS_EXPORTER_CMDS="-@all +info +ping +client|list +client|setname +config|get +dbsize +slowlog|len +slowlog|get +latency|latest +latency|histogram +memory|usage +scan +type +pttl +llen +scard +zcard +hlen +xlen +strlen"
_REDIS_USERS=(google-auth health exporter admin)

env_redis_mode() {
    local m
    m="$(env_setting WALLET_REDIS_AUTH)"
    echo "${m:-off}"
}

env_redis_enabled() {
    [[ "$(env_redis_mode)" != "off" ]]
}

# _redis_secret <пользователь> <ключ> — значение из $SECRETS_DIR/redis/<пользователь>.env.
_redis_secret() {
    sed -n "s/^$2=//p" "$SECRETS_DIR/redis/$1.env" 2>/dev/null | tail -n1
}

# env_redis_prepare — выводит и записывает generated/redis/users.acl и экспортирует WALLET_REDIS_ACL_DIR.
# Один раз на процесс; ошибки настройки и отсутствие секретов — die до действий с контуром.
env_redis_prepare() {
    [[ "${WALLET_REDIS_PREPARED:-}" == "$ENV_NAME" ]] && return 0
    local mode
    mode="$(env_redis_mode)"
    case "$mode" in off | compat | on) ;; *) die "WALLET_REDIS_AUTH=$mode в infra/env/$ENV_NAME.env — допустимо: off, compat, on" ;; esac
    if [[ "$mode" == "off" ]]; then
        export WALLET_REDIS_PREPARED="$ENV_NAME"
        return 0
    fi
    local u pw gen acl default_line
    declare -A hash=()
    for u in "${_REDIS_USERS[@]}"; do
        [[ -s "$SECRETS_DIR/redis/$u.env" ]] \
            || die "redis: нет $SECRETS_DIR/redis/$u.env — создайте пароли один раз на хосте: bash infra/env/redis-init.sh $ENV_NAME (Jenkins монтирует секреты только на чтение)"
        case "$u" in
            health | admin) pw="$(_redis_secret "$u" REDISCLI_AUTH)" ;;
            *) pw="$(_redis_secret "$u" REDIS_PASSWORD)" ;;
        esac
        [[ -n "$pw" ]] || die "redis: в $SECRETS_DIR/redis/$u.env нет пароля"
        hash[$u]="$(printf '%s' "$pw" | sha256sum | cut -d' ' -f1)"
    done
    if [[ "$mode" == "compat" ]]; then
        default_line="user default on nopass ~* &* +@all"
    else
        default_line="user default off"
    fi
    gen="${WALLET_GENERATED_DIR:-$STATE_DIR/generated}/redis"
    mkdir -p "$gen"
    chmod 755 "$gen"
    acl="$(
        # Комментарии в ACL-файле Redis недопустимы (каждая строка — `user …`): происхождение файла описано здесь.
        echo "$default_line"
        echo "user google-auth on #${hash[google-auth]} $_REDIS_KEY_PATTERNS $_REDIS_GOOGLE_AUTH_CMDS"
        echo "user exporter on #${hash[exporter]} ~* $_REDIS_EXPORTER_CMDS"
        echo "user health on #${hash[health]} resetkeys -@all +ping"
        echo "user admin on #${hash[admin]} ~* &* +@all"
    )"
    local tmp
    tmp="$(mktemp "$gen/users.acl.XXXXXX")"
    printf '%s\n' "$acl" > "$tmp"
    chmod 644 "$tmp"
    # Тот же файл — ничего не пересоздаём (mtime и inode остаются), иначе mv меняет метку изменений.
    if [[ -f "$gen/users.acl" ]] && cmp -s "$tmp" "$gen/users.acl"; then
        rm -f "$tmp"
    else
        mv "$tmp" "$gen/users.acl"
    fi
    export WALLET_REDIS_ACL_DIR="$gen"
    export WALLET_REDIS_PREPARED="$ENV_NAME"
}

# env_redis_admin <аргументы redis-cli...> — redis-cli в контейнере Redis контура. Режим включён —
# под admin (пароль из redis/admin.env через REDISCLI_AUTH, не аргументом и не в журнал); выключен — как раньше.
env_redis_admin() {
    if ! env_redis_enabled; then
        env_compose exec -T redis redis-cli "$@"
        return
    fi
    local pw
    pw="$(_redis_secret admin REDISCLI_AUTH)"
    [[ -n "$pw" ]] || die "redis: нет пароля admin в $SECRETS_DIR/redis/admin.env (bash infra/env/redis-init.sh $ENV_NAME)"
    REDISCLI_AUTH="$pw" env_compose exec -T -e REDISCLI_AUTH redis redis-cli --user admin "$@"
}

# env_redis_apply — применить users.acl к работающему Redis без рестарта (ACL LOAD под admin, design D5).
# Нужен при смене режима compat → on (и обратно): ACL-файл Redis читает на старте и по ACL LOAD, а рестарт
# оборвал бы соединение google-auth (переподключения у него нет). Режим выключен — ничего не делает.
env_redis_apply() {
    env_redis_enabled || return 0
    # Шаг 5 (default off): живое соединение под default оборвётся после ACL LOAD — не выключаем, пока оно есть
    # (задача R6.3). Каждый клиент должен быть переведён на своего пользователя на шаге 3.
    if [[ "$(env_redis_mode)" == "on" ]]; then
        local stale
        stale="$(env_redis_admin CLIENT LIST | grep -c ' user=default ' || true)"
        if [[ "$stale" -gt 0 ]]; then
            die "redis: $stale соединение(й) под user=default — default не выключен; переведите клиентов на своих пользователей (WALLET_REDIS_AUTH=compat, шаг 3) и повторите"
        fi
    fi
    env_redis_admin ACL LOAD >/dev/null || die "redis: ACL LOAD не прошёл (см. журнал Redis; прежний ACL остаётся в силе)"
    echo "==> [$ENV_NAME] redis: ACL применён (режим $(env_redis_mode))"
}
