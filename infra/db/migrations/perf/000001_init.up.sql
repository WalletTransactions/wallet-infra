-- perf_history — история прогонов нагрузочного контура (см.
-- servers/wallet-report/loadtest/record_run.sh), НЕ часть домена кошелька
-- (schema/server/schema/client — та схема мирrouится между сервером и
-- Android-клиентом, см. servers/infra/db/README.md, "Три роли" — это
-- отдельная, четвёртая база на том же инстансе Postgres, никак не
-- синкается никуда). Поэтому миграции этого домена живут здесь, а не в
-- schema/server/ — тот каталог про леджер, не про метрики CI.
--
-- Одна запись test_run — один прогон нагрузочного контура (обычно —
-- один сценарий на одном коммите); test_result — по одной строке НА
-- КАЖДЫЙ уровень concurrency в рамках этого прогона (см. record_run.sh,
-- "clients" — sweep 100/500/1000/... одним test_run, не отдельным
-- прогоном на каждый уровень).
CREATE TABLE test_run (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    commit_sha  text NOT NULL,
    branch      text NOT NULL,
    ts          timestamptz NOT NULL DEFAULT now(),
    -- "где гоняли" (например "local-podman-compose", "ci") — не то же
    -- самое, что version (версия ПРИЛОЖЕНИЯ/сервиса под нагрузкой).
    environment text NOT NULL,
    version     text,
    scenario    text NOT NULL,
    -- Произвольные параметры прогона (уровни concurrency, длительность на
    -- уровень, REPORTS_DB_POOL_SIZE и т.п.) — jsonb, не отдельные колонки:
    -- набор параметров разный у разных сценариев, и раздувать схему под
    -- каждый новый параметр сценария не нужно (см. record_run.sh, что туда
    -- реально кладётся).
    parameters  jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX test_run_branch_ts_idx ON test_run (branch, ts DESC);
CREATE INDEX test_run_commit_sha_idx ON test_run (commit_sha);

CREATE TABLE test_result (
    id            bigserial PRIMARY KEY,
    test_run_id   uuid NOT NULL REFERENCES test_run (id) ON DELETE CASCADE,
    -- Дублирует test_run.scenario — да, денормализация: сравнение в Grafana
    -- (../../../monitoring/grafana/dashboards/perf-history.json) почти
    -- всегда фильтрует ПО test_result (JOIN на test_run только за
    -- commit_sha/branch/ts), лишний JOIN ради одного повторяющегося поля
    -- того не стоит.
    scenario      text NOT NULL,
    clients       integer NOT NULL,
    duration_s    numeric NOT NULL,
    requests      bigint NOT NULL,
    rps           numeric NOT NULL,
    -- Percentile-ы latency, миллисекунды — nullable: k6 отдаёt их, только
    -- если сценарий явно попросил summaryTrendStats (см.
    -- ../../../../wallet-report/loadtest/k6/lib/summary_options.js) — если
    -- кто-то прогонит сценарий без него, запись не должна упасть, просто
    -- часть колонок останется пустой.
    p50_ms        numeric,
    p90_ms        numeric,
    p95_ms        numeric,
    p99_ms        numeric,
    error_rate    numeric NOT NULL,
    -- CPU/RAM целевого контейнера ЗА ОКНО ЭТОГО УРОВНЯ concurrency — не из
    -- k6 (он не видит сервер изнутри), а из Prometheus/cAdvisor (стек уже
    -- поднят, см. servers/compose.yaml) — record_run.sh запрашивает
    -- avg_over_time(...) сразу после прогона и кладёт агрегат сюда, ПОКА
    -- Prometheus ещё помнит это окно (retention по умолчанию короче, чем
    -- может понадобиться сравнение "сейчас vs полгода назад"). NULL, если
    -- Prometheus был недоступен в момент записи — не блокирует запись
    -- остальных метрик.
    avg_cpu_pct   numeric,
    avg_mem_bytes bigint
);

CREATE INDEX test_result_test_run_id_idx ON test_result (test_run_id);

-- Роль ТОЛЬКО для чтения — под ней ходит Grafana (см.
-- ../../monitoring/grafana/provisioning/datasources/datasource.yml,
-- источник "Perf History"). Тот же приём и те же оговорки, что у
-- wallet_reader (schema/server/role/wallet_reader.sql) — идемпотентный и
-- лечащий файл, пароль в репозитории осознанно (dev-only, роль умеет
-- только SELECT).
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'perf_reader') THEN
        CREATE ROLE perf_reader;
    END IF;
END
$$;

ALTER ROLE perf_reader
    LOGIN
    NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
    CONNECTION LIMIT 10
    PASSWORD 'perf_reader';

DO $$
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO perf_reader', current_database());
END
$$;

GRANT USAGE ON SCHEMA public TO perf_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO perf_reader;
-- Будущие таблицы этого домена читаются без правки этой роли — действует
-- только на объекты, создаваемые ролью, что выполняет эту миграцию
-- (мигратор, владелец схемы, см. servers/infra/db/README.md).
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO perf_reader;
-- Defense in depth — сейчас этой роли ничего, кроме SELECT, и не выдавалось,
-- но фиксирует состояние явно, а не полагается на историю базы (тот же
-- принцип, что и в wallet_reader.sql).
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
    ON ALL TABLES IN SCHEMA public FROM perf_reader;
