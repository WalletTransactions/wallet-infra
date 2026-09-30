-- Откат 000001_init.up.sql — см. комментарии там же.
REVOKE SELECT ON ALL TABLES IN SCHEMA public FROM perf_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE SELECT ON TABLES FROM perf_reader;
REVOKE USAGE ON SCHEMA public FROM perf_reader;
DO $$
BEGIN
    EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM perf_reader', current_database());
END
$$;

DROP TABLE IF EXISTS test_result;
DROP TABLE IF EXISTS test_run;

-- Саму роль perf_reader НЕ удаляем — она без привилегий на эту базу, но
-- DROP ROLE, если она ещё где-то CONNECT-нута (или создателем чего-то в
-- другой базе на этом же кластере), упал бы с "role cannot be dropped
-- because some objects depend on it"; лечится вручную при необходимости
-- (тот же принцип осторожности, что и в остальных ролях проекта).
