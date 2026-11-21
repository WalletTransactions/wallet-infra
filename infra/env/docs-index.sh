#!/bin/bash
# Заливка индекса wallet-docs (change docs-index-upload): OpenSpec-спеки
# репозиториев из рабочей папки организации → PUT /docs/index/{repo}.
#
# Использование:
#   infra/env/docs-index.sh <prod|test> <репозиторий|all> [--strict]
#     all      — все каталоги рядом с wallet-infra, в которых есть openspec/
#     --strict — любой отказ даёт ненулевой код (ручная проверка, CI)
#
# Примеры:
#   infra/env/docs-index.sh test wallet-gateway
#   infra/env/docs-index.sh test all
#
# Мягкий отказ (design D5): профиль docs выключен, контейнера wallet-docs нет,
# репозитория нет на диске или сервис ответил не 2xx — строка
# `docs-index: <причина>` и код 0 (при all — дальше по списку). Jenkins
# (job docs-index) по этой строке ставит UNSTABLE.
#
# Источник — рабочая папка организации (WALLET_TRANSACTIONS_PATH, иначе
# каталог над wallet-infra), а не git-клон (D1): *.md из openspec/ и файлы
# README.md (вид ops в wallet-docs, только для админа) — обычные файлы без
# симлинков (D4), без third_party/, node_modules/, .worktrees/, build/, vendor/.
# JSON собирает jq (D3): python3 в контейнере Jenkins нет.
#
# mTLS: запрос идёт внутри контейнера wallet-docs; если в его окружении задан
# TLS_CERT, — по https с сертификатом самого контейнера, иначе по http (change
# docs-index-mtls-readme). Сеть и стек Jenkins в этом не участвуют.
#
# Токен: запрос отправляется ИЗНУТРИ контейнера wallet-docs (D2) — INDEX_TOKEN
# остаётся в его окружении. В заголовок он попадает через файл (`curl -H
# @файл`, файл пишет встроенный printf оболочки), поэтому не появляется ни в
# аргументах процессов (ps на хосте видит процессы контейнеров), ни в выводе.
# Не включайте здесь set -x.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
    die "использование: docs-index.sh <prod|test> <репозиторий|all> [--strict]"
}

env_init "${1:-}"
target="${2:-}"
[[ -n "$target" ]] || usage
strict=0
if [[ $# -ge 3 ]]; then
    [[ "$3" == "--strict" && $# -eq 3 ]] || usage
    strict=1
fi

# Лимит тела сервиса (спека docs-indexing): больше — 413, предупреждаем сами.
readonly max_body_bytes=$((16 * 1024 * 1024))
repo_re='^[a-z0-9][a-z0-9-]{0,63}$'
src_root="${WALLET_TRANSACTIONS_PATH:-$(dirname "$WALLET_INFRA_DIR")}"
failures=0

# warn <причина> — мягкий отказ: строка для журнала и UNSTABLE в Jenkins.
warn() {
    echo "docs-index: $*"
    failures=$((failures + 1))
}

finish() {
    if [[ $failures -gt 0 && $strict -eq 1 ]]; then
        exit 1
    fi
    exit 0
}

if ! env_docs_enabled; then
    warn "профиль docs выключен в infra/env/$ENV_NAME.env — заливать некуда"
    finish
fi

env_check_secrets
env_check_tags
env_lock

container="$(env_compose ps -q wallet-docs 2>/dev/null || true)"
if [[ -z "$container" || "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" != "true" ]]; then
    warn "контейнер wallet-docs контура $ENV_NAME не запущен"
    finish
fi

# Список репозиториев.
repos=()
if [[ "$target" == "all" ]]; then
    for d in "$src_root"/*/; do
        name="$(basename "$d")"
        [[ "$name" =~ $repo_re && -d "$d/openspec" && ! -L "${d%/}" ]] && repos+=("$name")
    done
    [[ ${#repos[@]} -gt 0 ]] || { warn "в $src_root нет каталогов с openspec/"; finish; }
else
    [[ "$target" =~ $repo_re ]] || die "имя репозитория '$target' не подходит под $repo_re"
    repos=("$target")
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# collect <каталог> — пути файлов заливки (через NUL): openspec/**/*.md и README.md
# любой глубины (вид ops в wallet-docs). Вендорные и служебные каталоги пропускаются,
# симлинки не читаются (-type f их не берёт, каталоги по ссылкам find не обходит).
collect() {
    local dir="$1"
    {
        find "$dir/openspec" -type f -name '*.md' -print0
        find "$dir" \( -name third_party -o -name node_modules -o -name .worktrees -o -name build \
            -o -name vendor -o -name .git -o -name openspec \) -prune -o -type f -name README.md -print0
    } | sort -z
}

# payload <каталог> <файл> — {"files":[{"path","content"}]} из collect.
payload() {
    local dir="$1" out="$2" f
    : > "$tmp/items"
    while IFS= read -r -d '' f; do
        jq -n --arg path "${f#"$dir"/}" --rawfile content "$f" '{path: $path, content: $content}' >> "$tmp/items"
    done < <(collect "$dir")
    jq -s '{files: .}' "$tmp/items" > "$out"
}

# Код выхода upload, когда файл сертификата контейнера не читается (не код curl).
readonly cert_unreadable=90

# upload <репозиторий> <файл тела> — печатает тело ответа, последней строкой — код.
# Всё выполняется ВНУТРИ контейнера wallet-docs (docker exec): сеть и стек Jenkins
# не участвуют, 127.0.0.1 и имя wallet-docs разрешаются в самом контейнере. mTLS
# определяется по его окружению (TLS_CERT задан — сервис слушает только по TLS):
# https://wallet-docs:8089 с собственным сертификатом контейнера (имя — по SAN);
# иначе обычный http://127.0.0.1:8089 (prod без mTLS).
upload() {
    # shellcheck disable=SC2016  # $INDEX_TOKEN, $1, TLS_* раскрывает sh в контейнере
    docker exec -i "$container" sh -c '
        h="$(mktemp)"
        trap "rm -f \"$h\"" EXIT
        printf "X-Index-Token: %s\n" "${INDEX_TOKEN:-}" > "$h"
        if [ -n "${TLS_CERT:-}" ]; then
            [ -r "$TLS_CERT" ] && [ -r "${TLS_KEY:-}" ] && [ -r "${TLS_CA:-}" ] || exit '"$cert_unreadable"'
            curl -sS --max-time 3000 --cacert "$TLS_CA" --cert "$TLS_CERT" --key "$TLS_KEY" \
                -w "\n%{http_code}" -X PUT "https://wallet-docs:8089/docs/index/$1" \
                -H @"$h" -H "Content-Type: application/json" --data-binary @-
        else
            curl -sS --max-time 3000 -w "\n%{http_code}" -X PUT "http://127.0.0.1:8089/docs/index/$1" \
                -H @"$h" -H "Content-Type: application/json" --data-binary @-
        fi
    ' sh "$1" < "$2"
}

# explain_failure <код выхода> <вывод> — причина отказа запроса, без токена: curl -sS
# печатает только свою ошибку, значения заголовков в неё не попадают.
explain_failure() {
    local rc="$1" out="$2" detail
    detail="$(sed -n '1p' <<< "$out" | tr -d '\r')"
    if [[ "$rc" -eq "$cert_unreadable" ]]; then
        echo "сертификат контейнера не читается (TLS_CERT, TLS_KEY или TLS_CA)"
    elif [[ "$rc" -ge 125 && "$rc" -le 127 ]]; then
        echo "docker exec не выполнен (код $rc): $detail"
    elif [[ "$rc" =~ ^(35|51|58|59|60|77|83|91)$ ]] || grep -qiE 'ssl|tls|certificate' <<< "$out"; then
        echo "TLS-рукопожатие не прошло (curl $rc): $detail"
    else
        echo "сервис недоступен (curl $rc): $detail"
    fi
}

for repo in "${repos[@]}"; do
    dir="$src_root/$repo"
    if [[ ! -d "$dir/openspec" ]]; then
        warn "$repo: нет $dir/openspec — пропущен"
        continue
    fi
    payload "$dir" "$tmp/body.json"
    files="$(jq '.files | length' "$tmp/body.json")"
    size="$(stat -c %s "$tmp/body.json")"
    if [[ "$size" -gt "$max_body_bytes" ]]; then
        warn "$repo: тело $size байт больше лимита сервиса 16 МБ — пропущен"
        continue
    fi

    started=$SECONDS
    rc=0
    response="$(upload "$repo" "$tmp/body.json" 2>&1)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        warn "$repo: запрос к wallet-docs не выполнен: $(explain_failure "$rc" "$response")"
        continue
    fi
    code="$(tail -n1 <<< "$response")"
    body="$(sed '$d' <<< "$response")"
    if [[ "$code" != 2* ]]; then
        warn "$repo: wallet-docs ответил $code $(jq -r '.error? // empty' <<< "$body" 2>/dev/null || true)"
        continue
    fi
    echo "$repo: $(jq -r '"chunks=\(.chunks) embedded=\(.embedded) reused=\(.reused) skipped=\(.skipped)"' <<< "$body") files=$files за $((SECONDS - started)) с"
done

finish
