## 1. Конфигурация контура

- [x] 1.1 `compose.yaml`: `AI_STREAM_ENABLED: ${AI_STREAM_ENABLED-false}` у wallet-ai
- [x] 1.2 `infra/env/test.env`: `AI_STREAM_ENABLED=true`; `infra/env/prod.env`: закомментированная строка
- [x] 1.3 `infra/env/README.md`: где задаётся переменная и почему не в `wallet-ai.env`

## 2. Выкат на test

- [x] 2.1 Тег v0.4.1-rc.3 (rc.2 упал: незакоммиченные правки docs в выкатанной копии, см. test.env, PR #37); в контейнере wallet-ai `AI_STREAM_ENABLED=true`
- [x] 2.2 Убрать `AI_STREAM_ENABLED=true` из `~/.config/wallet-secrets/test/wallet-ai.env` (перекрывается compose); поток на test по-прежнему работает
