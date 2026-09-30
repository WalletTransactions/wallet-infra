-- Откат 000003_pg_metrics.up.sql.
ALTER TABLE test_result
    DROP COLUMN IF EXISTS avg_pg_active_conns,
    DROP COLUMN IF EXISTS avg_pg_cache_hit_pct,
    DROP COLUMN IF EXISTS avg_pg_lock_waits;
