# Spec Delta

## Purpose

Необязательный TLS на входе контура, чтобы пароли и cookie не ходили по сети
открытым текстом. Без включения профиля стенд работает как раньше, по HTTP.

## ADDED Requirements

### Requirement: TLS необязателен
TLS-прокси SHALL входить в compose-профиль `tls` и подниматься только когда
профиль включён (`COMPOSE_PROFILES=tls` в `infra/env/<env>.env`). Без профиля
стек SHALL работать так же, как до этого change: гейтвей публикуется на
`WALLET_GATEWAY_PORT` по HTTP, `COOKIE_SECURE` и доверие к `X-Forwarded-*` выключены.

#### Scenario: Профиль не включён
- **WHEN** контур поднят без профиля `tls`
- **THEN** контейнера `tls-proxy` нет, а гейтвей отвечает по `http://<хост>:<WALLET_GATEWAY_PORT>/healthz`

#### Scenario: Профиль включён
- **WHEN** контур поднят с профилем `tls`
- **THEN** поднимается `tls-proxy`, и `https://<хост>:<WALLET_TLS_PORT>/healthz` отвечает `200`

### Requirement: Точка входа с TLS
При включённом профиле `tls` клиентской точкой входа SHALL быть `tls-proxy` на
порту `WALLET_TLS_PORT` контура (prod `8443`, test `8444`), передающий все
запросы гейтвею того же контура. Порт гейтвея SHALL публиковаться только на
`127.0.0.1`, чтобы клиент не мог обойти прокси.

#### Scenario: Обход прокси
- **WHEN** при включённом профиле клиент с другой машины открывает `http://<хост>:<WALLET_GATEWAY_PORT>/healthz`
- **THEN** соединение не устанавливается

#### Scenario: Проверка с самого хоста
- **WHEN** на хосте выполняется `curl http://127.0.0.1:<WALLET_GATEWAY_PORT>/healthz`
- **THEN** ответ `200`, как и для скриптов выката

### Requirement: Режимы сертификата
`WALLET_TLS_MODE` SHALL принимать `internal` (по умолчанию) или `files`. При
`internal` прокси SHALL выпускать сертификат для `WALLET_TLS_HOST` (IP или имя
хоста) собственным CA, корень которого хранится в томе контура. При `files`
прокси SHALL брать сертификат и ключ из `${WALLET_SECRETS_DIR}/tls/`
(`fullchain.pem`, `privkey.pem`), не выпуская свои. Другое значение SHALL
останавливать запуск контура с понятной ошибкой.

#### Scenario: Собственный CA
- **WHEN** `WALLET_TLS_MODE=internal` и `WALLET_TLS_HOST=192.168.1.105`
- **THEN** `https://192.168.1.105:<WALLET_TLS_PORT>/healthz` отвечает с сертификатом, подписанным CA контура

#### Scenario: Готовый сертификат
- **WHEN** `WALLET_TLS_MODE=files` и в `${WALLET_SECRETS_DIR}/tls/` лежат `fullchain.pem` и `privkey.pem`
- **THEN** прокси отдаёт этот сертификат без выпуска нового

#### Scenario: Нет файлов
- **WHEN** `WALLET_TLS_MODE=files`, а файлов нет
- **THEN** запуск контура завершается ошибкой с указанием ожидаемых путей

### Requirement: Корень CA для устройств
Должен быть скрипт, выгружающий публичный корневой сертификат CA контура в
файл для установки на устройства. Закрытый ключ CA SHALL NOT покидать том
контура и SHALL NOT попадать в git и журналы.

#### Scenario: Выгрузка корня
- **WHEN** при `WALLET_TLS_MODE=internal` выполняется скрипт выгрузки
- **THEN** создаётся файл с публичным сертификатом, ключа в нём нет

### Requirement: Согласованные настройки профиля
Профиль `tls` SHALL включать вместе: `COOKIE_SECURE=true` у google-auth и
`TRUST_FORWARDED_HEADERS=true` у гейтвея. Без профиля оба SHALL быть выключены.
Раздельно включить их из `infra/env/<env>.env` SHALL быть нельзя.

#### Scenario: Cookie за TLS
- **WHEN** профиль `tls` включён и пользователь входит через `https://…:<WALLET_TLS_PORT>`
- **THEN** cookie `session` и `refresh_token` приходят с атрибутом `Secure`

#### Scenario: Без профиля
- **WHEN** профиль не включён
- **THEN** у google-auth `COOKIE_SECURE=false`, у гейтвея `TRUST_FORWARDED_HEADERS=false`
