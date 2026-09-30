#!/bin/bash
# Тонкая обёртка над golang-migrate (образ migrate/migrate) — накатывает/
# откатывает версионированные миграции ОДНОЙ из двух баз проекта (auth или
# wallet). Сам инструмент не подключает никакой зависимости в рантайм
# сервисов — это чисто эксплуатационный шаг, гоняется контейнером, как и
# сам psql/redis-cli в этом проекте (см. infra/db/README.md, "Миграции", почему
# golang-migrate, а не Flyway).
#
# Использование (после `cp infra/db/.env.example infra/db/.env` и `... up -d db`) —
# через `bash`, а не напрямую: exec-бит на Windows-чекауте не гарантирован:
#   bash infra/db/migrate.sh auth up             # накатить все новые миграции auth-базы
#   bash infra/db/migrate.sh wallet up
#   bash infra/db/migrate.sh auth down 1         # откатить последнюю миграцию
#   bash infra/db/migrate.sh auth version        # какая версия сейчас накачена
#   bash infra/db/migrate.sh auth force 1        # см. ниже, "Первое подключение"
#
# Первое подключение к УЖЕ существующей базе (схема уже накачена руками или
# старой версией init-db.sh, до перехода на этот инструмент): `up` попытается
# выполнить 000001_init.up.sql и упадёт на "relation already exists" — это
# ожидаемо. Вместо этого один раз выполните `force 1` — это только помечает
# в служебной таблице schema_migrations версию 1 как применённую, БЕЗ
# выполнения SQL. Дальше `up`/`down` работают как обычно. На чистой новой
# базе (свежий volume) сразу используйте `up` — таблиц ещё нет, миграция
# отработает штатно.
set -euo pipefail

# MSYS_NO_PATHCONV — наследие Windows/Git Bash (MSYS иначе молча переписывал
# абсолютные unix-пути в Windows-пути ещё до того, как они попадали в
# podman/docker). На Linux-баше не действует, но и не мешает — оставлено,
# чтобы скрипт остался переносимым, если кто-то снова запустит его из Git
# Bash на Windows.
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Сервисы — соседние репозитории рядом с wallet-infra (WalletTransactions/<сервис>),
# миграции каждой базы живут в репозитории своего сервиса.
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

target="${1:-}"
if [[ "$target" != "auth" && "$target" != "wallet" && "$target" != "perf" && "$target" != "telegram" ]]; then
    echo "Использование: $0 <auth|wallet|perf|telegram> <команда migrate...>  (up | down N | force N | version | ...)" >&2
    exit 1
fi
shift

ENV_FILE="$SCRIPT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Не найден $ENV_FILE — сначала: cp infra/db/.env.example infra/db/.env" >&2
    exit 1
fi
set -a
source "$ENV_FILE"
set +a

if [[ "$target" == "auth" ]]; then
    db_name="$AUTH_POSTGRES_DB"
    migrations_dir="$WORKSPACE_DIR/google-auth/migrations"
elif [[ "$target" == "wallet" ]]; then
    db_name="$WALLET_POSTGRES_DB"
    migrations_dir="$WORKSPACE_DIR/wallet-api/migrations"
elif [[ "$target" == "telegram" ]]; then
    # ${...:-} — переменная появилась позже остальных, и в старых
    # infra/db/.env её может не быть: под set -u это было бы невнятное
    # "unbound variable" вместо подсказки ниже.
    db_name="${TELEGRAM_POSTGRES_DB:-}"
    migrations_dir="$WORKSPACE_DIR/wallet-telegram/migrations"
else
    db_name="$PERF_POSTGRES_DB"
    migrations_dir="$SCRIPT_DIR/migrations/perf"
fi
if [[ -z "$db_name" ]]; then
    echo "Для '$target' не задано имя базы в $ENV_FILE — добавьте переменные из infra/db/.env.example (для telegram: TELEGRAM_POSTGRES_*)." >&2
    exit 1
fi

# Мигратор — единственная роль с правом DDL и владелец обеих баз (см.
# infra/db/README.md, "Три роли"); AUTH_/WALLET_POSTGRES_USER сюда не годятся —
# у них DDL нет вообще. Хост "db" — сетевой алиас контейнера "db" в
# compose-сети (см. ниже), НЕ localhost: реальная связность — через обычную
# bridge-сеть, ровно как у остальных сервисов (см. DATABASE_URL в
# compose.yaml — те тоже пишут "db", не "localhost").
database_url="postgres://${MIGRATOR_POSTGRES_USER}:${MIGRATOR_POSTGRES_PASSWORD}@db:5432/${db_name}?sslmode=disable"

# Ищем контейнер "db" по compose-лейблу сервиса, а не по имени
# (сгенерированное имя вроде "servers-db-1" зависит от имени папки проекта —
# не полагаемся на него). Лейбл ставит Docker Compose v2: "com.docker.compose.service".
db_container="$(docker ps --filter "label=com.docker.compose.service=db" --format '{{.Names}}' | head -n1)"
if [[ -z "$db_container" ]]; then
    echo "Не нашёл запущенный контейнер 'db' (com.docker.compose.service=db)." >&2
    echo "Сначала: docker compose --env-file infra/db/.env up -d db" >&2
    exit 1
fi

# Имя bridge-сети тоже не хардкодим (оно с префиксом имени папки проекта,
# см. выше про "db") — берём фактическую сеть, к которой уже подключён
# контейнер "db" (у него ровно одна).
db_network="$(docker inspect "$db_container" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')"
if [[ -z "$db_network" ]]; then
    echo "Не нашёл сеть контейнера '$db_container'." >&2
    exit 1
fi

# Базы цели ещё нет — значит, volume db-data инициализирован раньше, чем в
# init-db.sh появилась эта база (так было с telegram): сам образ postgres
# гоняет /docker-entrypoint-initdb.d только на ПУСТОМ volume. Догоняем
# bootstrap тем же скриптом — он идемпотентный (CREATE ... WHERE NOT EXISTS,
# GRANT/ALTER DEFAULT PRIVILEGES повторяемы), существующие роли и базы не
# трогает. Переменные передаём явно из infra/db/.env: у давно созданного
# контейнера "db" в окружении их может не быть. psql внутри контейнера ходит
# через unix-сокет — пароль мигратора не нужен.
db_exists="$(docker exec "$db_container" psql -U "$MIGRATOR_POSTGRES_USER" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '${db_name}'")"
if [[ "$db_exists" != "1" ]]; then
    echo "==> База ${db_name} не найдена — прогоняю infra/db/init-db.sh (идемпотентно)"
    docker exec -i \
        -e POSTGRES_USER="$MIGRATOR_POSTGRES_USER" \
        -e AUTH_POSTGRES_USER="${AUTH_POSTGRES_USER:-}" -e AUTH_POSTGRES_PASSWORD="${AUTH_POSTGRES_PASSWORD:-}" \
        -e AUTH_POSTGRES_DB="${AUTH_POSTGRES_DB:-}" \
        -e WALLET_POSTGRES_USER="${WALLET_POSTGRES_USER:-}" -e WALLET_POSTGRES_PASSWORD="${WALLET_POSTGRES_PASSWORD:-}" \
        -e WALLET_POSTGRES_DB="${WALLET_POSTGRES_DB:-}" \
        -e MONITORING_POSTGRES_USER="${MONITORING_POSTGRES_USER:-}" \
        -e MONITORING_POSTGRES_PASSWORD="${MONITORING_POSTGRES_PASSWORD:-}" \
        -e PERF_POSTGRES_USER="${PERF_POSTGRES_USER:-}" -e PERF_POSTGRES_PASSWORD="${PERF_POSTGRES_PASSWORD:-}" \
        -e PERF_POSTGRES_DB="${PERF_POSTGRES_DB:-}" \
        -e TELEGRAM_POSTGRES_USER="${TELEGRAM_POSTGRES_USER:-}" \
        -e TELEGRAM_POSTGRES_PASSWORD="${TELEGRAM_POSTGRES_PASSWORD:-}" \
        -e TELEGRAM_POSTGRES_DB="${TELEGRAM_POSTGRES_DB:-}" \
        "$db_container" sh < "$SCRIPT_DIR/init-db.sh"
fi

exec docker run --rm \
    --network "${db_network}" \
    -v "${migrations_dir}:/migrations:ro" \
    docker.io/migrate/migrate \
    -path=/migrations -database "$database_url" "$@"
