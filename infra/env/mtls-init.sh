#!/bin/bash
# Создаёт CA контура для взаимного TLS (openspec/changes/add-internal-mtls, design D2).
# Выполняется ОДИН РАЗ на хосте, не в Jenkins: тот монтирует секреты только на чтение
# и CA создать не может, а выкат только читает готовый.
#
#   bash infra/env/mtls-init.sh <prod|test>
#
# Закрытый ключ CA — ~/.config/wallet-secrets/<env>/mtls-ca/ca.key (права 600), в
# контейнеры сервисов не монтируется. Повторный запуск ничего не меняет, если CA есть.
# Сертификаты сервисов выпускает mtls.sh при каждом up.sh и выкате.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

env_init "${1:-}"
_mtls_ca >/dev/null
echo "CA контура $ENV_NAME: $SECRETS_DIR/mtls-ca/ca.crt (до $(openssl x509 -in "$SECRETS_DIR/mtls-ca/ca.crt" -noout -enddate | cut -d= -f2))"
