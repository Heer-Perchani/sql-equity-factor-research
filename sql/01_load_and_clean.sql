-- =============================================================================
-- 01_load_and_clean.sql
-- Stage the raw Kaggle CSV, build a trading calendar, run data-quality checks,
-- and flag rows that must not be used as returns.
--
-- Known issues in this dataset (found during profiling):
--   * Spin-offs appear as fake crashes: EBAY -57% (PayPal spin, 2015-07-20),
--     NI -63% (CPG spin), BAX -44% (Baxalta spin), DISCA/DISCK share split.
--   * Bad ticks: LNT halves on 2016-05-19 and doubles back the next day.
--   * A handful of rows have NULL open/high/low or zero volume.
-- =============================================================================

CREATE OR REPLACE TABLE params AS
SELECT
    0.25  AS bad_tick_move,        -- a >25% move ...
    0.05  AS bad_tick_revert,      -- ... that reverts to within 5% next day is a bad print
    -0.40 AS corp_action_drop,     -- a >40% one-day drop that does NOT revert = spin-off/split
    10.0  AS cost_bps,             -- one-way transaction cost used in backtests
    252   AS days_per_year;

-- -----------------------------------------------------------------------------
-- Raw staging table
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE raw_prices AS
SELECT
    Name::VARCHAR  AS ticker,
    date::DATE     AS trade_date,
    open::DOUBLE   AS open,
    high::DOUBLE   AS high,
    low::DOUBLE    AS low,
    close::DOUBLE  AS close,
    volume::BIGINT AS volume
FROM read_csv('data/all_stocks_5yr.csv', header = true);

-- -----------------------------------------------------------------------------
-- Trading calendar: one row per exchange trading day, with a sequential index
-- so "consecutive trading days" is simply day_idx - prev_day_idx = 1.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE trading_calendar AS
WITH d AS (SELECT DISTINCT trade_date FROM raw_prices)
SELECT
    trade_date,
    ROW_NUMBER() OVER (ORDER BY trade_date)         AS day_idx,
    DATE_TRUNC('month', trade_date)::DATE           AS month,
    DENSE_RANK() OVER (ORDER BY DATE_TRUNC('month', trade_date)) AS month_idx,
    trade_date = MAX(trade_date) OVER (PARTITION BY DATE_TRUNC('month', trade_date)) AS is_month_end,
    -- first and last calendar months are partial (data runs 2013-02-08 .. 2018-02-07)
    DATE_TRUNC('month', trade_date) NOT IN (
        (SELECT DATE_TRUNC('month', MIN(trade_date)) FROM d),
        (SELECT DATE_TRUNC('month', MAX(trade_date)) FROM d)
    ) AS is_full_month
FROM d;

-- -----------------------------------------------------------------------------
-- Row-level quality flags
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE prices_flagged AS
WITH base AS (
    SELECT
        r.*,
        c.day_idx,
        LAG(r.close)   OVER w AS prev_close,
        LEAD(r.close)  OVER w AS next_close,
        LAG(c.day_idx) OVER w AS prev_day_idx
    FROM raw_prices r
    JOIN trading_calendar c USING (trade_date)
    WINDOW w AS (PARTITION BY r.ticker ORDER BY r.trade_date)
),
flags AS (
    SELECT
        b.*,
        (open IS NULL OR high IS NULL OR low IS NULL)                     AS f_missing_ohl,
        COALESCE(volume = 0, FALSE)                                       AS f_zero_volume,
        COALESCE(high < low
                 OR high < GREATEST(open, close) - 1e-6
                 OR low  > LEAST(open, close)    + 1e-6, FALSE)           AS f_bad_ohlc,
        COALESCE(day_idx - prev_day_idx > 1, FALSE)                       AS f_gap,
        -- big move that snaps back the next day => erroneous print
        COALESCE(ABS(close / prev_close - 1) > p.bad_tick_move
                 AND ABS(next_close / prev_close - 1) < p.bad_tick_revert, FALSE) AS f_bad_tick
    FROM base b, params p
)
SELECT
    f.*,
    COALESCE(LAG(f_bad_tick) OVER (PARTITION BY ticker ORDER BY trade_date), FALSE) AS f_after_bad_tick,
    COALESCE(close / prev_close - 1 < p.corp_action_drop AND NOT f_bad_tick, FALSE) AS f_corp_action
FROM flags f, params p;

-- -----------------------------------------------------------------------------
-- Data-quality report (one row per check)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE dq_report AS
SELECT 'total rows'                        AS check_name, COUNT(*) AS n_rows, NULL AS action FROM raw_prices
UNION ALL SELECT 'distinct tickers',           COUNT(DISTINCT ticker), NULL FROM raw_prices
UNION ALL SELECT 'trading days in calendar',   COUNT(*), NULL FROM trading_calendar
UNION ALL SELECT 'duplicate (ticker, date)',   COUNT(*) - COUNT(DISTINCT (ticker, trade_date)), 'must be 0' FROM raw_prices
UNION ALL SELECT 'missing open/high/low',      COUNT(*) FILTER (f_missing_ohl),   'excluded from overnight/intraday returns' FROM prices_flagged
UNION ALL SELECT 'zero volume',                COUNT(*) FILTER (f_zero_volume),   'kept; excluded from liquidity factor' FROM prices_flagged
UNION ALL SELECT 'inconsistent OHLC bar',      COUNT(*) FILTER (f_bad_ohlc),      'kept (close is still usable)' FROM prices_flagged
UNION ALL SELECT 'gap vs trading calendar',    COUNT(*) FILTER (f_gap),           'multi-day return set to NULL' FROM prices_flagged
UNION ALL SELECT 'bad tick (spike + revert)',  COUNT(*) FILTER (f_bad_tick),      'return and next-day return set to NULL' FROM prices_flagged
UNION ALL SELECT 'corporate action (spin-off)',COUNT(*) FILTER (f_corp_action),   'return set to NULL' FROM prices_flagged
UNION ALL SELECT 'tickers with < 1 year data',
          COUNT(*), 'excluded from per-stock risk stats'
          FROM (SELECT ticker FROM raw_prices GROUP BY ticker HAVING COUNT(*) < 252);

-- Detail of every return that was overridden, for audit
CREATE OR REPLACE TABLE dq_overridden_returns AS
SELECT ticker, trade_date, prev_close, close, next_close,
       ROUND(close / prev_close - 1, 4) AS raw_ret,
       CASE WHEN f_bad_tick THEN 'bad tick'
            WHEN f_after_bad_tick THEN 'reversal of bad tick'
            WHEN f_corp_action THEN 'corporate action' END AS reason
FROM prices_flagged
WHERE f_bad_tick OR f_after_bad_tick OR f_corp_action
ORDER BY trade_date;
