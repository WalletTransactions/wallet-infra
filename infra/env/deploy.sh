#!/bin/bash
# Выкат одной версии в контур (design D5, D6; спека release-promotion).
#
# Использование:
#   infra/env/deploy.sh <prod|test> <сервис> <тег> [--rollback]
#     сервис — google-auth, wallet-api, wallet-report, wallet-ai,
#              wallet-gateway, wallet-web, wallet-telegram или wallet-infra
#     тег    — X.Y.Z-rc.N или X.Y.Z (с "v" или без); в prod — только X.Y.Z
#     --rollback — ручной откат на ранее выкатанный тег: без миграций и без
#              гейта (job env-rollback). Миграции при откате не откатываются —
#              поэтому они пишутся по expand/contract (infra/db/README.md).
#
# Порядок для сервиса:
#   1. блокировка контура (ждёт чужой выкат/перезаливку);
#   2. docker pull, digest образа;
#   3. prod: digest должен быть в test/verified — иначе «digest не проверен в test»;
#   4. у сервиса есть база: prod — дамп (backup.sh), затем миграции из образа.
#      Упал дамп или миграция — контейнер сервиса не трогается;
#   5. новый тег в tags.env, compose up только этого сервиса, ждём healthy;
#   6. smoke: /healthz гейтвея и /version сервиса = версия тега (и коммит
#      образа, если CI его проставил);
#   7. не прошло — прежний тег обратно и compose up, job падает;
#      прошло — digest в verified (для test — пропуск в prod), строка в history.
#
# wallet-infra: checkout git-тега в <state>/<env>/infra (оттуда дальше берут
# compose.yaml все скрипты контура), up.sh из него, smoke гейтвея; не прошло —
# прежний тег и up.sh ещё раз. Теги сервисов при этом не меняются: они в
# tags.env, а не в git. Гейт prod — тот же, по коммиту тега.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
    echo "Использование: $0 <prod|test> <сервис> <тег> [--rollback]" >&2
    exit 2
}

[[ $# -ge 3 ]] || usage
env_init "$1"
service="$2"
image_tag="${3#v}"
shift 3
rollback=0
for arg in "$@"; do
    case "$arg" in
        --rollback) rollback=1 ;;
        *) usage ;;
    esac
done

[[ "$image_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] \
    || die "тег '$3' — не X.Y.Z и не X.Y.Z-rc.N"
if [[ "$ENV_NAME" == "prod" && "$image_tag" == *-rc.* ]]; then
    die "в prod катится только финальный тег X.Y.Z, а не rc ($image_tag)"
fi
version="${image_tag%%-rc.*}"
verified_test="$STATE_ROOT/test/verified"

env_check_secrets
env_check_tags
env_lock

# smoke_gateway — гейтвей контура жив (изнутри его контейнера: скрипт может
# работать в контейнере Jenkins, где порт хоста недоступен по localhost).
smoke_gateway() {
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if env_compose exec -T wallet-gateway curl -fsS -o /dev/null http://127.0.0.1:8090/healthz 2>/dev/null; then
            return 0
        fi
        sleep 3
    done
    echo "smoke: /healthz гейтвея не отвечает" >&2
    return 1
}

# smoke_version <сервис> <ожидаемая версия> <коммит образа или пусто>
smoke_version() {
    local svc="$1" want="$2" revision="$3" host json got commit
    host="$svc"
    [[ "$svc" == "wallet-gateway" ]] && host=127.0.0.1
    json="$(env_compose exec -T wallet-gateway curl -fsS "http://$host:${WALLET_SERVICE_PORT[$svc]}/version")" || {
        echo "smoke: GET /version $svc не отвечает" >&2
        return 1
    }
    got="$(sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' <<<"$json")"
    commit="$(sed -n 's/.*"git_commit" *: *"\([^"]*\)".*/\1/p' <<<"$json")"
    echo "    /version $svc: $json"
    if [[ "$got" != "$want" ]]; then
        echo "smoke: $svc отдаёт версию '$got', ожидалась '$want'" >&2
        return 1
    fi
    if [[ "$revision" =~ ^[0-9a-f]{40}$ && -n "$commit" && "$revision" != "$commit"* ]]; then
        echo "smoke: $svc собран из коммита '$commit', а образ помечен '$revision'" >&2
        return 1
    fi
}

mark_verified() {
    mkdir -p "$STATE_DIR"
    touch "$STATE_DIR/verified"
    grep -q "^$1 " "$STATE_DIR/verified" || printf '%s %s %s %s\n' "$1" "$2" "$3" "$(date -Iseconds)" >> "$STATE_DIR/verified"
}

# prune_images <сервис> — на хосте остаются 3 последних образа сервиса
# (не считая тех, что записаны в tags.env любого контура); занятые
# контейнерами docker сам не удалит.
prune_images() {
    local svc="$1" t kept=0 in_use
    in_use="$(cat "$STATE_ROOT"/*/tags.env 2>/dev/null | sed -n "s/^$(tag_var "$svc")=//p")"
    while read -r t; do
        [[ -z "$t" || "$t" == "<none>" ]] && continue
        grep -qxF "$t" <<<"$in_use" && continue
        kept=$((kept + 1))
        (( kept <= 3 )) && continue
        docker rmi "$(image_of "$svc" "$t")" >/dev/null 2>&1 || true
    done < <(docker images "ghcr.io/wallettransactions/$svc" --format '{{.Tag}}')
}

deploy_infra() {
    local git_tag="v$image_tag" checkout="$STATE_DIR/infra" prev="" commit
    local repo="${WALLET_INFRA_REPO:-https://github.com/WalletTransactions/wallet-infra.git}"
    if [[ -d "$checkout/.git" ]]; then
        git -C "$checkout" fetch -q --tags --force origin
        prev="$(git -C "$checkout" describe --tags --exact-match HEAD 2>/dev/null || true)"
    else
        git clone -q --no-checkout "$repo" "$checkout"
    fi
    commit="$(git -C "$checkout" rev-parse --verify -q "$git_tag^{commit}")" \
        || die "в wallet-infra нет тега $git_tag"

    if [[ "$ENV_NAME" == "prod" && $rollback -eq 0 ]]; then
        grep -q "^git:$commit " "$verified_test" 2>/dev/null \
            || die "коммит $git_tag (${commit:0:8}) не проверен в test"
    fi

    echo "==> [$ENV_NAME] wallet-infra ${prev:-(нет)} → $git_tag"
    # git checkout заменяет файлы новыми (unlink + create), а bash дочитывает
    # уже открытый старый файл — выполняющийся скрипт это не ломает.
    git -C "$checkout" checkout -q --detach "$git_tag"
    if bash "$checkout/infra/env/up.sh" "$ENV_NAME" && smoke_gateway; then
        mark_verified "git:$commit" wallet-infra "$git_tag"
        log_history wallet-infra "$git_tag" "git:$commit" ok
        echo "==> [$ENV_NAME] wallet-infra $git_tag выкачен"
        return 0
    fi

    echo "==> [$ENV_NAME] wallet-infra $git_tag не прошёл — возвращаю ${prev:-(нечего)}" >&2
    if [[ -n "$prev" ]]; then
        git -C "$checkout" checkout -q --detach "$prev"
        bash "$checkout/infra/env/up.sh" "$ENV_NAME" \
            || echo "ВНИМАНИЕ: прежний $prev тоже не поднялся — контур требует внимания" >&2
        log_history wallet-infra "$git_tag" "git:$commit" "failed, rolled back to $prev"
    else
        log_history wallet-infra "$git_tag" "git:$commit" failed
    fi
    exit 1
}

if [[ "$service" == "wallet-infra" ]]; then
    deploy_infra
    exit 0
fi

[[ -n "${WALLET_SERVICE_PORT[$service]:-}" ]] || die "неизвестный сервис '$service'"

image="$(image_of "$service" "$image_tag")"
echo "==> [$ENV_NAME] $service → $image_tag"
docker pull -q "$image" >/dev/null || die "не удалось скачать $image"
digest="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image" \
    | grep "^ghcr.io/wallettransactions/$service@" | head -n1)"
digest="${digest#*@}"
[[ -n "$digest" ]] || die "у $image нет digest из registry"
revision="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image" 2>/dev/null || true)"
echo "    digest $digest"

if [[ "$ENV_NAME" == "prod" && $rollback -eq 0 ]]; then
    grep -q "^$digest " "$verified_test" 2>/dev/null \
        || die "digest не проверен в test: $service $image_tag ($digest)"
fi

base=""
for b in "${!WALLET_DB_SERVICE[@]}"; do
    [[ "${WALLET_DB_SERVICE[$b]}" == "$service" ]] && base="$b"
done
if [[ -n "$base" && $rollback -eq 0 ]]; then
    if [[ "$ENV_NAME" == "prod" ]]; then
        bash "$WALLET_INFRA_DIR/infra/env/backup.sh" prod --label "${service}-${image_tag}" "$base" || {
            log_history "$service" "$image_tag" "$digest" "failed: backup"
            die "дамп $base не снят — миграции и выкат не выполняются"
        }
    fi
    bash "$WALLET_INFRA_DIR/infra/env/migrate.sh" "$ENV_NAME" "$base" "$image" || {
        log_history "$service" "$image_tag" "$digest" "failed: migration"
        die "миграция $base упала — $service остаётся на прежнем образе"
    }
fi

prev="$(current_tag "$service")"
set_tag "$service" "$image_tag"
if env_compose up -d --no-deps --wait --wait-timeout 180 "$service" \
        && smoke_gateway && smoke_version "$service" "$version" "$revision"; then
    mark_verified "$digest" "$service" "$image_tag"
    log_history "$service" "$image_tag" "$digest" ok
    prune_images "$service"
    echo "==> [$ENV_NAME] $service $image_tag выкачен"
    exit 0
fi

echo "==> [$ENV_NAME] $service $image_tag не прошёл — возвращаю ${prev:-(нечего)}" >&2
if [[ -n "$prev" ]]; then
    set_tag "$service" "$prev"
    env_compose up -d --no-deps --wait --wait-timeout 180 "$service" \
        || echo "ВНИМАНИЕ: прежний $service $prev тоже не поднялся — контур требует внимания" >&2
    log_history "$service" "$image_tag" "$digest" "failed, rolled back to $prev"
else
    log_history "$service" "$image_tag" "$digest" failed
fi
exit 1
