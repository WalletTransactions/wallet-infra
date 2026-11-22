## Why

Вход по паролю (google-auth, change `add-password-auth`) пересылает пароль
пользователя через сеть. В стеке нет TLS: браузер и Android ходят на гейтвей по
`http://…:8090`, cookie выставляются без `Secure`. Для паролей нужен
необязательный TLS на входе контура. Стенд остаётся рабочим и без него: владелец
может сознательно остаться на HTTP, но тогда пароль принимается только с явным
`ALLOW_INSECURE_AUTH=true`.

## What Changes

- Необязательный compose-профиль `tls`: прокси Caddy перед гейтвеем контура,
  публикует HTTPS-порт (`WALLET_TLS_PORT`: prod 8443, test 8444).
- Три режима сертификата (`WALLET_TLS_MODE`), выбираемые для каждого контура:
  `internal` — собственный CA Caddy (по умолчанию), `files` — готовые сертификат
  и ключ из каталога секретов контура (например, от Let's Encrypt для домена),
  `tailscale` — публично доверенный сертификат на имя узла `*.ts.net` от
  `tailscaled` хоста (без своего домена и без установки CA на устройства).
- `WALLET_TLS_HOST` — список адресов через запятую (IP и имена), сертификат
  выпускается на каждый. В режиме `tailscale` список смешанный: имя `.ts.net`
  получает сертификат Tailscale, остальные адреса (LAN-IP) — от CA Caddy.
- Скрипт выгрузки корневого сертификата CA для установки на устройства.
- При включённом профиле `tls` compose сам включает `COOKIE_SECURE=true` у
  google-auth и `TRUST_FORWARDED_HEADERS=true` у гейтвея, а порт гейтвея
  публикует только на `127.0.0.1`; без профиля всё как раньше.
- Настройки способов входа контура (`AUTH_METHODS`, `REGISTRATION`,
  `ALLOW_INSECURE_AUTH`) задаются в `infra/env/<env>.env` и пробрасываются в
  google-auth.

## Capabilities

### New Capabilities
- `tls-ingress`: необязательный TLS на входе контура: профиль, порты, режимы
  сертификата (`internal`, `files`, `tailscale`), список адресов, выгрузка корня
  CA, согласованные настройки cookie и доверия к `X-Forwarded-*`.

### Modified Capabilities
- `deployment-environments`: «Адреса контуров» допускает TLS-прокси как
  опубликованный сервис; добавляется требование о настройках способов входа.

## Impact

- **wallet-infra**: `compose.yaml` (сервис `tls-proxy`, переменные google-auth и
  гейтвея), `infra/tls/` (Caddyfile, скрипт выгрузки CA), `infra/env/*.env`,
  `infra/env/README.md`, корневой `README.md`.
- **wallet-gateway** (`trusted-forwarded-headers`): должен быть выкачен раньше.
- **google-auth** (`add-password-auth`): переменные `AUTH_METHODS`, `REGISTRATION`,
  `ALLOW_INSECURE_AUTH`, `COOKIE_SECURE`.
- **android-wallet** (`add-password-login`): доверие к пользовательскому CA.
- **Google Cloud Console и `ALLOWED_REDIRECT_URIS` google-auth**: для входа
  через Google за TLS нужно вручную добавить https-варианты `redirect_uri` с
  TLS-портом для каждого имени из `WALLET_TLS_HOST` (URI сверяется буквально:
  `http://…:8091` → `https://…:8444`). Вход по LAN-IP google-auth переписывает в
  `<IP>.nip.io`, поэтому это имя тоже нужно в `WALLET_TLS_HOST`.
- **Хост** (только режим `tailscale`): в tailnet включены MagicDNS и HTTPS
  Certificates, в контейнер прокси монтируется сокет `tailscaled`.
- **RAM/диск**: Caddy ~20–40 МБ на контур (лимит 64 МБ), образ ~40 МБ; GPU не затрагивается.
- k8s (`infra/k8s`) не затрагивается.
