#!/bin/bash
# Создаёт пароли Redis контура (openspec/changes/add-redis-auth, design D4) — один раз, на хосте.
#
#   bash infra/env/redis-init.sh <prod|test>
#
# Файлы в ~/.config/wallet-secrets/<env>/redis/ (права 0600, каталог 0700), по одному на потребителя,
# чтобы пароль не попадал в чужие контейнеры:
#   google-auth.env  REDIS_USERNAME, REDIS_PASSWORD   — env_file google-auth;
#   health.env       REDISCLI_AUTH                    — env_file самого Redis (healthcheck);
#   exporter.env     REDIS_USER, REDIS_PASSWORD       — читает infra/monitoring/up.sh;
#   admin.env        REDISCLI_AUTH                    — оператор и test-refresh.sh, никуда не монтируется.
# Выкат (Jenkins) секреты только читает: секреты в Jenkins смонтированы на чтение. Повторный запуск ничего
# не меняет. Значения не печатаются.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

env_init "${1:-}"
dir="$SECRETS_DIR/redis"
mkdir -p "$dir"
chmod 700 "$dir"

make() { # <файл> <строки...>
    local file="$dir/$1.env"
    shift
    if [[ -s "$file" ]]; then
        echo "есть: $file"
        return 0
    fi
    ( umask 077; printf '%s\n' "$@" > "$file" )
    chmod 600 "$file"
    echo "создан: $file"
}

pw() { openssl rand -hex 32; }
make google-auth "REDIS_USERNAME=google-auth" "REDIS_PASSWORD=$(pw)"
make health "REDISCLI_AUTH=$(pw)"
make exporter "REDIS_USER=exporter" "REDIS_PASSWORD=$(pw)"
make admin "REDISCLI_AUTH=$(pw)"
echo "Дальше: WALLET_REDIS_AUTH=compat в infra/env/$ENV_NAME.env и up.sh $ENV_NAME (README infra/env, «Redis: пароль и ACL»)."
