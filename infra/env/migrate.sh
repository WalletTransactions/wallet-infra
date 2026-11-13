#!/bin/bash
# Накат миграций одной базы контура (design D4). Миграции берутся из ОБРАЗА
# сервиса (/migrations, COPY в его Containerfile), а не из рабочей папки:
# схема всегда соответствует выкатываемому коду.
#
# Использование:
#   infra/env/migrate.sh <prod|test> <auth|wallet|telegram|ai|docs|perf> [образ] [команда migrate...]
#     образ   — по умолчанию образ сервиса базы из tags.env контура;
#               для perf не нужен (миграции в infra/db/migrations/perf)
#     команда — по умолчанию "up"; можно "version", "force N", "down 1"
#
# Примеры:
#   infra/env/migrate.sh test wallet
#   infra/env/migrate.sh test wallet ghcr.io/wallettransactions/wallet-api:1.4.0-rc.1
#   infra/env/migrate.sh prod auth - version      # "-" — образ по умолчанию
#
# Как переносятся файлы: образ сервиса копирует /migrations во временный
# docker-том, migrate/migrate читает их оттуда. Не через каталог на диске —
# в Jenkins скрипт работает в контейнере, и его /tmp docker на хосте не видит.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

env_init "${1:-}"
base="${2:-}"
shift 2 || true
[[ -n "${WALLET_DB_SERVICE[$base]:-}" || "$base" == "perf" ]] \
    || die "база должна быть auth, wallet, telegram, ai, docs или perf, а не '${base}'"

image="${1:--}"
shift || true
[[ $# -gt 0 ]] || set -- up

env_check_secrets
env_check_tags
env_lock

set -a
# shellcheck disable=SC1091
source "$SECRETS_DIR/db.env"
set +a

db_var="${base^^}_POSTGRES_DB"
db_name="${!db_var:-}"
[[ -n "$db_name" ]] || die "в $SECRETS_DIR/db.env не задан $db_var"

db_container="$(env_compose ps -q db)"
[[ -n "$db_container" ]] || die "db контура $ENV_NAME не запущена — сначала infra/env/up.sh $ENV_NAME"

# Базы может не быть на томе, созданном до её появления в init-db.sh, —
# тогда прогоняем init-db.sh ещё раз (он идемпотентен; переменные ролей и
# сам скрипт у контейнера db уже есть, см. compose.yaml).
db_exists="$(docker exec "$db_container" sh -c \
    'psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '"'$db_name'"'"')"
if [[ "$db_exists" != "1" ]]; then
    echo "==> базы $db_name нет — прогоняю init-db.sh (идемпотентно)"
    docker exec "$db_container" sh /docker-entrypoint-initdb.d/init-db.sh >/dev/null
fi

database_url="postgres://${MIGRATOR_POSTGRES_USER}:${MIGRATOR_POSTGRES_PASSWORD}@db:5432/${db_name}?sslmode=disable"

if [[ "$base" == "perf" ]]; then
    echo "==> [$ENV_NAME] $base: migrate $* (infra/db/migrations/perf)"
    exec docker run --rm --network "wallet-$ENV_NAME" \
        -v "$COMPOSE_DIR/infra/db/migrations/perf:/migrations:ro" \
        docker.io/migrate/migrate:v4.18.3 -path=/migrations -database "$database_url" "$@"
fi

if [[ "$image" == "-" ]]; then
    service="${WALLET_DB_SERVICE[$base]}"
    tag="$(current_tag "$service")"
    [[ -n "$tag" ]] || die "в tags.env контура $ENV_NAME нет тега $service"
    image="$(image_of "$service" "$tag")"
fi

volume="wallet-migrations-${ENV_NAME}-${base}-$$"
cleanup() { docker volume rm -f "$volume" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> [$ENV_NAME] $base: migrate $* (миграции из $image)"
docker volume create "$volume" >/dev/null
# --user 0: рантайм-образы работают под appuser, а корень нового тома — root.
docker run --rm --user 0 --entrypoint cp -v "$volume:/dst" "$image" -r /migrations/. /dst/
docker run --rm --network "wallet-$ENV_NAME" -v "$volume:/migrations:ro" \
    docker.io/migrate/migrate:v4.18.3 -path=/migrations -database "$database_url" "$@"

# wallet_reader (под ней ходит wallet-report) создаёт миграция wallet-api с
# паролем-литералом для локальной разработки
# (wallet-api/schema/role/wallet_reader.sql: "для стенда с реальными данными
# пароль меняется вне этого файла"). Перезадаём после КАЖДОГО наката — любая
# будущая миграция с тем же ALTER ROLE вернула бы литерал. Пароль идёт в psql
# через окружение (docker exec -e без значения), не аргументом командной строки.
if [[ "$base" == "wallet" ]]; then
    [[ -n "${READER_POSTGRES_PASSWORD:-}" ]] || die "в $SECRETS_DIR/db.env не задан READER_POSTGRES_PASSWORD"
    READER_PW="$READER_POSTGRES_PASSWORD" docker exec -i -e READER_PW "$db_container" \
        sh -c 'psql -v ON_ERROR_STOP=1 -q -U "$POSTGRES_USER" -d postgres -v pw="$READER_PW"' <<'SQL'
SELECT format('ALTER ROLE wallet_reader PASSWORD %L', :'pw')
WHERE EXISTS (SELECT FROM pg_roles WHERE rolname = 'wallet_reader')\gexec
SQL
    echo "==> [$ENV_NAME] пароль wallet_reader задан из db.env"
fi
