# tls-ingress Specification

## Purpose
Необязательный TLS на входе контура, чтобы пароли и cookie не ходили по сети
открытым текстом. Без включения профиля стенд работает как раньше, по HTTP.

## Requirements

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
`WALLET_TLS_MODE` SHALL задаваться для каждого контура независимо и принимать
`internal` (по умолчанию), `files` или `tailscale`. При `internal` прокси SHALL
выпускать сертификаты на адреса `WALLET_TLS_HOST` собственным CA, корень
которого хранится в томе контура. Другое значение и невыполненные условия
режима SHALL останавливать запуск контура с понятной ошибкой.

#### Scenario: Собственный CA
- **WHEN** `WALLET_TLS_MODE=internal` и `WALLET_TLS_HOST=192.168.1.105`
- **THEN** `https://192.168.1.105:<WALLET_TLS_PORT>/healthz` отвечает с сертификатом, подписанным CA контура

#### Scenario: Неверный режим
- **WHEN** `WALLET_TLS_MODE=letsencrypt`
- **THEN** запуск контура завершается ошибкой со списком допустимых режимов

### Requirement: Режим files
При `WALLET_TLS_MODE=files` прокси SHALL брать `fullchain.pem` и `privkey.pem`
из `${WALLET_SECRETS_DIR}/tls/`, не выпуская свои, и каждый адрес
`WALLET_TLS_HOST` SHALL входить в этот сертификат.

#### Scenario: Готовый сертификат
- **WHEN** `WALLET_TLS_MODE=files` и в `${WALLET_SECRETS_DIR}/tls/` лежат `fullchain.pem` и `privkey.pem`
- **THEN** прокси отдаёт этот сертификат без выпуска нового

#### Scenario: Нет файлов
- **WHEN** `WALLET_TLS_MODE=files`, а файлов нет
- **THEN** запуск контура завершается ошибкой с указанием ожидаемых путей

#### Scenario: Адреса нет в готовом сертификате
- **WHEN** `WALLET_TLS_MODE=files`, а один из адресов `WALLET_TLS_HOST` не входит в сертификат
- **THEN** запуск контура завершается ошибкой с этим адресом

### Requirement: Режим tailscale
При `WALLET_TLS_MODE=tailscale` прокси SHALL получать и продлевать сертификат
на имя узла `<host>.<tailnet>.ts.net` у `tailscaled` хоста через его сокет, а
остальным адресам `WALLET_TLS_HOST` SHALL выпускать сертификаты собственным CA,
как в `internal`. Сокет `tailscaled` SHALL монтироваться в прокси только в этом
режиме.

#### Scenario: Сертификат Tailscale
- **WHEN** `WALLET_TLS_MODE=tailscale`, `WALLET_TLS_HOST=host.tailnet.ts.net` — имя этого узла, в tailnet включены HTTPS Certificates
- **THEN** `https://host.tailnet.ts.net:<WALLET_TLS_PORT>/healthz` с устройства в tailnet отвечает с сертификатом Let's Encrypt, без установки корня CA

#### Scenario: Смешанный список в режиме tailscale
- **WHEN** `WALLET_TLS_MODE=tailscale` и `WALLET_TLS_HOST=192.168.1.105,host.tailnet.ts.net`
- **THEN** по имени `.ts.net` прокси отдаёт сертификат Tailscale, а по `192.168.1.105` — сертификат, подписанный CA контура

#### Scenario: Чужое имя или нет tailscaled
- **WHEN** `WALLET_TLS_MODE=tailscale`, а в `WALLET_TLS_HOST` нет имени `.ts.net` этого узла или сокета `tailscaled` нет на хосте
- **THEN** запуск контура завершается ошибкой, называющей ожидаемое имя узла или путь к сокету

#### Scenario: Сокет только в режиме tailscale
- **WHEN** контур поднят в режиме `internal` или `files`
- **THEN** в контейнере `tls-proxy` нет сокета `tailscaled`

### Requirement: Список адресов
`WALLET_TLS_HOST` SHALL принимать один адрес или список через запятую (IP и
имена хоста). Прокси SHALL отдавать по каждому имени из списка сертификат на это
имя. Для подключений по IP (без SNI) прокси SHALL отдавать сертификат первого IP
списка. Пустой список при включённом профиле SHALL останавливать запуск с ошибкой.

#### Scenario: Один адрес
- **WHEN** `WALLET_TLS_HOST=192.168.1.105`
- **THEN** поведение такое же, как для одиночного адреса в режиме контура

#### Scenario: IP и имя
- **WHEN** `WALLET_TLS_MODE=internal` и `WALLET_TLS_HOST=192.168.1.105,wallet.lan`
- **THEN** `curl --cacert <корень CA> https://192.168.1.105:<WALLET_TLS_PORT>/healthz` и тот же запрос по `https://wallet.lan:<WALLET_TLS_PORT>/healthz` (имя резолвится у клиента) отвечают `200` без ошибок сертификата

#### Scenario: Адрес не из списка
- **WHEN** клиент обращается к прокси по имени, которого нет в `WALLET_TLS_HOST`
- **THEN** соединение не устанавливается или завершается ошибкой сертификата, запрос до гейтвея не доходит

### Requirement: Корень CA для устройств
Должен быть скрипт, выгружающий публичный корневой сертификат CA контура в
файл для установки на устройства. Закрытый ключ CA SHALL NOT покидать том
контура и SHALL NOT попадать в git и журналы.

#### Scenario: Выгрузка корня
- **WHEN** при `WALLET_TLS_MODE=internal` или `tailscale` выполняется скрипт выгрузки
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
