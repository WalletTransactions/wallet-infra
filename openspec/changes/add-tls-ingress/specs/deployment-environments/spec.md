# Spec Delta

## MODIFIED Requirements

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

## ADDED Requirements

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
