#!/bin/bash
# Дамп баз контура (design D6): перед миграцией в prod (его вызывает
# deploy.sh) и ежесуточно (Jenkins, prod-backup). Ролью dumper —
# pg_read_all_data, ни одной записи (infra/db/README.md, "Дополнительные роли").
#
# Использование:
#   infra/env/backup.sh <prod|test> [--label <метка>] [<база>...]
#     база  — auth, wallet, telegram, ai; по умолчанию все четыре
#     метка — в имени файла; по умолчанию "daily". deploy.sh ставит тег выката.
#
# Куда: ${WALLET_BACKUP_DIR}/<env>/<база>/<время>_<метка>.dump (pg_dump -Fc).
# WALLET_BACKUP_DIR обязателен и должен быть на ДРУГОМ физическом диске, чем
# тома docker (на этой машине — диск DATA, HDD): дамп рядом с базой не спасёт
# при отказе диска.
#
# Ротация в каталоге каждой базы: 7 последних "daily" и 3 последних
# остальных (дампы перед выкатами). Файл, который не читается pg_restore -l,
# не сохраняется, и скрипт завершается ошибкой — выкат в prod тогда не идёт.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KEEP_DAILY=7
KEEP_OTHER=3

env_init "${1:-}"
shift || true
label=daily
if [[ "${1:-}" == "--label" ]]; then
    label="${2:?--label требует значение}"
    shift 2
fi
[[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || die "метка '$label' — только буквы, цифры, точка, дефис, подчёркивание"
bases=("$@")
[[ ${#bases[@]} -gt 0 ]] || bases=(auth wallet telegram ai)
for base in "${bases[@]}"; do
    [[ "$base" != "docs" ]] || die "индекс docs не бэкапится — он пересобирается заливкой (infra/env/docs-index.sh)"
    [[ -n "${WALLET_DB_SERVICE[$base]:-}" ]] || die "база должна быть auth, wallet, telegram или ai, а не '$base'"
done

backup_root="${WALLET_BACKUP_DIR:?WALLET_BACKUP_DIR не задан — каталог дампов на другом диске, чем тома docker}"
env_check_secrets
env_check_tags
# Не посреди миграции: суточный дамп ждёт выкат (из deploy.sh — no-op,
# блокировка уже его).
env_lock

set -a
# shellcheck disable=SC1091
source "$SECRETS_DIR/db.env"
set +a
[[ -n "${DUMPER_POSTGRES_USER:-}" && -n "${DUMPER_POSTGRES_PASSWORD:-}" ]] \
    || die "в $SECRETS_DIR/db.env нет DUMPER_POSTGRES_USER/DUMPER_POSTGRES_PASSWORD"

db_container="$(env_compose ps -q db)"
[[ -n "$db_container" ]] || die "db контура $ENV_NAME не запущена"

stamp="$(date +%Y%m%dT%H%M%S)"
for base in "${bases[@]}"; do
    db_var="${base^^}_POSTGRES_DB"
    db_name="${!db_var:?в db.env не задан $db_var}"
    dir="$backup_root/$ENV_NAME/$base"
    mkdir -p "$dir"
    file="$dir/${stamp}_${label}.dump"

    echo "==> [$ENV_NAME] дамп $base ($db_name) → $file"
    # Пароль — через окружение docker exec (-e без значения), не аргументом.
    if ! PGPASSWORD="$DUMPER_POSTGRES_PASSWORD" docker exec -e PGPASSWORD "$db_container" \
            pg_dump -h 127.0.0.1 -U "$DUMPER_POSTGRES_USER" -d "$db_name" -Fc > "$file.tmp"; then
        rm -f "$file.tmp"
        die "pg_dump $db_name не удался"
    fi
    if ! docker exec -i "$db_container" pg_restore -l < "$file.tmp" > /dev/null; then
        rm -f "$file.tmp"
        die "дамп $db_name не читается pg_restore -l"
    fi
    mv "$file.tmp" "$file"
    echo "    $(du -h "$file" | cut -f1)"

    # Ротация: имена начинаются с времени, поэтому sort по имени = по времени.
    find "$dir" -maxdepth 1 -name '*_daily.dump' -printf '%f\n' | sort -r \
        | tail -n +$((KEEP_DAILY + 1)) | while read -r old; do rm -f "$dir/$old"; done
    find "$dir" -maxdepth 1 -name '*.dump' ! -name '*_daily.dump' -printf '%f\n' | sort -r \
        | tail -n +$((KEEP_OTHER + 1)) | while read -r old; do rm -f "$dir/$old"; done
done
