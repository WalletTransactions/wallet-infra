#!/bin/bash
# Перезаливка данных test из prod (design D9, спека test-data-refresh; job
# env-test-refresh). Ручная операция: обычный test живёт на своих данных.
#
# Использование:
#   infra/env/test-refresh.sh
#
# Порядок (под блокировкой test — выкат в test ждёт окончания):
#   1. stop всех сервисов test, кроме db и redis (никто не пишет в базы);
#   2. базы auth, wallet, telegram, ai в test — DROP ... WITH (FORCE), затем
#      init-db.sh (идемпотентно) создаёт их пустыми с владельцем и правами,
#      как на свежем томе. Не pg_restore --clean поверх старой базы: объекты
#      миграций test, которых ещё нет в prod, остались бы, и накат ниже упал
#      бы на «already exists»;
#   3. pg_dump -Fc каждой базы prod ролью dumper (pg_read_all_data — ни одной
#      записи в prod) потоком в pg_restore --clean --if-exists базы test.
#      Без файла на диске: персональные данные prod не остаются в каталоге
#      дампов;
#   4. миграции test из образов, выкатанных в test (схема test новее prod —
#      её миграции накатываются поверх);
#   5. вычистка всего, что принадлежит prod: TRUNCATE telegram_links (auth),
#      tg_link и tg_update_offset (telegram); FLUSHALL Redis test — все сессии
#      и refresh-токены;
#   6. up.sh test.
#
# Упало посреди — сервисы test остаются остановленными (данные могли
# частично смениться); повторный запуск начинает с шага 1.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASES=(auth wallet telegram ai)

# --- prod: только чтение -----------------------------------------------
env_init prod
env_check_secrets
env_check_tags
prod_db="$(env_compose ps -q db)"
[[ -n "$prod_db" ]] || die "db контура prod не запущена"
set -a
# shellcheck disable=SC1091
source "$SECRETS_DIR/db.env"
set +a
dump_user="${DUMPER_POSTGRES_USER:?в db.env prod нет DUMPER_POSTGRES_USER}"
dump_pw="${DUMPER_POSTGRES_PASSWORD:?в db.env prod нет DUMPER_POSTGRES_PASSWORD}"
declare -A prod_name
for base in "${BASES[@]}"; do
    v="${base^^}_POSTGRES_DB"
    prod_name[$base]="${!v:?в db.env prod не задан $v}"
done

# --- test ----------------------------------------------------------------
env_init test
env_check_secrets
env_check_tags
env_lock
set -a
# shellcheck disable=SC1091
source "$SECRETS_DIR/db.env"
set +a
test_db="$(env_compose ps -q db)"
[[ -n "$test_db" ]] || die "db контура test не запущена — сначала infra/env/up.sh test"
[[ "$test_db" != "$prod_db" ]] || die "db test и prod — один контейнер?"

trap 'echo "ОШИБКА: перезаливка прервана — сервисы test остановлены; повторите test-refresh.sh" >&2' ERR

echo "==> [test] остановка сервисов (кроме db и redis)"
mapfile -t services < <(env_compose config --services | grep -vxE 'db|redis')
env_compose stop "${services[@]}"

# tpsql <база> — psql суперпользователем в db test, SQL из stdin.
tpsql() {
    docker exec -i "$test_db" sh -c 'psql -v ON_ERROR_STOP=1 -q -U "$POSTGRES_USER" -d "$1"' sh "$1"
}

declare -A test_name
for base in "${BASES[@]}"; do
    v="${base^^}_POSTGRES_DB"
    test_name[$base]="${!v:?в db.env test не задан $v}"
    echo "==> [test] пересоздаю базу ${test_name[$base]}"
    tpsql postgres <<<"DROP DATABASE IF EXISTS \"${test_name[$base]}\" WITH (FORCE);"
done
docker exec "$test_db" sh /docker-entrypoint-initdb.d/init-db.sh >/dev/null

for base in "${BASES[@]}"; do
    echo "==> prod ${prod_name[$base]} → test ${test_name[$base]}"
    # Пароль dumper — через окружение docker exec (-e без значения).
    PGPASSWORD="$dump_pw" docker exec -e PGPASSWORD "$prod_db" \
        pg_dump -h 127.0.0.1 -U "$dump_user" -d "${prod_name[$base]}" -Fc \
    | docker exec -i "$test_db" sh -c \
        'pg_restore -U "$POSTGRES_USER" -d "$1" --clean --if-exists --exit-on-error --single-transaction' \
        sh "${test_name[$base]}"
done

for base in "${BASES[@]}"; do
    bash "$WALLET_INFRA_DIR/infra/env/migrate.sh" test "$base"
done

echo "==> [test] вычистка привязок Telegram и сессий"
tpsql "${test_name[auth]}" <<<"TRUNCATE telegram_links;"
tpsql "${test_name[telegram]}" <<<"TRUNCATE tg_link, tg_update_offset;"
env_compose exec -T redis redis-cli FLUSHALL >/dev/null

trap - ERR
bash "$WALLET_INFRA_DIR/infra/env/up.sh" test
log_history test-refresh - - ok
echo "==> [test] перезалит из prod"
