# Tasks

## 1. Порты

- [x] 1.1 `127.0.0.1:19200:9200` и `127.0.0.1:15601:5601` в `infra/logging/compose.yaml`; проверить `docker compose -f infra/logging/compose.yaml config`
- [ ] 1.2 Перезапустить стек логов; `curl http://<LAN-IP>:19200` — отказ соединения, `curl http://127.0.0.1:19200` — ответ; в Dashboards видны свежие логи обоих контуров

## 2. Спеки

- [x] 2.1 `openspec validate logging-localhost-only --strict`
- [ ] 2.2 Архивировать change после проверки
