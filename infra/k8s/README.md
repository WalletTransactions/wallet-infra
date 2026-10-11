# k8s

Манифесты для локального кластера (minikube / kind / Rancher Desktop) —
прямой аналог `compose.yaml`, тот же набор из 7 "сервисов" (db, redis,
google-auth, wallet-api, wallet-report, wallet-gateway, wallet-web), та же
логика с тремя Postgres-ролями (см. `infra/db/README.md`, "Три роли") и тем же
порядком запуска (db → миграции → остальное, см. `infra/db/README.md`, "Миграции").

Обычные YAML-манифесты, без Helm/Kustomize — читать и дебажить руками, без
дополнительных инструментов. Секреты — `kubectl create secret` из тех же
`.env`-файлов, что и у compose (не хранятся в git, генерируются на лету
скриптом `apply.sh`, см. ниже).

## Файлы

| Файл | Что внутри |
|---|---|
| `00-namespace.yaml` | namespace `wallet-transaction` |
| `01-db.yaml` | Postgres: PVC, Service, Deployment (ссылается на Secret `db-credentials` и ConfigMap `db-init-script` — оба создаёт `apply.sh`) |
| `02-redis.yaml` | Redis (AOF + PVC — persistence обязательна, см. comment в файле) |
| `03-migrate-job.yaml` | Job'ы наката схемы (`auth`/`wallet`), golang-migrate — аналог `infra/db/migrate.sh`, но без привязки к podman (ссылается на ConfigMap'ы `migrate-auth-sql`/`migrate-wallet-sql`, создаёт `apply.sh`) |
| `04-google-auth.yaml` | google-auth: Service + Deployment (ссылается на Secret'ы `google-auth-env`/`google-auth-jwt-key`) |
| `05-wallet-api.yaml` | wallet-api: Service + Deployment (ссылается на Secret `wallet-api-env`) |
| `06-wallet-gateway.yaml` | wallet-gateway: Service (NodePort) + Deployment — единственный сервис без секретов, все значения прямо в файле |
| `07-wallet-web.yaml` | wallet-web (nginx-статика): Service + Deployment, без секретов |
| `08-wallet-report.yaml` | wallet-report: Service + Deployment (ссылается на Secret `wallet-report-env`) — CQRS-lite query-сторона, читает БД ролью `wallet_reader`, писать не может физически |
| `10-wallet-ai.yaml` | wallet-ai: Service + Deployment, без секретов — LLM в кластере нет (`LLM_URL` не задан), ИИ выключен, `/api/ai/status` → `enabled=false` |
| `apply.sh` | Оркестрирует всё это по порядку — см. "Запуск" ниже |

## Перед первым запуском

Как и с compose — сначала обычные `.env`:

```bash
cp infra/db/.env.example infra/db/.env
cp google-auth/.env.example google-auth/.env      # + вписать Google OAuth креды
cp wallet-api/.env.example wallet-api/.env
cp wallet-report/.env.example wallet-report/.env
openssl genrsa -out google-auth/jwt_signing_key.pem 2048
```

`REDIRECT_URL` в `google-auth/.env` (и Authorized redirect URI в Google
Cloud Console) должен указывать на `http://localhost:8090/auth/google/callback`
— именно поэтому доступ к гейтвею ниже через `kubectl port-forward`, не
через сырой NodePort (адрес NodePort — IP кластера/ноды, не `localhost`,
Google туда не отредиректит правильно).

## Сборка образов

Манифесты НИЧЕГО не билдят — образы `wallet-transaction/{google-auth,
wallet-api,wallet-report,wallet-gateway,wallet-web}:local` нужно собрать и
загрузить в кластер заранее (и заново после любого изменения кода сервиса):

```bash
# minikube — собрать прямо в докер-демоне кластера, без push в registry:
minikube image build -t wallet-transaction/google-auth:local ./google-auth
minikube image build -t wallet-transaction/wallet-api:local ./wallet-api
minikube image build -t wallet-transaction/wallet-report:local ./wallet-report
minikube image build -t wallet-transaction/wallet-ai:local ./wallet-ai
minikube image build -t wallet-transaction/wallet-gateway:local ./wallet-gateway
minikube image build -t wallet-transaction/wallet-web:local ./wallet-web

# kind — собрать локально (docker/podman build), потом загрузить в кластер:
docker build -t wallet-transaction/google-auth:local ./google-auth
kind load docker-image wallet-transaction/google-auth:local
# ...аналогично для остальных четырёх
```

Все Deployment'ы используют `imagePullPolicy: IfNotPresent` — если образ
уже есть локально в кластере под тем же тегом `:local`, наружу за ним никто
не полезет (значит, и падать на "ImagePullBackOff" из-за отсутствия
registry не должно, но и пересборка без пересоздания образа с тем же тегом
не подхватится сама — после `minikube image build`/`kind load` пересоздайте
под: `kubectl rollout restart deployment/<имя> -n wallet-transaction`).

## Запуск

```bash
bash infra/k8s/apply.sh
```

Делает по порядку (см. комментарии в самом скрипте):
1. namespace;
2. секреты (`db-credentials`, `google-auth-env`, `google-auth-jwt-key`,
   `wallet-api-env`, `wallet-report-env`) и ConfigMap'ы (`db-init-script`,
   `migrate-auth-sql`/`migrate-wallet-sql`) — из `.env`-файлов и `infra/db/`,
   пересоздаются каждый запуск (`kubectl apply` поверх, так что повторный
   запуск после правки `.env` — это и есть способ обновить секрет);
3. `db` + `redis`, ждёт готовности `db`;
4. Job'ы миграций (`up`), ждёт их завершения — **если база уже
   существовала ДО перехода на golang-migrate**, `up` упадёт на "relation
   already exists": это ожидаемо, см. `infra/db/README.md`, "Миграции" — на
   чистом volume (свежий PVC) ничего делать не нужно, просто дайте
   `apply.sh` отработать;
5. `google-auth`, `wallet-api`, `wallet-report`, `wallet-gateway`, `wallet-web`.

Только пересоздать секреты/конфиги (после правки `.env`), без остального:

```bash
bash infra/k8s/apply.sh --secrets-only
```

## Доступ

```bash
kubectl port-forward -n wallet-transaction svc/wallet-gateway 8090:8090
```

и открыть `http://localhost:8090` — см. "Перед первым запуском" выше,
почему не через NodePort напрямую.

## Проверить статус / логи

```bash
kubectl get all -n wallet-transaction
kubectl logs -n wallet-transaction deployment/wallet-gateway -f
kubectl logs -n wallet-transaction job/db-migrate-auth
```

## Подключиться к Postgres/Redis с Windows напрямую

Мимо гейтвея, в обход контейнерной сети (как порт `15432`/`16379` у
compose):

```bash
kubectl port-forward -n wallet-transaction svc/db 15432:5432
kubectl port-forward -n wallet-transaction svc/redis 16379:6379
```

Креды — из `infra/db/.env` (`AUTH_POSTGRES_*`/`WALLET_POSTGRES_*`/`MIGRATOR_POSTGRES_*`,
см. `infra/db/README.md`, "Подключение с Windows напрямую" — то же самое, просто
`port-forward` вместо проброшенного порта compose).

## Снести всё

```bash
kubectl delete namespace wallet-transaction
```

Удаляет вообще всё, включая PVC (данные Postgres/Redis) — для чистого
передеплоя с нуля.
