-- Добавляет колонки под scenario_find_the_wall.js (см.
-- servers/wallet-report/loadtest/record_wall_run.sh) — открытый (open-loop,
-- ramping-arrival-rate) сценарий: он не sweep'ит уровни concurrency, как
-- scenario_pool_saturation.js (record_run.sh), а один раз гонит нарастающий
-- по стадиям темп запросов (10 -> 1500 rps), пока сервер не "просядет".
-- Поэтому на такой прогон пишется ОДНА строка test_result (не по одной на
-- уровень), а "уровень" здесь — не число одновременных клиентов
-- (test_result.clients уже занят под другой смысл в остальных сценариях —
-- туда кладётся k6-метрика vus_max, только для traceability), а темп
-- запросов, который сервер попытался выдержать.
--
-- Обе колонки nullable — существующие сценарии (pool_saturation,
-- dashboard_burst, sync_push_*) их не заполняют, и наоборот, сами по себе
-- не участвуют в "sweep"-панелях дашборда (perf-history.json), рассчитанных
-- на variable(test_result.clients).
ALTER TABLE test_result
    -- Пиковый целевой темп запросов (rps) из stages сценария — ДОЛЖЕН
    -- совпадать с последним ненулевым target в scenario_find_the_wall.js
    -- (см. TARGET_RATE_PEAK в record_wall_run.sh — параметр, не читается
    -- из .js автоматически, держите их в синхроне при правке stages).
    ADD COLUMN target_rate_max numeric,
    -- Встроенная k6-метрика dropped_iterations (см.
    -- https://k6.io/docs/using-k6/metrics/reference/#dropped-iterations) —
    -- запросы, которые executor НЕ СМОГ отправить (не хватило VU из maxVUs,
    -- чтобы удержать целевой темп) — главный сигнал "уже не успевает", ещё
    -- до роста error_rate/latency.
    ADD COLUMN dropped_iterations bigint;

COMMENT ON COLUMN test_result.target_rate_max IS
    'Пиковый целевой rps сценария find_the_wall (open-loop), NULL для остальных сценариев.';
COMMENT ON COLUMN test_result.dropped_iterations IS
    'k6 dropped_iterations — итерации, которые executor не смог запустить вовремя (нехватка VU под целевой темп).';
