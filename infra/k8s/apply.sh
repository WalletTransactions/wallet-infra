#!/bin/bash
# Разворачивает весь compose.yaml-стек в текущем kube-контексте (namespace
# wallet-transaction). Ничего не билдит образы (см. infra/k8s/README.md, "Сборка
# образов" — сделайте это один раз перед первым запуском и после каждого
# изменения кода сервиса) — только секреты/конфиги/манифесты и порядок:
# db → миграции → остальные сервисы, тот же порядок, что в README.md
# ("Перед первым запуском") и infra/db/README.md ("Миграции").
#
# Использование:
#   bash infra/k8s/apply.sh              # секреты/конфиги + весь стек + миграции
#   bash infra/k8s/apply.sh --secrets-only  # только пересоздать секреты/конфиги
#                                      # (после правки .env-файлов), без apply
set -euo pipefail

# MSYS (Git Bash на Windows) молча переписывает похожие на unix-путь
# аргументы в Windows-пути — та же засада, что уже ловили в infra/db/migrate.sh.
export MSYS_NO_PATHCONV=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Сервисы — соседние репозитории рядом с wallet-infra (WalletTransactions/<сервис>).
WORKSPACE_DIR="$(cd "$ROOT_DIR/.." && pwd)"
NS=wallet-transaction
KCTL=(kubectl --namespace "$NS")

require_file() {
    if [[ ! -f "$1" ]]; then
        echo "Не найден $1 — см. корневой README.md, \"Перед первым запуском\"." >&2
        exit 1
    fi
}

require_file "$ROOT_DIR/infra/db/.env"
require_file "$WORKSPACE_DIR/google-auth/.env"
require_file "$WORKSPACE_DIR/google-auth/jwt_signing_key.pem"
require_file "$WORKSPACE_DIR/wallet-api/.env"
require_file "$WORKSPACE_DIR/wallet-report/.env"
require_file "$WORKSPACE_DIR/wallet-telegram/.env"

echo "==> namespace"
kubectl apply -f "$ROOT_DIR/infra/k8s/00-namespace.yaml"

echo "==> секреты и конфиги (из .env-файлов и db/, НЕ из git)"

# db-credentials — как есть, без пересчёта (используется только внутри
# кластера самим Postgres и Job'ами миграций, все ключи ему и так нужны).
kubectl create secret generic db-credentials -n "$NS" \
    --from-env-file="$ROOT_DIR/infra/db/.env" \
    --dry-run=client -o yaml | "${KCTL[@]}" apply -f -

# Считываем infra/db/.env в текущий шелл — нужны реальные пароли, чтобы собрать
# DATABASE_URL для google-auth/wallet-api (см. ниже) с хостом "db" вместо
# localhost из .env.example (тот же приём, что и явные overrides в
# compose.yaml у сервисов google-auth/wallet-api).
set -a
source "$ROOT_DIR/infra/db/.env"
set +a

# google-auth-env — весь google-auth/.env, КРОМЕ DATABASE_URL/REDIS_HOST/
# REDIS_PORT (у них в .env — localhost-заглушки для локального запуска без
# контейнеров, см. .env.example) — эти три пересчитаны на адреса Service'ов
# в кластере. Остальное (GOOGLE_CLIENT_ID/SECRET, REDIRECT_URL,
# JWT_RSA_PRIVATE_KEY_PATH, COOKIE_SECURE, ADMIN_EMAILS/SUPPORT_EMAILS,
# TTL...) — без изменений.
grep -vE '^(DATABASE_URL|REDIS_HOST|REDIS_PORT)=' "$WORKSPACE_DIR/google-auth/.env" \
    > "$ROOT_DIR/infra/k8s/.google-auth.env.filtered"
kubectl create secret generic google-auth-env -n "$NS" \
    --from-env-file="$ROOT_DIR/infra/k8s/.google-auth.env.filtered" \
    --from-literal=DATABASE_URL="postgresql://${AUTH_POSTGRES_USER}:${AUTH_POSTGRES_PASSWORD}@db:5432/${AUTH_POSTGRES_DB}" \
    --from-literal=REDIS_HOST=redis \
    --from-literal=REDIS_PORT=6379 \
    --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
rm -f "$ROOT_DIR/infra/k8s/.google-auth.env.filtered"

# Приватный RSA-ключ подписи access-токенов — отдельный секрет (файл, не
# строка), монтируется в google-auth как volume (см. infra/k8s/04-google-auth.yaml).
kubectl create secret generic google-auth-jwt-key -n "$NS" \
    --from-file=jwt_signing_key.pem="$WORKSPACE_DIR/google-auth/jwt_signing_key.pem" \
    --dry-run=client -o yaml | "${KCTL[@]}" apply -f -

# wallet-api-env — та же логика: DATABASE_URL пересчитан на СВОИ (WALLET_*)
# креды и хост "db"; AUTH_SERVICE_URL из .env — тоже localhost-заглушка, но
# её (не секрет) переопределяет env: прямо в infra/k8s/05-wallet-api.yaml, здесь
# фильтровать не нужно.
grep -vE '^DATABASE_URL=' "$WORKSPACE_DIR/wallet-api/.env" \
    > "$ROOT_DIR/infra/k8s/.wallet-api.env.filtered"
kubectl create secret generic wallet-api-env -n "$NS" \
    --from-env-file="$ROOT_DIR/infra/k8s/.wallet-api.env.filtered" \
    --from-literal=DATABASE_URL="postgresql://${WALLET_POSTGRES_USER}:${WALLET_POSTGRES_PASSWORD}@db:5432/${WALLET_POSTGRES_DB}" \
    --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
rm -f "$ROOT_DIR/infra/k8s/.wallet-api.env.filtered"

# wallet-report-env — та же логика: REPORTS_DATABASE_URL пересчитан на ТУ ЖЕ
# WALLET_POSTGRES_DB, но ролью wallet_reader (креды зашиты литералом, см.
# wallet-api/schema/role/wallet_reader.sql и compose.yaml, сервис wallet-report);
# AUTH_SERVICE_URL из .env — localhost-заглушка, но её (не секрет)
# переопределяет env: прямо в infra/k8s/08-wallet-report.yaml, здесь
# фильтровать не нужно.
grep -vE '^REPORTS_DATABASE_URL=' "$WORKSPACE_DIR/wallet-report/.env" \
    > "$ROOT_DIR/infra/k8s/.wallet-report.env.filtered"
kubectl create secret generic wallet-report-env -n "$NS" \
    --from-env-file="$ROOT_DIR/infra/k8s/.wallet-report.env.filtered" \
    --from-literal=REPORTS_DATABASE_URL="postgresql://wallet_reader:wallet_reader@db:5432/${WALLET_POSTGRES_DB}" \
    --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
rm -f "$ROOT_DIR/infra/k8s/.wallet-report.env.filtered"

# wallet-telegram-env — та же логика: DATABASE_URL пересчитан на СВОИ
# (TELEGRAM_*) креды и хост "db"; AUTH_SERVICE_URL переопределяет env: в
# infra/k8s/09-wallet-telegram.yaml.
grep -vE '^DATABASE_URL=' "$WORKSPACE_DIR/wallet-telegram/.env" \
    > "$ROOT_DIR/infra/k8s/.wallet-telegram.env.filtered"
kubectl create secret generic wallet-telegram-env -n "$NS" \
    --from-env-file="$ROOT_DIR/infra/k8s/.wallet-telegram.env.filtered" \
    --from-literal=DATABASE_URL="postgresql://${TELEGRAM_POSTGRES_USER}:${TELEGRAM_POSTGRES_PASSWORD}@db:5432/${TELEGRAM_POSTGRES_DB}" \
    --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
rm -f "$ROOT_DIR/infra/k8s/.wallet-telegram.env.filtered"

# wallet-ai-db — только DATABASE_URL своей базы ai (импорт выписок) с хостом
# "db"; остальные настройки wallet-ai — env: в infra/k8s/10-wallet-ai.yaml.
kubectl create secret generic wallet-ai-db -n "$NS" \
    --from-literal=DATABASE_URL="postgresql://${AI_POSTGRES_USER}:${AI_POSTGRES_PASSWORD}@db:5432/${AI_POSTGRES_DB}" \
    --dry-run=client -o yaml | "${KCTL[@]}" apply -f -

# ConfigMap'ы из самостоятельных файлов (не копии внутри YAML, см.
# комментарии в infra/k8s/01-db.yaml и infra/k8s/03-migrate-job.yaml).
kubectl create configmap db-init-script -n "$NS" \
    --from-file=init-db.sh="$ROOT_DIR/infra/db/init-db.sh" \
    --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
kubectl create configmap migrate-auth-sql -n "$NS" \
    --from-file="$WORKSPACE_DIR/google-auth/migrations" \
    --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
kubectl create configmap migrate-wallet-sql -n "$NS" \
    --from-file="$WORKSPACE_DIR/wallet-api/migrations" \
    --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
kubectl create configmap migrate-telegram-sql -n "$NS" \
    --from-file="$WORKSPACE_DIR/wallet-telegram/migrations" \
    --dry-run=client -o yaml | "${KCTL[@]}" apply -f -
kubectl create configmap migrate-ai-sql -n "$NS" \
    --from-file="$WORKSPACE_DIR/wallet-ai/migrations" \
    --dry-run=client -o yaml | "${KCTL[@]}" apply -f -

if [[ "${1:-}" == "--secrets-only" ]]; then
    echo "Готово (только секреты/конфиги, без apply остального)."
    exit 0
fi

echo "==> db + redis"
"${KCTL[@]}" apply -f "$ROOT_DIR/infra/k8s/01-db.yaml"
"${KCTL[@]}" apply -f "$ROOT_DIR/infra/k8s/02-redis.yaml"

echo "==> ждём db..."
"${KCTL[@]}" wait --for=condition=available --timeout=120s deployment/db

echo "==> миграции (см. infra/db/README.md \"Миграции\" — force вместо up, если база уже существовала ДО перехода на golang-migrate, см. README)"
"${KCTL[@]}" delete job db-migrate-auth db-migrate-wallet db-migrate-telegram db-migrate-ai --ignore-not-found
"${KCTL[@]}" apply -f "$ROOT_DIR/infra/k8s/03-migrate-job.yaml"
"${KCTL[@]}" wait --for=condition=complete --timeout=120s job/db-migrate-auth job/db-migrate-wallet job/db-migrate-telegram job/db-migrate-ai

echo "==> google-auth, wallet-api, wallet-report, wallet-ai, wallet-gateway, wallet-web, wallet-telegram"
"${KCTL[@]}" apply -f "$ROOT_DIR/infra/k8s/04-google-auth.yaml"
"${KCTL[@]}" apply -f "$ROOT_DIR/infra/k8s/05-wallet-api.yaml"
"${KCTL[@]}" apply -f "$ROOT_DIR/infra/k8s/08-wallet-report.yaml"
"${KCTL[@]}" apply -f "$ROOT_DIR/infra/k8s/10-wallet-ai.yaml"
"${KCTL[@]}" apply -f "$ROOT_DIR/infra/k8s/06-wallet-gateway.yaml"
"${KCTL[@]}" apply -f "$ROOT_DIR/infra/k8s/07-wallet-web.yaml"
"${KCTL[@]}" apply -f "$ROOT_DIR/infra/k8s/09-wallet-telegram.yaml"

echo "==> готово. Доступ: kubectl port-forward -n $NS svc/wallet-gateway 8090:8090"
echo "    (важно — именно port-forward, не NodePort напрямую: REDIRECT_URL в"
echo "     google-auth/.env и Google Cloud Console завязаны на localhost:8090)"
