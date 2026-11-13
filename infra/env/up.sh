#!/bin/bash
# Поднимает (или приводит в соответствие с compose.yaml и tags.env) весь
# контур: сеть → db, redis → миграции всех баз → остальные сервисы.
# Повторный запуск безопасен: миграции без новых файлов — no change, compose
# пересоздаёт только контейнеры, чьё описание или образ поменялись.
#
# Использование:
#   infra/env/up.sh <prod|test>
#
# Обычный выкат версии сервиса — не этот скрипт, а infra/env/deploy.sh
# (миграции одной базы, гейт, smoke, откат). up.sh — первый запуск контура и
# выкат самого wallet-infra.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

env_init "${1:-}"
env_check_secrets
env_check_tags
env_lock

# Сеть external (compose.yaml): к ней подключается стек метрик, поэтому
# создаётся отдельно от проекта и переживает `compose down`.
if ! docker network inspect "wallet-$ENV_NAME" >/dev/null 2>&1; then
    echo "==> создаю сеть wallet-$ENV_NAME"
    docker network create "wallet-$ENV_NAME" >/dev/null
fi

echo "==> [$ENV_NAME] db, redis"
env_compose up -d --wait db redis

# Через bash, а не по биту исполнения: рабочая папка на NTFS его не хранит.
for base in auth wallet telegram ai; do
    bash "$WALLET_INFRA_DIR/infra/env/migrate.sh" "$ENV_NAME" "$base"
done
# База нагрузочных прогонов — только в test: loadtest в prod не ходит.
if [[ "$ENV_NAME" == "test" ]]; then
    bash "$WALLET_INFRA_DIR/infra/env/migrate.sh" "$ENV_NAME" perf
fi
# docs — необязательный модуль (change wallet-docs-assistant, design D6):
# миграции и сервис — только при включённом профиле, заданной базе в db.env и
# теге образа в tags.env. Профиль включён, а чего-то нет — профиль на этот
# запуск выключается (COMPOSE_PROFILES процесса сильнее --env-file), иначе
# compose тянул бы образ wallet-docs:unset и весь up падал.
docs_db="$(sed -n 's/^DOCS_POSTGRES_DB=//p' "$SECRETS_DIR/db.env" | tail -n1)"
if env_docs_enabled && [[ -n "$docs_db" && -n "$(current_tag wallet-docs)" ]]; then
    bash "$WALLET_INFRA_DIR/infra/env/migrate.sh" "$ENV_NAME" docs
elif env_docs_enabled; then
    echo "==> [$ENV_NAME] docs пропущен: профиль включён, но нет DOCS_POSTGRES_DB в db.env или тега wallet-docs в tags.env"
    export COMPOSE_PROFILES=
else
    echo "==> [$ENV_NAME] docs пропущен: профиль docs выключен"
fi

echo "==> [$ENV_NAME] сервисы"
env_compose up -d --wait --wait-timeout 300 --remove-orphans

echo "==> [$ENV_NAME] готово:"
env_compose ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}'
