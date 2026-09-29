-- =============================================================================
-- 04_factors.sql
-- Cross-sectional equity factors, formed at each month-end t using ONLY data
-- available at t, and evaluated on the return of month t+1.
--
--   momentum_12_1   : return over months t-11..t-1 (skip the latest month,
--                     which tends to reverse)                 high  -> long
--   reversal_1m     : return of month t                       low   -> long
--   low_vol         : 63-day realised volatility at t          low   -> long
--   high_52w        : close / 252-day max close                 high  -> long
--   amihud_illiq    : avg(|ret| / $volume) over last 21 days    high  -> long
--
-- Every factor is stored with a "score" oriented so HIGHER = expected to
-- outperform; quintile 5 is always the long leg, quintile 1 the short leg.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Daily-frequency signals sampled on month-end dates
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE month_end_signals AS
WITH d AS (
    SELECT
        d.ticker,
        d.trade_date,
        d.adj_log_price,
        -- 52-week high on the clean (spin-off adjusted) price series
        CASE WHEN COUNT(*) OVER w252 = 252
             THEN EXP(d.adj_log_price - MAX(d.adj_log_price) OVER w252) END AS pct_of_52w_high,
        -- Amihud illiquidity: price impact per $1m traded
        CASE WHEN COUNT(d.ret) OVER w21 >= 15
             THEN AVG(ABS(d.ret) / NULLIF(d.dollar_volume, 0) * 1e6) OVER w21 END AS amihud
    FROM daily_returns d
    WINDOW
        w21  AS (PARTITION BY d.ticker ORDER BY d.trade_date ROWS BETWEEN 20  PRECEDING AND CURRENT ROW),
        w252 AS (PARTITION BY d.ticker ORDER BY d.trade_date ROWS BETWEEN 251 PRECEDING AND CURRENT ROW)
)
SELECT
    d.ticker,
    c.month,
    d.pct_of_52w_high,
    d.amihud,
    rr.vol_63d
FROM d
JOIN trading_calendar c USING (trade_date)
LEFT JOIN rolling_risk rr USING (ticker, trade_date)
WHERE c.is_month_end;

-- -----------------------------------------------------------------------------
-- Monthly signals + the NEXT month's return (the thing we try to predict)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE factor_panel AS
WITH m AS (
    SELECT
        ticker, month, month_idx, ret_m,
        -- momentum: compound months t-11 .. t-1 (11 months, skipping month t)
        EXP(SUM(LN(1 + ret_m)) OVER mom) - 1          AS mom_12_1,
        COUNT(*)            OVER mom                  AS mom_n,
        MIN(month_idx)      OVER mom                  AS mom_first_idx,
        LEAD(ret_m)         OVER (PARTITION BY ticker ORDER BY month_idx) AS fwd_ret,
        LEAD(month_idx)     OVER (PARTITION BY ticker ORDER BY month_idx) AS fwd_month_idx
    FROM monthly_returns
    WINDOW mom AS (PARTITION BY ticker ORDER BY month_idx ROWS BETWEEN 11 PRECEDING AND 1 PRECEDING)
)
SELECT
    m.ticker,
    m.month                                             AS formation_month,
    (m.month + INTERVAL 1 MONTH)::DATE                  AS holding_month,
    -- only accept windows with no missing months
    CASE WHEN m.mom_n = 11 AND m.mom_first_idx = m.month_idx - 11 THEN m.mom_12_1 END AS mom_12_1,
    m.ret_m                                             AS ret_1m,
    s.vol_63d,
    s.pct_of_52w_high,
    s.amihud,
    m.fwd_ret
FROM m
LEFT JOIN month_end_signals s
       ON s.ticker = m.ticker AND s.month = m.month
-- the forward return must be the very next calendar month (no gaps)
WHERE m.fwd_month_idx = m.month_idx + 1;

-- -----------------------------------------------------------------------------
-- Long format: one row per (factor, month, stock) with an oriented score,
-- then cross-sectional quintiles and ranks.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE factor_scores AS
WITH long AS (
              SELECT 'momentum_12_1' AS factor, ticker, formation_month, holding_month,  mom_12_1        AS score, fwd_ret FROM factor_panel
    UNION ALL SELECT 'reversal_1m',            ticker, formation_month, holding_month, -ret_1m          AS score, fwd_ret FROM factor_panel
    UNION ALL SELECT 'low_vol',                ticker, formation_month, holding_month, -vol_63d         AS score, fwd_ret FROM factor_panel
    UNION ALL SELECT 'high_52w',               ticker, formation_month, holding_month,  pct_of_52w_high AS score, fwd_ret FROM factor_panel
    UNION ALL SELECT 'amihud_illiq',           ticker, formation_month, holding_month,  amihud          AS score, fwd_ret FROM factor_panel
)
SELECT
    *,
    NTILE(5)     OVER (PARTITION BY factor, formation_month ORDER BY score)   AS quintile,
    RANK()       OVER (PARTITION BY factor, formation_month ORDER BY score)   AS score_rank,
    RANK()       OVER (PARTITION BY factor, formation_month ORDER BY fwd_ret) AS fwd_rank
FROM long
WHERE score IS NOT NULL AND fwd_ret IS NOT NULL;

-- -----------------------------------------------------------------------------
-- Information Coefficient (IC): each month, the Spearman rank correlation
-- between the factor score and next month's return. A persistent positive IC
-- means the factor has predictive power.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE factor_ic_monthly AS
SELECT
    factor,
    formation_month,
    COUNT(*)                     AS n_stocks,
    CORR(score_rank, fwd_rank)   AS rank_ic
FROM factor_scores
GROUP BY factor, formation_month;

CREATE OR REPLACE TABLE factor_ic_summary AS
SELECT
    factor,
    COUNT(*)                                          AS n_months,
    ROUND(AVG(n_stocks))                              AS avg_stocks,
    AVG(rank_ic)                                      AS mean_ic,
    STDDEV_SAMP(rank_ic)                              AS std_ic,
    AVG(rank_ic) / STDDEV_SAMP(rank_ic) * SQRT(12)    AS ic_ir_ann,
    AVG(rank_ic) / (STDDEV_SAMP(rank_ic) / SQRT(COUNT(*))) AS t_stat,
    AVG(CASE WHEN rank_ic > 0 THEN 1.0 ELSE 0.0 END)  AS pct_months_positive
FROM factor_ic_monthly
GROUP BY factor
ORDER BY t_stat DESC;
