# Spec Delta

## Purpose

Описывает, как Postgres контура готов к векторному поиску для сервиса `wallet-docs`: расширение `vector`, отдельная база и роль только с DML. Всё это включается секретами контура и не влияет на остальные базы.

## ADDED Requirements

### Requirement: Postgres контура поддерживает расширение vector
Инстанс Postgres каждого контура (prod, test) SHALL быть версии 16 и содержать расширение `vector` в составе образа. Остальные базы, роли и расширения (`pg_stat_statements`) SHALL работать как до этого change.

#### Scenario: Расширение доступно
- **WHEN** в запущенном контуре выполняется `SELECT 1 FROM pg_available_extensions WHERE name = 'vector'`
- **THEN** запрос возвращает строку

#### Scenario: Прежние базы целы
- **WHEN** после смены образа контур поднят через `infra/env/up.sh <env>` и миграции накатаны
- **THEN** сервисы `google-auth`, `wallet-api`, `wallet-ai` и `wallet-telegram` здоровы, а в `pg_stat_statements` по-прежнему копится статистика

### Requirement: База wallet-docs создаётся только по секретам контура
База, роль и расширение для `wallet-docs` SHALL создаваться `infra/db/init-db.sh`, только если в `db.env` контура заданы `DOCS_POSTGRES_USER`, `DOCS_POSTGRES_PASSWORD` и `DOCS_POSTGRES_DB`. Если они не заданы, скрипт SHALL завершаться успешно без базы docs.

#### Scenario: Секреты заданы
- **WHEN** `init-db.sh` выполняется при заданных `DOCS_POSTGRES_*`
- **THEN** в кластере есть база `DOCS_POSTGRES_DB` с расширением `vector`, а ролью `DOCS_POSTGRES_USER` можно подключиться только к ней

#### Scenario: Секретов нет
- **WHEN** `init-db.sh` выполняется без `DOCS_POSTGRES_*`
- **THEN** скрипт завершается с кодом 0, а базы и роли docs в кластере нет

#### Scenario: Повторный запуск
- **WHEN** `init-db.sh` запускается повторно на контуре, где база docs уже есть
- **THEN** скрипт завершается с кодом 0 и ничего не меняет

### Requirement: Роль wallet-docs имеет только DML на свою базу
Роль `DOCS_POSTGRES_USER` SHALL иметь `CONNECT` только на базу `DOCS_POSTGRES_DB` и только DML (`SELECT`, `INSERT`, `UPDATE`, `DELETE`) на таблицы, которые создаст мигратор. DDL, `TRUNCATE` и доступ к остальным базам SHALL быть запрещены.

#### Scenario: Чужая база недоступна
- **WHEN** под ролью `DOCS_POSTGRES_USER` выполняется подключение к базе кошелька
- **THEN** Postgres отклоняет подключение

#### Scenario: DDL запрещён
- **WHEN** под этой ролью выполняется `CREATE TABLE` или `TRUNCATE` в базе docs
- **THEN** Postgres отвечает отказом в правах

### Requirement: Индекс документации не входит в дампы
Скрипты `backup.sh` и `test-refresh.sh` SHALL по умолчанию работать только с четырьмя прежними базами (auth, wallet, telegram, ai). База docs SHALL NOT попадать в дампы, потому что индекс пересобирается из репозиториев.

#### Scenario: Бэкап prod
- **WHEN** выполняется `infra/env/backup.sh prod` без явного списка баз
- **THEN** появляются дампы только четырёх прежних баз, а роль `dumper` не получает `CONNECT` на базу docs
