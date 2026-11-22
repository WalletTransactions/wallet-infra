# Tasks

## 1. TLS-прокси

- [x] 1.1 Добавить в `compose.yaml` сервис `tls-proxy` (профиль `tls`, образ Caddy 2, `mem_limit: 64m`, том для данных CA, порт `${WALLET_TLS_PORT}:443`, проксирует на `wallet-gateway:8090`) и генерацию Caddyfile в `infra/env/tls.sh` (state-каталог контура, вызов из `env_compose`); проверить в test: `docker compose --profile tls config` собирается, `https://<хост>:8444/healthz` отвечает `200`
- [x] 1.2 Список адресов и режимы `internal`/`files`: `WALLET_TLS_HOST` через запятую, Caddyfile собирается по блоку на источник сертификата (пустые блоки не выводятся), `default_sni` — первый IP; `internal` (CA Caddy, для IP и для имени хоста), `files` (`fullchain.pem`, `privkey.pem` из `${WALLET_SECRETS_DIR}/tls/`, каждый адрес проверяется `openssl x509 -checkhost/-checkip`); ошибки при неверном `WALLET_TLS_MODE`, пустом списке, отсутствии файлов и адресе вне сертификата; проверить `curl --cacert` для одного адреса и для `IP,имя`, сообщения об ошибках, а также выяснить, обслуживается ли второй IP без SNI за docker-NAT (результат — в design, Open Questions)
- [x] 1.3 Режим `tailscale`: сокет `${WALLET_TAILSCALE_SOCKET:-/var/run/tailscale/tailscaled.sock}` монтируется в `tls-proxy` только в этом режиме, блок `.ts.net` с `tls { get_certificate tailscale }`, остальные адреса — `tls internal`; `up.sh` проверяет наличие сокета и что имя `.ts.net` в списке совпадает с `Self.DNSName` из `tailscale status --json`; проверить в test с `WALLET_TLS_HOST=<LAN-IP>,<host>.<tailnet>.ts.net`: по имени — сертификат Let's Encrypt (`curl` без `--cacert`), по IP — CA контура, ошибки при чужом имени и без сокета, в режиме `internal` сокета в контейнере нет (`docker exec … ls`)
- [x] 1.4 Скрипт `infra/env/export-ca.sh`, выгружающий публичный `root.crt` из тома; проверить, что в файле нет закрытого ключа (`openssl x509 -in … -noout`, `grep PRIVATE` пусто)

## 2. Согласованные настройки

- [x] 2.1 `up.sh` выводит из `WALLET_TLS=true` профиль `tls`, `COOKIE_SECURE=true` у google-auth, `TRUST_FORWARDED_HEADERS=true` у гейтвея и привязку порта гейтвея к `127.0.0.1`; без переменной — прежнее поведение; проверить в test оба состояния: в `docker compose config` нужные значения, с другой машины `:8091` закрыт при TLS
- [x] 2.2 Пробросить `WALLET_AUTH_METHODS`, `WALLET_REGISTRATION`, `WALLET_ALLOW_INSECURE_AUTH` в google-auth (`AUTH_METHODS`, `REGISTRATION`, `ALLOW_INSECURE_AUTH`) поверх `google-auth.env` только если заданы (без умолчаний: значения уже живут в секрете, design D5); проверить `docker compose config` без переменных (значения из секрета) и с ними, а на живом test после выката google-auth — `curl <гейтвей>/auth/methods`

## 3. Документация и выкат

- [x] 3.1 Описать профиль, три режима сертификата (с таблицей «какой выбрать»), список адресов, выгрузку CA и настройки входа в `infra/env/README.md` и корневом `README.md` (включая шаг «добавить https `redirect_uri` с TLS-портом в `ALLOWED_REDIRECT_URIS` и Google Cloud Console» для каждого имени, а для входа по LAN-IP — имя `<IP>.nip.io` в `WALLET_TLS_HOST`, установку корня CA на устройства, включение MagicDNS и HTTPS Certificates в tailnet, риск сокета `tailscaled` и альтернативу `tailscale cert` по таймеру + `files` с перезапуском прокси); проверить, что команды из README выполняются как записаны
- [ ] 3.2 Включить TLS в test, пройти из браузера: вход через Google по имени `.ts.net` и по LAN-IP (колбэк на `<IP>.nip.io` без ошибки сертификата), cookie с `Secure`, `curl http://<хост>:8091` с другой машины не отвечает; затем prod по порядку из `design.md`

- [x] 3.3 Проверить `https://` с Android (перенесено из android-wallet `add-password-login`, задача 1.2): на Huawei P20 Pro установить корень CA контура (из `export-ca.sh`) как пользовательский сертификат, указать `https://`-адрес в «Адрес сервера» и выполнить вход и синхронизацию; без установленного корня запрос завершается ошибкой сертификата. Приложение уже доверяет пользовательским CA (`network_security_config`, android-wallet 1.0.165+)

## Результаты проверки на test (2026-11-20, wallet-infra v0.5.0-rc.1)

- `WALLET_TLS_MODE=tailscale`, `WALLET_TLS_HOST=192.168.1.105,192.168.1.105.nip.io,ivan-pc.<tailnet>.ts.net`; 12 сервисов healthy, `tls-proxy` healthy.
- `https://…:8444/healthz` — `200`: по `.ts.net` без корня CA (Let's Encrypt через tailscaled), по IP и nip.io — с корнем CA контура; по IP без корня — ошибка сертификата.
- `:8091` слушает только `127.0.0.1`: с LAN-адреса хоста соединение отклонено, с `127.0.0.1` — `200`.
- `export-ca.sh test` выгрузил `root.crt` (`CN=Caddy Local Authority - 2026 ECC Root`), `grep PRIVATE` пусто.
- В контейнерах `COOKIE_SECURE=true`, `TRUST_FORWARDED_HEADERS=true`; `ALLOW_INSECURE_AUTH=true` из секрета сохранён (`<env>.env` его не задаёт).
- `GET /auth/google` выбирает `redirect_uri` `https://ivan-pc.<tailnet>.ts.net:8444/…` и `https://192.168.1.105.nip.io:8444/…` (по IP), с хоста напрямую — прежний `http://localhost:8091/…`.
- Вход через Google из браузера по `https://ivan-pc.<tailnet>.ts.net:8444` прошёл (URI добавлены в Google Console); у cookie `session` и `refresh_token` в браузере стоят `Secure` и `HttpOnly`.
- Android (3.3, 2026-11-22, Huawei P20 Pro, qa-приложение 1.0.165): `export-ca.sh test` → `root.crt` (`CN=Caddy Local Authority - 2026 ECC Root`) установлен вручную как «Сертификат ЦС» («VPN и приложения»); «Адрес сервера» `https://<LAN-IP>:8444/`; вход по паролю прошёл, «Синхронизировать сейчас» завершилась (скачано справочники, счета и операции, отправлено 2 счёта). Проверка «без корня — ошибка сертификата» на телефоне не гонялась; на хосте `curl` без `--cacert` по IP/nip.io даёт ошибку сертификата (см. выше).
- Остаётся из 3.2 — prod (порт 8443, финальный тег) и вход по `<IP>.nip.io` из браузера.

## Workflow follow-up

- Выкатывается после `trusted-forwarded-headers` (wallet-gateway) и до включения паролей (`add-password-auth`).
- Архивировать change после выкатки и проверки на test-контуре.
