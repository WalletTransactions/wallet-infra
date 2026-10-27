#!/bin/bash
# Контур для нагрузочных прогонов (wallet-api/loadtest, wallet-report/loadtest,
# job'ы *-loadtest в Jenkins) — подключается через source, сам не запускается.
#
# Нагрузка, сид данных и минтинг токенов идут только в test: в prod они
# создали бы чужие леджеры и пользователей. Раньше скрипты брали «первый
# попавшийся» контейнер db — при двух контурах это мог быть prod.
#
# После source заданы:
#   LOADTEST_ENV          — контур (только test);
#   LOADTEST_NETWORK      — docker-сеть контура: в ней db, wallet-gateway и
#                           prometheus резолвятся по именам сервисов;
#   LOADTEST_DB_CONTAINER — имя контейнера db контура;
#   LOADTEST_PEM          — ключ подписи access-токенов этого контура (тот же,
#                           что у его google-auth, иначе гейтвей ответит 401);
#   LOADTEST_CONTAINER_PREFIX — префикс имён контейнеров контура для фильтров
#                           cadvisor (`name=~"wallet-test-.*"`);
#   переменные db.env контура (WALLET_POSTGRES_*, PERF_POSTGRES_* и т.д.).
#
# Значения секретов не печатаются (как и в остальных infra/env/*.sh).

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOADTEST_ENV="${LOADTEST_ENV:-test}"
[[ "$LOADTEST_ENV" == "test" ]] \
    || die "нагрузочные прогоны — только в контуре test, а не '$LOADTEST_ENV'"

env_init "$LOADTEST_ENV"
[[ -f "$SECRETS_DIR/db.env" ]] || die "нет $SECRETS_DIR/db.env (см. wallet-infra/infra/env/README.md)"
[[ -f "$SECRETS_DIR/jwt_signing_key.pem" ]] || die "нет $SECRETS_DIR/jwt_signing_key.pem"

LOADTEST_NETWORK="wallet-$LOADTEST_ENV"
LOADTEST_CONTAINER_PREFIX="wallet-$LOADTEST_ENV-"
LOADTEST_PEM="$SECRETS_DIR/jwt_signing_key.pem"
LOADTEST_DB_CONTAINER="$(docker ps \
    --filter "label=com.docker.compose.project=wallet-$LOADTEST_ENV" \
    --filter "label=com.docker.compose.service=db" \
    --format '{{.Names}}' | head -n1)"
[[ -n "$LOADTEST_DB_CONTAINER" ]] \
    || die "db контура $LOADTEST_ENV не запущена — сначала infra/env/up.sh $LOADTEST_ENV"

set -a
# shellcheck disable=SC1091
source "$SECRETS_DIR/db.env"
set +a

echo "==> контур $LOADTEST_ENV: сеть $LOADTEST_NETWORK, db $LOADTEST_DB_CONTAINER"

# loadtest_container_id <сервис> — полный id контейнера сервиса в контуре.
# Метка `name` у cAdvisor — это id контейнера, а не имя (docker-обработчик
# cAdvisor выключен, см. compose.yaml стека метрик), а по `image` prod и test
# не различить: на одном теге образ общий. Id меняется при пересоздании
# контейнера — брать его в момент запроса к Prometheus, не заранее.
loadtest_container_id() {
    docker ps --no-trunc \
        --filter "label=com.docker.compose.project=wallet-$LOADTEST_ENV" \
        --filter "label=com.docker.compose.service=$1" \
        --format '{{.ID}}' | head -n1
}

# loadtest_override <сервис> <ПЕРЕМЕННАЯ> <значение> — пересоздать сервис
# контура с изменённой переменной окружения (например, DATABASE_POOL_SIZE)
# на время прогона. Под блокировкой контура: не посреди выката или
# перезаливки. Следующий выкат этого сервиса вернёт обычную конфигурацию сам.
loadtest_override() {
    local service="$1" var="$2" value="$3" file
    env_lock
    file="$(mktemp --suffix=.yaml)"
    printf 'services:\n  %s:\n    environment:\n      %s: "%s"\n' "$service" "$var" "$value" > "$file"
    echo "==> [$LOADTEST_ENV] $service: $var=$value на время прогона"
    env_compose -f "$file" up -d --no-deps --wait --wait-timeout 180 "$service"
    rm -f "$file"
}

# loadtest_restore <сервис> — вернуть сервис к конфигурации контура.
loadtest_restore() {
    local service="$1"
    env_lock
    echo "==> [$LOADTEST_ENV] $service: обычная конфигурация контура"
    env_compose up -d --no-deps --wait --wait-timeout 180 "$service"
}
