# Proposal

## Why

Ночной Jenkins-job `docs-index` на test перестал заливать индекс: сборка #10 завершилась `UNSTABLE`, у всех 13 репозиториев «запрос к wallet-docs не выполнен: 000». Причина — на test включён mTLS (`INTERNAL_MTLS=true`, wallet-docs 0.1.5): сервис требует клиентский сертификат, а `docs-index.sh` шлёт `PUT` на `http://127.0.0.1:8089` без него и получает «Empty reply». Параллельно wallet-docs 0.1.6 научился виду `ops` (README по развёртыванию, только для `role: admin`), но скрипт отправляет только `openspec/**/*.md`, поэтому вид остаётся пустым.

## What Changes

- `docs-index.sh` заливает по mTLS, когда он включён в контуре: запрос выполняется внутри контейнера `wallet-docs` по `https://wallet-docs:8089` с сертификатом самого контейнера (`TLS_CERT`, `TLS_KEY`, `TLS_CA`; имя совпадает с SAN). Без mTLS — как раньше, `http://127.0.0.1:8089` (prod).
- В тело заливки, кроме `openspec/**/*.md`, добавляются файлы с именем `README.md` на любой глубине репозитория; `third_party/`, `node_modules/`, `.worktrees/`, `build/`, `vendor/`, `.git/` и симлинки пропускаются. Репозитории без `openspec/` по-прежнему пропускаются целиком.
- Диагностика отказов различает причины: сертификат не читается, TLS-рукопожатие не прошло, сервис недоступен, сервис ответил кодом. Вместо «…: 000» в строке `docs-index: …` — понятная причина.
- Контракт мягкого отказа и статус `UNSTABLE` в Jenkins не меняются.

## Capabilities

### New Capabilities

Нет.

### Modified Capabilities

- `docs-index-upload`: скрипт заливки собирает ещё и `README.md`, работает при включённом mTLS и называет причину отказа.

## Impact

- **wallet-infra**: `infra/env/docs-index.sh`, `infra/env/README.md` (описание сбора файлов и mTLS-пути), спека `docs-index-upload`.
- **Jenkins/BuildPlatform**: job `docs-index` и `env_run.sh` не меняются, но Jenkins берёт скрипты из checkout'а **выкатанного тега wallet-infra**, поэтому после слияния нужен тег wallet-infra и его выкат на test (`deploy.sh test wallet-infra <тег>`), иначе job продолжит запускать старый скрипт.
- **wallet-docs**: без правок (0.1.6 уже принимает `ops`).
- **prod**: mTLS там выключен, путь по `http` сохраняется; wallet-docs на prod пока 0.1.4, поэтому README в ответе придут в `skipped`, пока сервис не будет обновлён.
- **Данные**: после первой заливки на test в индексе появятся чанки `ops`; индекс воспроизводим.
