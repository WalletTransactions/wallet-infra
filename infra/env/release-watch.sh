#!/bin/bash
# Что пора выкатить (design D5, job env-release-watch): теги образов в ghcr и
# git-теги wallet-infra против того, что сейчас в контурах. Сам ничего не
# выкатывает — печатает в stdout строки "<env> <сервис> <тег>", по каждой
# job запускает env-deploy. Пояснения — в stderr.
#
# Использование:
#   infra/env/release-watch.sh
#
# Правило (спека release-promotion, «Тег определяет контур»):
#   - старший X.Y.Z-rc.N → test, если он новее выкатанного в test;
#   - старший X.Y.Z      → prod, если он новее выкатанного в prod и уже
#     проверен в test (digest в test/verified, у wallet-infra — коммит).
#     Непроверенный не печатается, а только упоминается: иначе job падал бы на
#     гейте каждые 5 минут, пока rc этого коммита не пройдёт test.
#   - тег, выкат которого в этот контур уже падал (failed в history), не
#     повторяется: сломанный тег катился бы по кругу. Его заменит следующий.
# Сначала строки test, потом prod: финальный тег, запушенный сразу за rc,
# пройдёт гейт, как только job выкатит rc.
#
# Логин в ghcr — из ~/.docker/config.json (тот же, что у docker pull);
# значение в вывод и в аргументы процессов не попадает.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
env_init test   # ради STATE_ROOT; оба контура читаются из него

REPO_INFRA="${WALLET_INFRA_REPO:-https://github.com/WalletTransactions/wallet-infra.git}"
DOCKER_CFG="${DOCKER_CONFIG:-$HOME/.docker}/config.json"

note() { echo "    $*" >&2; }

# ver_key <тег без v> — ключ для sort -V: rc идёт перед финальным той же версии.
ver_key() {
    local t="$1"
    if [[ "$t" == *-rc.* ]]; then echo "${t%%-rc.*}.${t##*-rc.}"; else echo "$t.999999"; fi
}

# newer <a> <b> — a строго новее b (b может быть пустым).
newer() {
    [[ -z "$2" ]] && return 0
    [[ "$1" == "$2" ]] && return 1
    [[ "$(printf '%s\n%s\n' "$(ver_key "$1")" "$(ver_key "$2")" | sort -V | tail -n1)" == "$(ver_key "$1")" ]]
}

# newest <rc|final> — старший тег нужного вида из stdin (теги без v).
newest() {
    local re='^[0-9]+\.[0-9]+\.[0-9]+$'
    [[ "$1" == rc ]] && re='^[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$'
    local t best=""
    while read -r t; do
        [[ "$t" =~ $re ]] || continue
        newer "$t" "$best" && best="$t"
    done
    echo "$best"
}

# failed_before <env> <сервис> <тег как в history> — выкат уже падал.
failed_before() {
    awk -F'\t' -v s="$2" -v t="$3" '$2 == s && $3 == t && $5 ~ /^failed/ { f = 1 } END { exit !f }' \
        "$STATE_ROOT/$1/history" 2>/dev/null
}

# ghcr <сервис> <путь после /v2/wallettransactions/<сервис>/> [curl...] —
# запрос к registry с токеном pull. Basic-учётка и bearer — через stdin
# (-H @-), не аргументами.
ghcr() {
    local svc="$1" path="$2" auth token
    shift 2
    auth="$(jq -r '.auths["ghcr.io"].auth // empty' "$DOCKER_CFG")"
    [[ -n "$auth" ]] || die "в $DOCKER_CFG нет логина ghcr.io (docker login ghcr.io)"
    token="$(curl -fsS -H @- "https://ghcr.io/token?service=ghcr.io&scope=repository:wallettransactions/$svc:pull" \
        <<<"Authorization: Basic $auth" | jq -r .token)"
    curl -fsS -H @- "$@" "https://ghcr.io/v2/wallettransactions/$svc/$path" <<<"Authorization: Bearer $token"
}

# digest <сервис> <тег> — digest манифеста, как его запишет docker pull.
digest() {
    ghcr "$1" "manifests/$2" -I \
        -H 'Accept: application/vnd.oci.image.index.v1+json' \
        -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
        -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        | tr -d '\r' | awk -F': ' 'tolower($1) == "docker-content-digest" { print $2 }'
}

# --- сервисы ---------------------------------------------------------------
for svc in "${!WALLET_SERVICE_PORT[@]}"; do
    tags="$(ghcr "$svc" "tags/list?n=1000" | jq -r '.tags[]?')" || {
        echo "ghcr: не удалось получить теги $svc" >&2
        continue
    }
    for env_name in test prod; do
        kind=rc
        [[ "$env_name" == prod ]] && kind=final
        STATE_DIR="$STATE_ROOT/$env_name"
        cur="$(current_tag "$svc")"
        want="$(newest "$kind" <<<"$tags")"
        [[ -n "$want" ]] && newer "$want" "$cur" || continue
        if failed_before "$env_name" "$svc" "$want"; then
            note "$env_name $svc $want — выкат уже падал, жду следующий тег"
            continue
        fi
        if [[ "$env_name" == prod ]]; then
            d="$(digest "$svc" "$want")"
            if ! grep -q "^$d " "$STATE_ROOT/test/verified" 2>/dev/null; then
                note "prod $svc $want (${d:-digest ?}) — ещё не проверен в test"
                continue
            fi
        fi
        note "$env_name $svc: ${cur:-(нет)} → $want"
        echo "$env_name $svc $want"
    done
done | sort -s -k1,1r   # test раньше prod

# --- wallet-infra ----------------------------------------------------------
# ls-remote без --refs: у аннотированного тега коммит — в строке "^{}".
# Нет доступа к GitHub — пропускаем только wallet-infra: выкат образов
# сервисов от него не зависит и не должен из-за него стоять.
if ! refs="$(infra_git ls-remote --tags "$REPO_INFRA")"; then
    echo "ВНИМАНИЕ: git ls-remote $REPO_INFRA не удался — теги wallet-infra не проверены" \
         "(нет ${WALLET_SECRETS_ROOT:-~/.config/wallet-secrets}/github-read.token? см. infra/env/README.md)" >&2
    exit 0
fi
infra_tags="$(awk '{ sub("refs/tags/v", "", $2); sub(/\^\{\}$/, "", $2); print $2 }' <<<"$refs" | sort -u)"
for env_name in test prod; do
    kind=rc
    [[ "$env_name" == prod ]] && kind=final
    checkout="$STATE_ROOT/$env_name/infra"
    cur=""
    if [[ -d "$checkout/.git" ]]; then
        cur="$(git -C "$checkout" describe --tags --exact-match HEAD 2>/dev/null || true)"
        cur="${cur#v}"
    fi
    want="$(newest "$kind" <<<"$infra_tags")"
    [[ -n "$want" ]] && newer "$want" "$cur" || continue
    if failed_before "$env_name" wallet-infra "v$want"; then
        note "$env_name wallet-infra v$want — выкат уже падал, жду следующий тег"
        continue
    fi
    if [[ "$env_name" == prod ]]; then
        commit="$(awk -v r="refs/tags/v$want" '$2 == r "^{}" { c = $1 } $2 == r && !c { c = $1 } END { print c }' <<<"$refs")"
        if ! grep -q "^git:$commit " "$STATE_ROOT/test/verified" 2>/dev/null; then
            note "prod wallet-infra v$want (${commit:0:8}) — ещё не проверен в test"
            continue
        fi
    fi
    note "$env_name wallet-infra: ${cur:-(нет)} → $want"
    echo "$env_name wallet-infra $want"
done
