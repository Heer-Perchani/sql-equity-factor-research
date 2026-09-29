-- =============================================================================
-- 07_anomalies.sql
-- Calendar and intraday anomalies on the equal-weighted market.
--   * Overnight vs intraday: is the equity premium earned while the market is
--     closed (close -> next open) or while it is open (open -> close)?
--   * Day-of-week effect.
--   * Turn-of-month effect (last trading day + first 3 of the next month).
-- Each effect is reported with a t-statistic so noise is not mistaken for signal.
-- =============================================================================

-- Cumulative overnight vs intraday growth of $1
CREATE OR REPLACE TABLE overnight_intraday AS
SELECT
    trade_date,
    mkt_ret,
    mkt_ret_overnight,
    mkt_ret_intraday,
    EXP(SUM(LN(1 + mkt_ret))           OVER w) AS cum_close_to_close,
    EXP(SUM(LN(1 + mkt_ret_overnight)) OVER w) AS cum_overnight,
    EXP(SUM(LN(1 + mkt_ret_intraday))  OVER w) AS cum_intraday
FROM market_daily
WHERE mkt_ret_overnight IS NOT NULL AND mkt_ret_intraday IS NOT NULL
WINDOW w AS (ORDER BY trade_date);

CREATE OR REPLACE TABLE overnight_intraday_summary AS
SELECT 'overnight (close->open)' AS session,
       AVG(mkt_ret_overnight) * 252 AS ann_mean,
       STDDEV_SAMP(mkt_ret_overnight) * SQRT(252) AS ann_vol,
       AVG(mkt_ret_overnight) / STDDEV_SAMP(mkt_ret_overnight) * SQRT(252) AS sharpe,
       AVG(mkt_ret_overnight) / (STDDEV_SAMP(mkt_ret_overnight) / SQRT(COUNT(*))) AS t_stat
FROM market_daily
UNION ALL
SELECT 'intraday (open->close)',
       AVG(mkt_ret_intraday) * 252,
       STDDEV_SAMP(mkt_ret_intraday) * SQRT(252),
       AVG(mkt_ret_intraday) / STDDEV_SAMP(mkt_ret_intraday) * SQRT(252),
       AVG(mkt_ret_intraday) / (STDDEV_SAMP(mkt_ret_intraday) / SQRT(COUNT(*)))
FROM market_daily;

-- Day-of-week effect
CREATE OR REPLACE TABLE day_of_week_effect AS
SELECT
    ISODOW(trade_date)                AS dow,
    DAYNAME(trade_date)               AS day_name,
    COUNT(*)                          AS n_days,
    AVG(mkt_ret) * 1e4                AS mean_ret_bps,
    STDDEV_SAMP(mkt_ret) * 1e4        AS std_ret_bps,
    AVG(mkt_ret) / (STDDEV_SAMP(mkt_ret) / SQRT(COUNT(*))) AS t_stat,
    AVG(CASE WHEN mkt_ret > 0 THEN 1.0 ELSE 0.0 END) AS pct_up_days
FROM market_daily
GROUP BY 1, 2
ORDER BY 1;

-- Turn-of-month effect
CREATE OR REPLACE TABLE turn_of_month_effect AS
WITH c AS (
    SELECT
        trade_date,
        ROW_NUMBER() OVER (PARTITION BY month ORDER BY trade_date)      AS day_of_month,
        ROW_NUMBER() OVER (PARTITION BY month ORDER BY trade_date DESC) AS days_to_month_end
    FROM trading_calendar
),
tagged AS (
    SELECT m.mkt_ret,
           CASE WHEN c.days_to_month_end = 1 OR c.day_of_month <= 3
                THEN 'turn of month' ELSE 'rest of month' END AS period
    FROM market_daily m JOIN c USING (trade_date)
)
SELECT
    period,
    COUNT(*)                   AS n_days,
    AVG(mkt_ret) * 1e4         AS mean_ret_bps,
    AVG(mkt_ret) / (STDDEV_SAMP(mkt_ret) / SQRT(COUNT(*))) AS t_stat,
    AVG(CASE WHEN mkt_ret > 0 THEN 1.0 ELSE 0.0 END) AS pct_up_days
FROM tagged
GROUP BY period
ORDER BY period DESC;
