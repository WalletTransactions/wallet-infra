-- Откат 000002_wall_scenario.up.sql.
ALTER TABLE test_result
    DROP COLUMN IF EXISTS target_rate_max,
    DROP COLUMN IF EXISTS dropped_iterations;
