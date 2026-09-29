-- =============================================================================
-- 02_returns.sql
-- Daily returns (close-to-close, overnight, intraday), an equal-weighted market
-- index, and monthly compounded returns.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Daily returns. A return is NULL when it cannot be trusted (bad tick, the
-- reversal day after it, spin-off, gap in history, or first observation).
-- adj_log_price is a cumulative sum of clean log returns: a price series that
-- is immune to the spin-off jumps in the raw close.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE daily_returns AS
WITH r AS (
    SELECT
        ticker,
        trade_date,
        close,
        volume,
        close * volume AS dollar_volume,
        f_zero_volume,
        CASE WHEN prev_close IS NULL OR f_gap OR f_bad_tick OR f_after_bad_tick OR f_corp_action
             THEN NULL ELSE close / prev_close - 1 END AS ret,
        CASE WHEN prev_close IS NULL OR f_gap OR f_bad_tick OR f_after_bad_tick OR f_corp_action
                  OR f_missing_ohl
             THEN NULL ELSE open / prev_close - 1 END AS ret_overnight,
        CASE WHEN f_bad_tick OR f_missing_ohl
             THEN NULL ELSE close / open - 1 END AS ret_intraday
    FROM prices_flagged
)
SELECT
    r.*,
    LN(1 + r.ret) AS log_ret,
    SUM(COALESCE(LN(1 + r.ret), 0)) OVER (PARTITION BY ticker ORDER BY trade_date) AS adj_log_price
FROM r;

-- -----------------------------------------------------------------------------
-- Equal-weighted market index (no market caps in the dataset, so every stock
-- gets the same weight each day).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE market_daily AS
SELECT
    trade_date,
    COUNT(ret)                 AS n_stocks,
    AVG(ret)                   AS mkt_ret,
    AVG(ret_overnight)         AS mkt_ret_overnight,
    AVG(ret_intraday)          AS mkt_ret_intraday
FROM daily_returns
GROUP BY trade_date
HAVING COUNT(ret) > 0
ORDER BY trade_date;

-- -----------------------------------------------------------------------------
-- Monthly returns: compound daily returns within each calendar month.
--   (1+r_1)(1+r_2)...(1+r_n) - 1  ==  EXP(SUM(LN(1+r))) - 1
-- Only full months, and only stock-months with >= 15 clean trading days.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE monthly_returns AS
SELECT
    d.ticker,
    c.month,
    c.month_idx,
    EXP(SUM(d.log_ret)) - 1   AS ret_m,
    COUNT(d.log_ret)          AS n_days,
    LAST(d.close ORDER BY d.trade_date) AS month_end_close
FROM daily_returns d
JOIN trading_calendar c USING (trade_date)
WHERE c.is_full_month
GROUP BY d.ticker, c.month, c.month_idx
HAVING COUNT(d.log_ret) >= 15;

CREATE OR REPLACE TABLE market_monthly AS
SELECT
    c.month,
    c.month_idx,
    EXP(SUM(LN(1 + m.mkt_ret))) - 1 AS mkt_ret_m
FROM market_daily m
JOIN trading_calendar c USING (trade_date)
WHERE c.is_full_month
GROUP BY c.month, c.month_idx;
