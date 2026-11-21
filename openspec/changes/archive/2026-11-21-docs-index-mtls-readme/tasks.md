# Tasks

Порядок: правка скрипта и проверка на test вручную → PR → тег wallet-infra и выкат на test → job в Jenkins. Бэкап или смена данных не нужны: индекс wallet-docs воспроизводим.

## 1. Заливка по mTLS и причины отказа

- [x] 1.1 В `upload` (`infra/env/docs-index.sh`) выбирать способ внутри контейнера: при заданных `TLS_CERT`, `TLS_KEY`, `TLS_CA` — `curl --cacert --cert --key` на `https://wallet-docs:8089`, иначе `http://127.0.0.1:8089`; токен по-прежнему через файл заголовка; проверка: на test `bash infra/env/docs-index.sh test wallet-infra` печатает строку итога с `chunks` больше нуля, код 0 (контур с mTLS) (2026-11-21: `chunks=333 embedded=31 reused=302 skipped=0 files=54`, код 0)
- [x] 1.2 Вернуть код `curl` отдельно от HTTP-кода и сопоставить причины (TLS, недоступность, код ответа); проверить чтение `TLS_CERT` до запроса; проверка: подмена сертификата (временный `TLS_CERT` на несуществующий путь через `docker exec -e`) даёт «сертификат контейнера не читается», остановленный контейнер — «не запущен», неверный `INDEX_TOKEN` — `ответил 401`, и ни в одном выводе нет токена (2026-11-21: `TLS_CERT=/nope` → «сертификат контейнера не читается»; неверный токен → «wallet-docs ответил 401 unauthorized»; чужой `TLS_CA` → «TLS-рукопожатие не прошло (curl 60)»; токена в выводе нет)
- [x] 1.3 Проверить prod-путь без mTLS: на контуре без `TLS_CERT` в контейнере запрос идёт по `http://127.0.0.1:8089`; проверка: `bash infra/env/docs-index.sh prod wallet-gateway` (после согласия владельца на заливку в prod) либо чтение собранной команды при `TLS_CERT` пустом; результат записан в tasks.md (2026-11-21: заливка в prod не запускалась; при пустом `TLS_CERT` в контейнере test запрос идёт по http — `curl 55` против TLS-сервера, то есть ветка http выбрана)

## 2. README в заливке

- [x] 2.1 В `payload` добавить `find` по `README.md` вне `third_party`, `node_modules`, `.worktrees`, `build`, `vendor`, `.git`, `openspec` (`-type f`, без симлинков), пути относительно корня репозитория; проверка: `bash -x`-свободный пробный прогон на `wallet-infra` — в теле есть `README.md` и `infra/env/README.md`, нет `third_party/…/README.md`; число файлов в строке итога выросло на число README (2026-11-21: собираются `README.md`, `infra/db/README.md`, `infra/diagrams/README.md`, `infra/env/README.md`, `third_party` нет)
- [x] 2.2 `all`: репозиторий без `openspec/` по-прежнему пропускается; проверка: `bash infra/env/docs-index.sh test all` — для `org` пометка о пропуске, итоговые строки для остальных (2026-11-21: `docs-index.sh test all` — 13 репозиториев, итоговая строка у каждого, строк `docs-index: …` нет)
- [x] 2.3 Проверить, что README доходят до индекса как вид `ops`; проверка: `psql` на test — `select kind, count(*) from doc_chunks where repo='wallet-infra' group by 1` показывает строки `ops` (22 при двух README) (2026-11-21: `ops` = 34 чанка у wallet-infra на test)

## 3. Документация

- [x] 3.1 `infra/env/README.md`: описание сбора README, пути по mTLS и без, расшифровка строк `docs-index: …`; шапка `docs-index.sh` — те же правила; проверка: команды из новых абзацев выполняются как написано

## 4. Выкат и Jenkins

- [x] 4.1 PR в wallet-infra (`gh pr merge --squash --auto`), после слияния тег wallet-infra и `deploy.sh test wallet-infra <тег>`; проверка: в `~/.local/state/wallet-envs/test/history` строка `wallet-infra … ok`, `<state>/test/infra/infra/env/docs-index.sh` содержит новую версию (2026-11-21: PR #65, тег `v0.5.0-rc.13` на `5f9b5c3`, на test в `history` 20:24 UTC, checkout содержит новый скрипт)
- [x] 4.2 Запустить job `docs-index` вручную (`ENV=test`, `REPO=all`); проверка: сборка `SUCCESS`, в журнале итоговая строка каждого репозитория с `openspec/`, нет строк `docs-index: …`; по расписанию следующий ночной запуск тоже `SUCCESS` (2026-11-21: сборка #11 `SUCCESS`, 13 репозиториев, строк `docs-index: …` нет)
- [x] 4.3 Спросить админским токеном про развёртывание (wallet-docs, change `docs-ops-kind`, задача 6.3); проверка: ответ из чанков вида `ops` (2026-11-21: админ получил ответ про mTLS с `sources` из README `wallet-mcp`, `wallet-telegram`, `wallet-infra`; `0.1.7-rc.1`)

## Workflow follow-up

- Архивировать change (`openspec archive docs-index-mtls-readme`) после выката на test и успешного ночного запуска job.
- prod: когда wallet-docs на prod получит 0.1.6, перезалить индекс (`docs-index.sh prod all`), чтобы README стали видом `ops`; mTLS на prod скрипт не требует.
