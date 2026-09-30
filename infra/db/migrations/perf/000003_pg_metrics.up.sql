-- Добавляет метрики САМОГО Postgres поверх avg_cpu_pct/avg_mem_bytes
-- (000001_init.up.sql) — CPU/RAM целевого контейнера ничего не говорят о
-- том, ЧТО происходит внутри базы под нагрузкой: насыщение пула соединений
-- reports_pool, попадание в page cache, ожидания на блокировках. Источник —
-- тот же Prometheus/postgres-exporter (см. servers/compose.yaml, сервис
-- "postgres-exporter"), запрашивается в record_run.sh тем же приёмом
-- avg_over_window, что и CPU/RAM.
ALTER TABLE test_result
    -- Среднее число "занятых" соединений reports_pool (datname=wallet_api,
    -- usename=wallet_reader — именно эта роль/база у wallet-report, см.
    -- REPORTS_DATABASE_URL в compose.yaml) за окно уровня concurrency —
    -- state IN ('active','idle in transaction'): "idle" — соединение живо,
    -- но не занято работой, само по себе не сигнал насыщения пула.
    ADD COLUMN avg_pg_active_conns numeric,
    -- Buffer cache hit ratio за окно, % — increase(blks_hit)/(increase(blks_hit)
    -- + increase(blks_read)) на wallet_api за время прогона уровня, НЕ
    -- мгновенный снимок (мгновенное отношение растущих с начала аптайма
    -- counters почти всегда близко к 100% и не показывает, что происходило
    -- ИМЕННО в это окно — см. prom_query_at в record_run.sh).
    ADD COLUMN avg_pg_cache_hit_pct numeric,
    -- Среднее число НЕ выданных (ожидающих) блокировок на wallet_api за окно
    -- (pg_locks WHERE NOT granted) — требует отдельного custom-query у
    -- postgres-exporter, дефолтный коллектор locks считает ВСЕ блокировки
    -- без разбивки по granted (см. infra/monitoring/postgres-exporter/queries.yaml).
    ADD COLUMN avg_pg_lock_waits numeric;

COMMENT ON COLUMN test_result.avg_pg_active_conns IS
    'Среднее число занятых соединений reports_pool (wallet_api/wallet_reader, state active|idle in transaction) за окно уровня concurrency, NULL если Prometheus был недоступен.';
COMMENT ON COLUMN test_result.avg_pg_cache_hit_pct IS
    'Postgres buffer cache hit ratio, % (blks_hit/(blks_hit+blks_read), delta за окно), NULL если Prometheus был недоступен.';
COMMENT ON COLUMN test_result.avg_pg_lock_waits IS
    'Среднее число не выданных (ожидающих) блокировок pg_locks на wallet_api за окно, NULL если Prometheus/custom-query недоступны.';
