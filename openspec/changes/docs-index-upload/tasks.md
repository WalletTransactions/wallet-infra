# Tasks

## 1. Скрипт

- [x] 1.1 Проверить окружение скрипта: `command -v jq python3 curl` на хосте и в контейнере Jenkins (`docker exec jenkins sh -c …`), наличие `WALLET_TRANSACTIONS_PATH` и списка каталогов с `openspec/`. Проверка: результат записан в заметки к задаче, выбран `jq` или `python3 -I`.
- [x] 1.2 Написать `infra/env/docs-index.sh <prod|test> <репозиторий|all> [--strict]`: поиск `openspec/**/*.md` (`find -type f`, без симлинков), сборка JSON, `docker exec -i` в контейнер `wallet-docs`, итоговая строка на репозиторий, `env_lock`, мягкий отказ с предупреждением `docs-index: <причина>`. Проверка: `bash -n` проходит; на контуре без `wallet-docs` `bash infra/env/docs-index.sh test all` печатает одно предупреждение и завершается 0, `--strict` — ненулевым кодом; `docker ps` и `tags.env` не изменились.
- [x] 1.3 Проверить, что токен не утекает: во время заливки `ps -eo args | grep -c "$INDEX_TOKEN"` (значение не печатать, сравнивать через переменную) равно 0; вывод скрипта и журнал не содержат токена; `set -x` в скрипте нет. Проверка: проверка на test после появления `wallet-docs` (change `docs-service`, задача 5.2).
- [x] 1.4 Обновить `infra/env/README.md` (назначение, использование, мягкий отказ, `--strict`, где `INDEX_TOKEN`). Проверка: команды из README выполняются как написано.

## 2. Jenkins

- [x] 2.1 Сделать резервную копию `BuildPlatform/jobs` (каталог вне git): `cp -a jobs jobs.bak-<дата>` рядом, затем создать `jobs/docs-index/Jenkinsfile`: параметры `ENV` (test/prod, по умолчанию test) и `REPO` (по умолчанию `all`), `env_run.sh "$ENV" docs-index.sh "$REPO"`, ночной триггер для test, `disableConcurrentBuilds`, таймаут 60 минут, `UNSTABLE` при предупреждении `docs-index:` в журнале. Проверка: ручной запуск job'а на test без `wallet-docs` завершается `UNSTABLE` с предупреждением, соседние job'ы (`env-deploy`, `prod-backup`) работают.
- [x] 2.2 Зарегистрировать job в Jenkins (по образцу существующих, как описано в `BuildPlatform/README.md`) и обновить README BuildPlatform. Проверка: job виден в списке, запуск с `ENV=test`, `REPO=wallet-gateway` после включения `wallet-docs` завершается `SUCCESS`, а в журнале строка `wallet-gateway: chunks=…`.

## 3. Проверка на стенде

- [x] 3.1 На test с включённым `wallet-docs` залить `wallet-gateway`, затем `all`. Проверка: итоговые строки для всех репозиториев с `openspec/`, повторный запуск показывает `reused` равным `chunks` и `embedded=0`, `GET /api/docs/status` под токеном админа даёт 200.
- [x] 3.2 Прогнать выкат другого сервиса (`deploy.sh test wallet-gateway <тег>`) одновременно с `docs-index.sh test all`. Проверка: заливка ждёт блокировку и выполняется после выката, оба завершаются успешно.

## Заметки к выкату

- 1.1 (2026-11-13): хост — `jq`, `python3`, `curl` есть; контейнер Jenkins — `jq`, `curl`, `docker` есть, `python3` нет → JSON собирает `jq` (D3). `WALLET_TRANSACTIONS_PATH` в Jenkins = рабочая папка организации, каталоги с `openspec/` видны.
- 1.2: `bash -n` проходит. На test без профиля `docs`: `docs-index.sh test all` — одна строка `docs-index: профиль docs выключен …`, код 0; `--strict` — код 1; `tags.env` (md5) и число контейнеров не изменились. Тот же запуск через `env_run.sh` внутри контейнера Jenkins — то же самое.
- 1.2 (путь заливки): функции `payload`/`upload` из скрипта против опубликованного `ghcr.io/wallettransactions/wallet-docs:0.1.0-rc.1` на одноразовом pgvector — `wallet-gateway` 200, `chunks=161`; `android-wallet` 200, `chunks=802` (столько же, сколько у сборки JSON на Python в `wallet-docs/scripts/it.sh`).
- 1.3 (предварительно): во время этих заливок `ps -eo args` на хосте ни разу не содержал токен (опрос каждые 50 мс), в журнале сервиса токена нет. Повторить на test после 5.2 docs-service.
- 2.1: копия `BuildPlatform/jobs.bak-20261113`, `jobs/docs-index/Jenkinsfile` (ENV/REPO, cron `H 3 * * *`, таймаут 60 мин, без параллельных сборок, `UNSTABLE` по строке `docs-index: `), README BuildPlatform и `jenkins/README.md` обновлены. Запуск job'а в UI — вместе с 2.2.
- 2.2: регистрация Pipeline-джобы в UI Jenkins (админ) — вручную, по `jenkins/README.md`, «Заводим новый job».
- 2.2 (2026-11-13): job `docs-index` заведён через REST API (`createItem`, тот же `config.xml`, что у `env-deploy`: Pipeline script с `evaluate(...)`, sandbox выключен). Первая сборка упала на «script not yet approved» — владелец одобрил скрипт в In-process Script Approval. Вторая упала с `ENV: parameter not set`: параметры из декларативного `Jenkinsfile` Jenkins регистрирует только после первого прогона пайплайна, а запуск был без параметров. Дальше с параметрами: `ENV=test REPO=wallet-gateway` — `SUCCESS` (`chunks=172 embedded=0 reused=172`), `ENV=test REPO=all` — `SUCCESS`, 13 репозиториев. Скрипт берётся из выкатанного checkout'а test (`~/.local/state/wallet-envs/test/infra`, тег `v0.4.1-rc.1`). Ветка `UNSTABLE` при отказе на живом Jenkins не прогонялась (профиль docs выключать не стали); логика проверена на уровне скрипта в 1.2.
- 1.3 на test (2026-11-13, `wallet-docs:0.1.1-rc.1`): две полные заливки `all` подряд, 432 опроса `ps -eo args` каждые 50 мс — токена в аргументах процессов 0 раз, в выводе скрипта 0 вхождений.
- 3.1 на test: `wallet-gateway` — `chunks=172`; `all` — 13 репозиториев с `openspec/`; повторный запуск — `embedded=0`, `reused` равен `chunks` у каждого. `GET /api/docs/status` — `200` по журналу гейтвея (запросы реального пользователя), админ-токеном вручную не проверялось: wallet-test MCP недоступен (токен просрочен).
- 3.2 на test: `deploy.sh test wallet-gateway 0.1.5-rc.1` и `docs-index.sh test wallet-gateway` одновременно — заливка вывела «контур test занят другой операцией, жду…», выполнилась после выката, оба с кодом 0.
- **Найдено при 3.1: OOM-kill `wallet-docs` на `mem_limit: 128m`.** Из шести заливок `wallet-web` примерно одна обрывалась пустой ошибкой «запрос к wallet-docs не выполнен:», `RestartCount` вырос до 4, в `journalctl -k` — `Memory cgroup out of memory … wallet_docs anon-rss:126304kB`. Лимит поднят до 384m в `compose.yaml`; на живом test проверено через `docker update --memory 384m`: 8 заливок `wallet-web` подряд без перезапусков. Лимит в compose вступит в силу на test после тега wallet-infra (`up.sh` берёт compose из выкатанного checkout'а); до этого `docker update` сбросится при пересоздании контейнера.
- Побочное: при обрыве соединения сообщение «запрос к wallet-docs не выполнен: » приходит пустым — код возврата `docker exec` и причина не печатаются. Для диагностики стоило бы добавить код выхода.

## Workflow follow-up

- Включать ночной запуск для prod только после проверки качества ответов на test (change `docs-service`, задача 6.3).
- Архивировать change после выката и проверки на test.
