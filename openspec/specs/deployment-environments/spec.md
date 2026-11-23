# deployment-environments Specification

## Purpose
Определяет постоянные контуры стека WalletTransactions (prod и test), их адреса и изоляцию друг от друга, а также то, какие внешние интеграции подключены к каждому контуру.

## Requirements

### Requirement: Два постоянных контура
Стек SHALL работать ровно в двух постоянных контурах, `prod` и `test`, на хосте под docker. Каждый контур — отдельный compose-проект: `wallet-prod` и `wallet-test`. В каждом контуре полный набор сервисов: db, redis, google-auth, wallet-api, wallet-report, wallet-ai, wallet-gateway, wallet-web, wallet-telegram. Оба контура SHALL описываться одним `compose.yaml`; различия контуров SHALL задаваться только файлами настроек контура и секретами.

#### Scenario: Оба контура подняты
- **WHEN** выполняется `docker compose -p wallet-prod ps` и `docker compose -p wallet-test ps`
- **THEN** в каждом проекте все сервисы стека в состоянии running, а сервисы с healthcheck — healthy

#### Scenario: Запуск без контура невозможен
- **WHEN** в каталоге wallet-infra выполняется `docker compose up -d` без настроек контура
- **THEN** compose завершается ошибкой о незаданной переменной контура и ни одного контейнера не создаёт

### Requirement: Адреса контуров
У каждого контура SHALL быть ровно одна точка входа для клиентов: его wallet-gateway (prod порт 8090, test порт 8091) либо, если включён профиль `tls`, его TLS-прокси (prod порт 8443, test порт 8444), за которым стоит тот же гейтвей. Postgres контура SHALL публиковаться только на `127.0.0.1` этой машины (prod 15555, test 15432) — для DBeaver/psql — и SHALL NOT быть доступен из сети. Остальные сервисы контура, включая Redis, SHALL NOT публиковаться на порты хоста, кроме TLS-прокси при включённом профиле; прямой доступ к ним — только через `docker exec`.

#### Scenario: prod на прежнем адресе
- **WHEN** клиент (браузер, Android) обращается к `http://<хост>:8090/healthz`
- **THEN** отвечает wallet-gateway из `wallet-prod`

#### Scenario: test на своём адресе
- **WHEN** выполняется `curl http://<хост>:8091/version`
- **THEN** отвечает wallet-gateway из `wallet-test`

#### Scenario: Контур с TLS
- **WHEN** в контуре включён профиль `tls` и выполняется `curl https://<хост>:8444/version` (test)
- **THEN** отвечает wallet-gateway из `wallet-test` через TLS-прокси

#### Scenario: БД доступна только с этой машины
- **WHEN** на хосте проверяются слушающие порты
- **THEN** Postgres prod слушает только `127.0.0.1:15555`, Postgres test — только `127.0.0.1:15432`, а порты Redis ни одного из контуров не открыты

#### Scenario: Вход в БД по паролю роли
- **WHEN** с этой машины выполняется подключение к `127.0.0.1:15432` ролью test с неверным паролем
- **THEN** Postgres отклоняет вход

### Requirement: Изоляция данных
У каждого контура SHALL быть свои тома Postgres и Redis и своя сеть docker. Сервисы одного контура SHALL NOT иметь сетевого доступа к хранилищам и сервисам другого контура.

#### Scenario: Запись в test не видна в prod
- **WHEN** через `:8091` создаётся кошелёк
- **THEN** через `:8090` под тем же пользователем этого кошелька нет

#### Scenario: Межконтурный трафик невозможен
- **WHEN** из контейнера `wallet-test` выполняется обращение к db, redis или любому сервису контура `wallet-prod`
- **THEN** имя не резолвится или соединение не устанавливается

### Requirement: Изоляция секретов и токенов
У каждого контура SHALL быть свои пароли ролей Postgres и свой ключ подписи JWT google-auth. Токен, выданный одним контуром, SHALL NOT приниматься другим.

#### Scenario: Токен test не проходит в prod
- **WHEN** access-токен, полученный через `:8091`, отправляется в `GET http://<хост>:8090/api/wallets`
- **THEN** гейтвей prod отвечает 401

### Requirement: Отдельный Telegram-бот для test
В test SHALL работать отдельный Telegram-бот со своим токеном. Токен prod-бота @WalletTransaction_bot SHALL использоваться только в `wallet-prod`. У каждого бота ровно один работающий процесс.

#### Scenario: Два бота не конфликтуют
- **WHEN** оба контура запущены
- **THEN** ни один из ботов не получает от Telegram `409 Conflict` на getUpdates

#### Scenario: Токен prod-бота не попадает в test
- **WHEN** просматриваются переменные окружения контейнера wallet-telegram в `wallet-test`
- **THEN** в них токен test-бота, отличный от токена prod

### Requirement: Google OAuth в обоих контурах
Оба контура SHALL использовать один Google OAuth-клиент. У каждого контура свой redirect URI, указывающий на его собственный гейтвей.

#### Scenario: Вход в test
- **WHEN** пользователь проходит «Sign in with Google» через `:8091`
- **THEN** Google возвращает его на callback гейтвея test, и сессия создаётся в хранилищах test

### Requirement: LLM в контурах
wallet-ai в prod SHALL быть подключён к LM Studio на хосте. В test ИИ SHALL быть по умолчанию выключен: `/api/ai/status` отвечает `enabled=false`. Включается он только явной настройкой контура test.

#### Scenario: ИИ в test выключен по умолчанию
- **WHEN** выполняется `GET http://<хост>:8091/api/ai/status` с валидным токеном test
- **THEN** ответ содержит `enabled=false`

#### Scenario: ИИ в prod работает
- **WHEN** LM Studio на хосте запущен и выполняется `GET http://<хост>:8090/api/ai/status`
- **THEN** ответ содержит `enabled=true`

### Requirement: Приоритет prod при нехватке памяти
При нехватке памяти хоста процессы контура test SHALL завершаться раньше процессов контура prod. У каждого сервиса SHALL быть потолок памяти.

#### Scenario: Приоритет задан
- **WHEN** просматривается `oom_score_adj` процессов контейнеров обоих контуров
- **THEN** у всех процессов prod значение ниже, чем у любого процесса test, а у каждого контейнера задан лимит памяти

### Requirement: Контейнеры из рабочей папки не запускаются
Контуры SHALL NOT запускать образы, собранные на хосте. `compose.yaml` SHALL NOT содержать инструкций сборки.

#### Scenario: Нет сборки в compose
- **WHEN** выполняется `docker compose config` для любого контура
- **THEN** ни у одного сервиса нет секции `build`

### Requirement: Настройки способов входа контура
Контур MAY задавать способы входа переменными `infra/env/<env>.env`:
`WALLET_AUTH_METHODS` (`password`, `google`, `both`), `WALLET_REGISTRATION`
(`open`, `closed`) и `WALLET_ALLOW_INSECURE_AUTH` (`true`, `false`). Заданную
переменную compose SHALL передавать в google-auth как `AUTH_METHODS`,
`REGISTRATION`, `ALLOW_INSECURE_AUTH` поверх `google-auth.env`; незаданная
SHALL NOT менять значение из него. Недопустимое значение SHALL останавливать
запуск.

#### Scenario: Ничего не задано
- **WHEN** в `<env>.env` нет этих переменных, а в `google-auth.env` задано `ALLOW_INSECURE_AUTH=true`
- **THEN** google-auth запускается с `ALLOW_INSECURE_AUTH=true`, как до этого change

#### Scenario: Недопустимое значение
- **WHEN** в `<env>.env` задано `WALLET_AUTH_METHODS=sms`
- **THEN** запуск контура завершается ошибкой со списком допустимых значений

#### Scenario: Пароль включён в test
- **WHEN** в `test.env` заданы `WALLET_AUTH_METHODS=both` и `WALLET_REGISTRATION=open`
- **THEN** `GET /auth/methods` через гейтвей test отвечает `{"methods":["password","google"],"registration":true}`, а prod не меняется

### Requirement: Секреты контура — то, что нельзя восстановить
Пароли, ключи и корни CA контура SHALL храниться в каталоге секретов
`~/.config/wallet-secrets/<env>/` (700, не в git), каждый вид в своём файле или
подкаталоге. Ключи и `*.env` SHALL иметь права 600 (кроме
`jwt_signing_key.pem` — 644: его читает другой uid в контейнере). Создаёт их человек или
скрипт на хосте (`<что>-init.sh`). Существующие файлы SHALL NOT перезаписываться
повторным запуском. Выкат в Jenkins монтирует секреты только на чтение и SHALL
только читать их и проверять права.

#### Scenario: Раскладка секретов
- **WHEN** контур test работает с TLS на входе, mTLS и паролем Redis
- **THEN** в `~/.config/wallet-secrets/test/` лежат `db.env`, `<сервис>.env`, `jwt_signing_key.pem`, `redis/`, `mtls-ca/` (CA между сервисами) и `tls-ca/` (корень CA входа), и ничего из этого нет в git

#### Scenario: Неверные права
- **WHEN** у `tls-ca/root.key` или у `<сервис>.env` права не 600
- **THEN** `up.sh` и выкат останавливаются с ошибкой, называющей файл и нужные права

#### Scenario: Выкат из Jenkins
- **WHEN** выкат идёт в Jenkins, где каталог секретов смонтирован только на чтение, а нужного обязательного файла нет
- **THEN** выкат останавливается с ошибкой и командой `<что>-init.sh <env>`, которую надо выполнить на хосте

### Requirement: Состояние и тома — то, что пересоздаётся
Всё, что скрипты выводят сами, SHALL лежать в состоянии контура
`~/.local/state/wallet-envs/<env>/` (`tags.env`, `infra/`, `verified`, `history`,
`generated/`) или в томах docker `wallet-<env>_*`. Файлы `generated/` SHALL
пересоздаваться при каждом вызове compose через скрипты и SHALL NOT правиться
руками. Ключи и корни CA, которые нельзя восстановить, SHALL NOT храниться
только в состоянии или в томе.

#### Scenario: Удалён generated
- **WHEN** каталог `generated/` контура удалён
- **THEN** следующий `up.sh` или выкат пересоздаёт его, контур работает как раньше

#### Scenario: Удалён том tls-data
- **WHEN** корень CA входа лежит в `tls-ca/`, а том `wallet-<env>_tls-data` удалён
- **THEN** после `up.sh` сертификаты подписаны тем же корнем, устройства переустанавливать корень не должны
