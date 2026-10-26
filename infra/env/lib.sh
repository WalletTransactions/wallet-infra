#!/bin/bash
# Общие функции скриптов контуров (infra/env/*.sh) — подключается через
# source, сам не запускается. См. infra/env/README.md.
#
# Где что лежит (переопределяется переменными — в Jenkins каталоги
# смонтированы по тем же абсолютным путям, что на хосте, но $HOME другой):
#   WALLET_SECRETS_ROOT  — секреты контуров, по умолчанию ~/.config/wallet-secrets
#   WALLET_STATE_ROOT    — состояние выкатов, по умолчанию ~/.local/state/wallet-envs
#
# Скрипты НЕ печатают значений секретов: без set -x, без cat файлов из
# WALLET_SECRETS_ROOT (спека release-promotion, "Секреты не попадают в логи").

WALLET_INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Базы контура и сервис, в образе которого лежат их миграции (design D4).
# perf — база истории нагрузочных прогонов, миграции в этом репозитории.
# shellcheck disable=SC2034  # используют скрипты, подключающие lib.sh
declare -A WALLET_DB_SERVICE=(
    [auth]=google-auth
    [wallet]=wallet-api
    [telegram]=wallet-telegram
    [ai]=wallet-ai
)

# Сервисы, которые выкатываются по тегам, и порт их GET /version внутри
# сети контура (smoke в deploy.sh).
# shellcheck disable=SC2034
declare -A WALLET_SERVICE_PORT=(
    [google-auth]=8080
    [wallet-api]=8082
    [wallet-report]=8084
    [wallet-ai]=8087
    [wallet-gateway]=8090
    [wallet-web]=80
    [wallet-telegram]=8086
)

die() {
    echo "ОШИБКА: $*" >&2
    exit 1
}

# env_init <env> — проверяет имя контура и выставляет ENV_NAME, SECRETS_DIR,
# STATE_DIR; экспортирует WALLET_SECRETS_DIR для compose.yaml.
env_init() {
    ENV_NAME="${1:-}"
    [[ "$ENV_NAME" == "prod" || "$ENV_NAME" == "test" ]] \
        || die "контур должен быть prod или test, а не '${ENV_NAME}'"
    STATE_ROOT="${WALLET_STATE_ROOT:-$HOME/.local/state/wallet-envs}"
    SECRETS_DIR="${WALLET_SECRETS_ROOT:-$HOME/.config/wallet-secrets}/$ENV_NAME"
    STATE_DIR="$STATE_ROOT/$ENV_NAME"
    export WALLET_SECRETS_DIR="$SECRETS_DIR"
    # Описание контура (compose.yaml, init-db.sh, миграции perf) — из
    # выкатанного тега wallet-infra (<state>/<env>/infra, его ведёт
    # deploy.sh wallet-infra), а не из рабочей папки: выкат сервиса не должен
    # заодно катить незакоммиченные правки. Пока checkout'а нет (первый
    # запуск контура) — из репозитория, где лежит сам скрипт.
    if [[ -f "$STATE_DIR/infra/compose.yaml" ]]; then
        COMPOSE_DIR="$STATE_DIR/infra"
    else
        COMPOSE_DIR="$WALLET_INFRA_DIR"
    fi
}

# env_check_secrets — все файлы секретов на месте, каталог 700, *.env 600.
# jwt_signing_key.pem — 644: его bind-монтирует в google-auth, а там процесс
# работает под appuser (uid 999), не владельцем файла. Других пользователей
# хоста к нему всё равно не пускает каталог 700.
env_check_secrets() {
    local f mode want
    [[ -d "$SECRETS_DIR" ]] || die "нет каталога секретов $SECRETS_DIR (см. infra/env/README.md)"
    mode="$(stat -c %a "$SECRETS_DIR")"
    [[ "$mode" == "700" ]] || die "права $SECRETS_DIR — $mode, нужно 700"
    for f in db.env google-auth.env wallet-api.env wallet-report.env wallet-ai.env \
             wallet-gateway.env wallet-telegram.env jwt_signing_key.pem; do
        [[ -f "$SECRETS_DIR/$f" ]] || die "нет $SECRETS_DIR/$f"
        want=600
        [[ "$f" == *.pem ]] && want=644
        mode="$(stat -c %a "$SECRETS_DIR/$f")"
        [[ "$mode" == "$want" ]] || die "права $SECRETS_DIR/$f — $mode, нужно $want (chmod $want)"
    done
}

# env_check_tags — tags.env контура есть (его пишет только deploy.sh).
env_check_tags() {
    [[ -f "$STATE_DIR/tags.env" ]] \
        || die "нет $STATE_DIR/tags.env — теги образов контура (см. infra/env/README.md, \"Первый запуск\")"
}

# env_lock — блокировка контура: выкаты, миграции и перезаливка идут строго
# по одному (спека release-promotion). Ждёт чужую операцию, не падает.
# Повторный вызов в том же процессе или дочернем скрипте — no-op.
# Файл — в каталоге состояния, а не в /tmp: у контейнера Jenkins свой /tmp,
# а каталог состояния смонтирован туда же, и ручной запуск на хосте ждёт
# job'ы Jenkins (и наоборот).
env_lock() {
    [[ "${WALLET_ENV_LOCK_HELD:-}" == "$ENV_NAME" ]] && return 0
    mkdir -p "$STATE_ROOT"
    exec 9>"$STATE_ROOT/$ENV_NAME.lock"
    if ! flock -n 9; then
        echo "==> контур $ENV_NAME занят другой операцией, жду..."
        flock 9
    fi
    export WALLET_ENV_LOCK_HELD="$ENV_NAME"
}

# env_compose <аргументы compose...> — docker compose контура со всеми
# тремя источниками переменных (design D2). Порядок важен: позже — сильнее.
env_compose() {
    docker compose \
        --project-directory "$COMPOSE_DIR" \
        -f "$COMPOSE_DIR/compose.yaml" \
        --env-file "$COMPOSE_DIR/infra/env/$ENV_NAME.env" \
        --env-file "$STATE_DIR/tags.env" \
        --env-file "$SECRETS_DIR/db.env" \
        "$@"
}

# tag_var <сервис> — имя переменной тега в tags.env: wallet-api → WALLET_API_TAG.
tag_var() {
    local s="${1^^}"
    echo "${s//-/_}_TAG"
}

# current_tag <сервис> — тег сервиса из tags.env контура (пусто, если нет).
current_tag() {
    local var
    var="$(tag_var "$1")"
    sed -n "s/^${var}=//p" "$STATE_DIR/tags.env" 2>/dev/null | tail -n1
}

# set_tag <сервис> <тег> — записать тег сервиса в tags.env (атомарно:
# временный файл + mv, чтобы прерванная запись не оставила полфайла).
set_tag() {
    local var tmp
    var="$(tag_var "$1")"
    mkdir -p "$STATE_DIR"
    tmp="$(mktemp "$STATE_DIR/tags.env.XXXXXX")"
    { grep -v "^${var}=" "$STATE_DIR/tags.env" 2>/dev/null || true; echo "${var}=$2"; } > "$tmp"
    mv "$tmp" "$STATE_DIR/tags.env"
}

# image_of <сервис> <тег>
image_of() {
    echo "ghcr.io/wallettransactions/$1:$2"
}

# log_history <сервис> <тег> <digest|commit> <итог> — строка в журнал выкатов
# контура: по нему видно, что и когда катилось, и на что откатываться.
log_history() {
    mkdir -p "$STATE_DIR"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "$1" "$2" "$3" "$4" >> "$STATE_DIR/history"
}
