# Design

## Context

Зачем — в `proposal.md`. Исходное состояние:
- На хост публикуется только гейтвей контура (`${WALLET_GATEWAY_PORT}:8090`) по HTTP;
  настройки google-auth (`COOKIE_SECURE`, `REDIRECT_URL`, `ADMIN_EMAILS`)
  лежат в `${WALLET_SECRETS_DIR}/google-auth.env` вне git.
- Различия контуров — только `infra/env/<env>.env` и секреты (см.
  `deployment-environments`); необязательные модули включаются профилем compose
  (так сделан wallet-docs: `COMPOSE_PROFILES=docs` вместе с `WALLET_DOCS_URL`).
- Образы собирает CI, выкат — Jenkins через `infra/env/up.sh`/`deploy.sh`; голый
  `docker compose` в каталоге намеренно падает.
- Хост один (12 ядер, 14 ГБ), контуров два.

## Goals / Non-Goals

**Goals:**
- Дать включаемый TLS на входе контура, не ломая стенд без него.
- Сделать связанные настройки (`COOKIE_SECURE`, доверие к `X-Forwarded-*`, порт гейтвея)
  невозможными в рассогласованном виде.

**Non-Goals:**
- TLS между сервисами внутри контура (план — `org/docs/TODO_service_auth_tls.md`).
- k8s-вариант (`infra/k8s`), Ingress.
- Автоматический выпуск публичных сертификатов (DNS-01, плагины Caddy): нужен
  собственный образ; вместо этого режим `files` принимает сертификат из любого ACME-клиента.
  Исключение — режим `tailscale`: источник Tailscale встроен в стандартный образ Caddy.
- Публичный доступ через Tailscale Funnel.
- Правки BuildPlatform: профиль включается переменной в env-файле контура, `up.sh`
  её уже читает.

## Decisions

### D1. Caddy, отдельный контейнер на контур, профиль `tls`

Caddy выдаёт сертификаты и умеет собственный CA (`tls internal`) без правок C++
и без openssl-скриптов. Альтернативы: nginx (нет встроенного CA, сертификаты
вручную), TLS в самом гейтвее (правка C++ и поддержка CA в cpp-httplib,
`CPPHTTPLIB_OPENSSL_SUPPORT` пересобирает все образы). Профиль повторяет приём
wallet-docs: необязательный модуль не ломает контур, где он не нужен.

### D2. Три режима сертификата, выбор — на контур

| Режим | Откуда сертификат | Что нужно клиентам |
|---|---|---|
| `internal` (по умолчанию) | CA Caddy в томе контура, на любой адрес (IP, имя) | установить корень CA |
| `files` | `${WALLET_SECRETS_DIR}/tls/{fullchain,privkey}.pem` от любого ACME-клиента или своего CA | ничего (при публичном CA) |
| `tailscale` | `tailscaled` хоста: Let's Encrypt на имя узла `<host>.<tailnet>.ts.net` | быть в tailnet |

`internal` работает в LAN без домена. `files` — для тех, у кого есть домен.
`tailscale` — для тех, у кого домена нет, но есть tailnet: имя `.ts.net` даёт
и публичное доверие, и годный для Google `redirect_uri` (D7). Режимы контуров
независимы: test может быть на `internal`, prod — на `tailscale`.

### D7. Режим `tailscale`: Caddy берёт сертификат у `tailscaled` через сокет

В Caddy есть встроенный источник сертификатов Tailscale (`tls { get_certificate
tailscale }`): он запрашивает сертификат у локального `tailscaled` по LocalAPI
и сам его продлевает. Для этого в контейнер `tls-proxy` монтируется сокет
`${WALLET_TAILSCALE_SOCKET:-/var/run/tailscale/tailscaled.sock}` — только в
этом режиме. Caddy в контейнере работает от root, `tailscaled` такие запросы
принимает.

`up.sh` до запуска проверяет: сокет существует; среди `WALLET_TLS_HOST` есть
ровно одно имя `.ts.net`, и оно совпадает с именем узла
(`tailscale status --json` → `Self.DNSName`), — иначе понятная ошибка:
`tailscaled` выдаёт сертификат только на имя своего узла.

*Альтернатива:* `tailscale cert` на хосте по таймеру + режим `files`. Сокет в
контейнер не попадает (см. риски), но нужны systemd-таймер вне compose и
перезапуск прокси после продления (Caddy не перечитывает файлы). Остаётся
доступной без отдельного режима: это обычный `files`.
*Альтернатива:* `tailscale serve` на хосте вместо Caddy. Отвергнуто: настройка
хоста вне compose, не управляется `up.sh`/Jenkins и не подчиняется D3.

### D8. `WALLET_TLS_HOST` — список адресов

Клиенты ходят на один контур по разным адресам: дома по LAN-IP, снаружи через
Tailscale. Сертификат проверяется по адресу из URL, поэтому он нужен на каждый.
`WALLET_TLS_HOST` — список через запятую (`192.168.1.105,host.tailnet.ts.net`);
каждый адрес — адрес сайта в Caddyfile. Один адрес — частный случай, прежние
значения остаются рабочими.

### D9. Смешанный источник сертификатов в режиме `tailscale`

В режиме `tailscale` имя `.ts.net` получает сертификат Tailscale, а остальные
адреса списка — от CA Caddy (как в `internal`). Так телефону в tailnet не нужен
корень CA, а LAN-клиенты без Tailscale продолжают работать по IP с установленным
корнем. В `internal` и `files` источник один на все адреса; в `files` каждый адрес
обязан быть в SAN сертификата (`up.sh` проверяет `openssl x509 -checkhost/-checkip`).

Caddyfile генерирует `infra/env/tls.sh` в state-каталог контура
(`generated/caddy/Caddyfile`, каталог смонтирован в прокси): по блоку на источник
сертификата, пустой блок не выводится. Генерация, а не подстановка `{$…}`:
пустой список адресов в блоке Caddy не принимает. Вывод идёт в `env_compose`
на **каждый** вызов compose, а не только в `up.sh`: иначе `deploy.sh
wallet-gateway` пересоздал бы гейтвей с портом на всех интерфейсах. Так же
пишутся `generated/google-auth.env` (`COOKIE_SECURE`) и
`generated/wallet-gateway.env` (`TRUST_FORWARDED_HEADERS`): второй `env_file`
сервиса перекрывает секрет. Метка `wallet.tls-config` у прокси — хеш Caddyfile
(и сертификата в `files`): Caddy файлы не перечитывает, а смена метки
заставляет compose пересоздать контейнер.

Подключения по IP приходят без SNI (RFC 6066 запрещает IP-литералы в SNI), а за
docker-NAT Caddy видит локальный адрес контейнера, а не хоста. Поэтому для IP
прокси использует `default_sni` = первый IP из списка; второй и следующие IP
не гарантированы (см. Open Questions).

### D3. Один переключатель — профиль, остальное выводится из него

Compose выставляет `COOKIE_SECURE`, `TRUST_FORWARDED_HEADERS` и привязку порта
гейтвея из того, включён ли профиль (одна переменная `WALLET_TLS`, из которой
`up.sh` выставляет `COMPOSE_PROFILES=tls` и производные), а не из трёх независимых
настроек. Иначе легко получить `TRUST_FORWARDED_HEADERS=true` при открытом `:8090`
(подделка заголовков, см. change гейтвея) или `COOKIE_SECURE=true` без TLS (браузер не
вернёт cookie, вход «ломается без причины»).

*Альтернатива:* три отдельные переменные в env-файле. Отвергнуто по причине выше.

### D4. Гейтвей при TLS — только на 127.0.0.1

Скрипты выката и проверки (`curl` с хоста, healthcheck) продолжают ходить на
`127.0.0.1:<порт гейтвея>`. С других машин порт закрыт, и обойти прокси нельзя.

### D5. Настройки способов входа — в `<env>.env`, а не в секретах

`AUTH_METHODS`, `REGISTRATION`, `ALLOW_INSECURE_AUTH` не секретны, и контуры
должны различаться (пароль сначала в test). К моменту реализации они уже жили
в `google-auth.env` (wallet-infra #40, на обоих контурах `ALLOW_INSECURE_AUTH=true`),
поэтому `<env>.env` их только **перекрывает**: заданная переменная попадает в
`generated/google-auth.env`, который подключается после секрета, а незаданная
не меняет ничего. Умолчания в compose сломали бы вход по паролю по HTTP (403).

### D6. Корень CA — скриптом из тома

`infra/env/export-ca.sh` (рядом с остальными скриптами контура, общий `lib.sh`)
копирует `root.crt` из тома Caddy, закрытый ключ не трогает. Устройства (браузеры, Android) ставят корень вручную (для Android —
как пользовательский CA, см. `add-password-login`).

## Risks / Trade-offs

- **Устройства не доверяют CA** (режим `internal`) → выгрузка корня, инструкция в
  README; режим `files` с публичным сертификатом обходит проблему.
- **Рассинхрон настроек** → D3, одна переменная.
- **IP-адрес в сертификате** меняется при смене DHCP-адреса хоста → задать
  `WALLET_TLS_HOST` именем хоста (например, `.ts.net`), а при IP — зарезервировать
  адрес на роутере.
- **Сокет `tailscaled` в контейнере** (режим `tailscale`) даёт процессу Caddy от
  root полный LocalAPI: при компрометации прокси можно менять настройки
  tailscale хоста → сокет монтируется только в этом режиме, образ Caddy
  официальный и закреплён по версии, порт прокси — единственный открытый;
  кому это неприемлемо — `tailscale cert` по таймеру + `files` (D7).
- **Имя `.ts.net` попадает в публичные логи Certificate Transparency** (имя
  tailnet раскрывается) → принять; при неприемлемости — `internal`.
- **Режим `tailscale` недоступен с устройств вне tailnet** → смешанный список
  (D9): LAN-IP через CA Caddy; публичный доступ (Funnel) — вне этого change.
- **Несколько IP в списке**: без SNI корректный сертификат гарантирован только
  первому IP (D9) → в README рекомендовать один IP плюс имена.
- **Google и IP**: `redirect_uri` на IP Google не принимает, поэтому google-auth
  (`resolve_redirect_uri`) переписывает Host `192.168.*` в `<IP>.nip.io`, и после
  Google браузер возвращается уже по этому имени → в режимах `internal` и
  `tailscale` добавить `<IP>.nip.io` в `WALLET_TLS_HOST` (CA Caddy выпустит на него
  сертификат), иначе колбэк упадёт с ошибкой сертификата.
- **Google `redirect_uri`** сверяется буквально, а с TLS меняются схема и порт
  (`http://ivan-pc.<tailnet>.ts.net:8091/…` → `https://…:8444/…`) → https-варианты
  для каждого имени добавить и в `ALLOWED_REDIRECT_URIS`
  (`${WALLET_SECRETS_DIR}/google-auth.env`), и в Google Cloud Console; http-варианты
  оставить для отката. Это шаг миграции; пока не добавлен, вход через Google
  по TLS падает, а вход по паролю работает.
- **RAM:** +2 процесса Caddy (до 64 МБ по лимиту, ~20–40 МБ фактически); диск
  ~40 МБ образ; GPU и Postgres не затрагиваются.
- **Один контур с TLS, другой нет** допустим — настройки по контурам независимы.

## Migration Plan

1. Выкатить `trusted-forwarded-headers` (wallet-gateway) в оба контура.
2. test: включить `WALLET_TLS=true` (`WALLET_TLS_HOST` = адрес хоста), поднять,
   проверить `https://<хост>:8444/healthz`, вход через Google (после добавления
   https `redirect_uri` в Google Cloud Console), выгрузить корень CA.
   Для режима `tailscale`: в админке tailnet включить MagicDNS и HTTPS
   Certificates, `WALLET_TLS_MODE=tailscale`,
   `WALLET_TLS_HOST=<LAN-IP>,<LAN-IP>.nip.io,<host>.<tailnet>.ts.net`, в
   `ALLOWED_REDIRECT_URIS` и Google Console добавить
   `https://<LAN-IP>.nip.io:8444/auth/google/callback` и
   `https://<host>.<tailnet>.ts.net:8444/auth/google/callback`, проверить вход
   через Google по IP и по имени `.ts.net`.
3. Выкатить `add-password-auth` с `WALLET_AUTH_METHODS=both` в test.
4. После проверки повторить для prod (порт 8443).

Откат: убрать `WALLET_TLS` из `<env>.env` и пересоздать контур — порт гейтвея
снова публикуется на всех интерфейсах, `COOKIE_SECURE`/доверие выключаются.

Правки вне wallet-infra: wallet-gateway (`TRUST_FORWARDED_HEADERS`), google-auth
(`AUTH_METHODS` и др., `X-Forwarded-Proto` для `redirect_uri`), android-wallet
(доверие к пользовательскому CA, `usesCleartextTraffic`), Google Cloud Console.

## Open Questions

- Выпускать ли Caddy сертификат для IP в `internal` или требовать имя хоста —
  зависит от версии Caddy и проверяется в задаче 1.2; на спеки не влияет.
- ~~Несколько IP без SNI за docker-NAT~~ — проверено (Caddy 2.10.2): второй IP
  получает сертификат первого (`default_sni`), проверка падает. Ограничение
  остаётся; обход (`network_mode: host`, порт на IP) не нужен — второй адрес
  задаётся именем (`<IP>.nip.io`, `.ts.net`).
