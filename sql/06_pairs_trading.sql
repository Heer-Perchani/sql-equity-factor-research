-- =============================================================================
-- 06_pairs_trading.sql
-- Statistical-arbitrage pairs strategy, fully in SQL.
--
--   Formation period : 2013-02-08 .. 2016-12-31  (select pairs, fit hedge ratio)
--   Trading period   : 2017-01-01 .. 2018-02-07  (out-of-sample trading)
--
-- 1. Screen every pair of stocks (~127k) by daily-return correlation.
-- 2. For the top candidates, regress log-price A on log-price B to get the
--    hedge ratio; the residual is the "spread".
-- 3. Estimate how fast the spread mean-reverts (AR(1) half-life) and keep
--    pairs that revert within a reasonable time.
-- 4. Trade: z = (spread - formation mean) / formation std.
--      z >  2  -> short the spread     z < -2 -> long the spread
--      exit when z crosses 0. Positions are entered on the next day's close.
-- =============================================================================

CREATE OR REPLACE TABLE pairs_params AS
SELECT
    DATE '2016-12-31' AS formation_end,
    2.0               AS entry_z,
    20                AS n_pairs,
    5.0               AS min_half_life_days,
    60.0              AS max_half_life_days;

-- Universe: stocks with complete clean history through both periods
CREATE OR REPLACE TABLE pairs_universe AS
SELECT ticker
FROM daily_returns
GROUP BY ticker
HAVING MIN(trade_date) = (SELECT MIN(trade_date) FROM trading_calendar)
   AND MAX(trade_date) = (SELECT MAX(trade_date) FROM trading_calendar)
   AND COUNT(ret) >= (SELECT COUNT(*) FROM trading_calendar) - 5;

-- -----------------------------------------------------------------------------
-- Step 1: correlation screen over all pairs (self-join on date, a < b)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE pair_correlations AS
WITH f AS (
    SELECT d.ticker, d.trade_date, d.ret
    FROM daily_returns d
    JOIN pairs_universe u USING (ticker)
    WHERE d.trade_date <= (SELECT formation_end FROM pairs_params)
      AND d.ret IS NOT NULL
)
SELECT
    a.ticker        AS ticker_a,
    b.ticker        AS ticker_b,
    CORR(a.ret, b.ret) AS ret_corr,
    COUNT(*)        AS n_obs
FROM f a
JOIN f b
  ON a.trade_date = b.trade_date
 AND a.ticker < b.ticker
GROUP BY a.ticker, b.ticker;

-- -----------------------------------------------------------------------------
-- Step 2 + 3: hedge ratio, spread statistics and mean-reversion half-life
-- for the 200 most correlated pairs
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE pair_candidates AS
WITH top AS (
    SELECT * FROM pair_correlations ORDER BY ret_corr DESC LIMIT 200
),
px AS (
    SELECT t.ticker_a, t.ticker_b, t.ret_corr, a.trade_date,
           a.adj_log_price AS la, b.adj_log_price AS lb
    FROM top t
    JOIN daily_returns a ON a.ticker = t.ticker_a
    JOIN daily_returns b ON b.ticker = t.ticker_b AND b.trade_date = a.trade_date
    WHERE a.trade_date <= (SELECT formation_end FROM pairs_params)
),
fit AS (
    SELECT ticker_a, ticker_b, MAX(ret_corr) AS ret_corr,
           REGR_SLOPE(la, lb)     AS hedge_ratio,
           REGR_INTERCEPT(la, lb) AS alpha,
           REGR_R2(la, lb)        AS price_r2
    FROM px GROUP BY ticker_a, ticker_b
),
spread AS (
    SELECT px.ticker_a, px.ticker_b, px.trade_date,
           px.la - f.hedge_ratio * px.lb - f.alpha AS s
    FROM px JOIN fit f USING (ticker_a, ticker_b)
),
ar AS (
    -- AR(1) on the spread:  delta_s_t = phi * s_{t-1} + e  ->  half-life = -ln 2 / ln(1 + phi)
    SELECT ticker_a, ticker_b,
           REGR_SLOPE(ds, s_lag) AS phi,
           STDDEV_SAMP(s_all)    AS spread_std
    FROM (
        SELECT ticker_a, ticker_b, s AS s_all,
               s - LAG(s) OVER w AS ds,
               LAG(s) OVER w     AS s_lag
        FROM spread
        WINDOW w AS (PARTITION BY ticker_a, ticker_b ORDER BY trade_date)
    )
    GROUP BY ticker_a, ticker_b
)
SELECT
    f.*,
    ar.phi,
    CASE WHEN ar.phi < 0 THEN -LN(2) / LN(1 + ar.phi) END AS half_life_days,
    ar.spread_std
FROM fit f JOIN ar USING (ticker_a, ticker_b)
WHERE f.hedge_ratio > 0;

CREATE OR REPLACE TABLE selected_pairs AS
SELECT c.*
FROM pair_candidates c, pairs_params p
WHERE c.half_life_days BETWEEN p.min_half_life_days AND p.max_half_life_days
ORDER BY c.ret_corr DESC
LIMIT (SELECT n_pairs FROM pairs_params);

-- -----------------------------------------------------------------------------
-- Step 4: out-of-sample trading
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE pairs_daily AS
WITH px AS (
    SELECT sp.ticker_a, sp.ticker_b, sp.hedge_ratio,
           a.trade_date,
           a.adj_log_price - sp.hedge_ratio * b.adj_log_price - sp.alpha AS spread,
           a.ret AS ret_a, b.ret AS ret_b
    FROM selected_pairs sp
    JOIN daily_returns a ON a.ticker = sp.ticker_a
    JOIN daily_returns b ON b.ticker = sp.ticker_b AND b.trade_date = a.trade_date
),
-- z-score uses formation-period mean/std only (no look-ahead)
z AS (
    SELECT px.*,
           (px.spread - st.mu) / st.sd AS z
    FROM px
    JOIN (SELECT ticker_a, ticker_b, AVG(spread) AS mu, STDDEV_SAMP(spread) AS sd
          FROM px WHERE trade_date <= (SELECT formation_end FROM pairs_params)
          GROUP BY ticker_a, ticker_b) st USING (ticker_a, ticker_b)
    WHERE px.trade_date > (SELECT formation_end FROM pairs_params)
),
-- entry/exit events; position = most recent event (gaps-and-islands via IGNORE NULLS)
ev AS (
    SELECT z.*,
           CASE WHEN z >  p.entry_z THEN -1
                WHEN z < -p.entry_z THEN  1
                WHEN SIGN(z) <> SIGN(LAG(z) OVER w) THEN 0
           END AS event
    FROM z, pairs_params p
    WINDOW w AS (PARTITION BY ticker_a, ticker_b ORDER BY trade_date)
),
pos AS (
    SELECT ev.*,
           COALESCE(LAST_VALUE(event IGNORE NULLS) OVER w, 0) AS position
    FROM ev
    WINDOW w AS (PARTITION BY ticker_a, ticker_b ORDER BY trade_date
                 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
)
SELECT
    pos.*,
    LAG(position, 1, 0) OVER w                               AS position_held,
    -- spread return, normalised to $1 gross exposure across both legs
    LAG(position, 1, 0) OVER w
        * (COALESCE(ret_a, 0) - hedge_ratio * COALESCE(ret_b, 0)) / (1 + hedge_ratio) AS gross_pnl,
    ABS(position - LAG(position, 1, 0) OVER w) * (SELECT cost_bps FROM params) / 10000 AS cost
FROM pos
WINDOW w AS (PARTITION BY ticker_a, ticker_b ORDER BY trade_date);

-- Per-pair results
CREATE OR REPLACE TABLE pairs_summary AS
SELECT
    d.ticker_a, d.ticker_b,
    ROUND(MAX(s.ret_corr), 3)          AS formation_corr,
    ROUND(MAX(s.hedge_ratio), 3)       AS hedge_ratio,
    ROUND(MAX(s.half_life_days), 1)    AS half_life_days,
    COUNT(*) FILTER (WHERE d.position <> 0 AND d.position_held = 0) AS n_trades,
    AVG(CASE WHEN d.position_held <> 0 THEN 1.0 ELSE 0.0 END)       AS pct_days_invested,
    EXP(SUM(LN(1 + d.gross_pnl - d.cost))) - 1                      AS total_net_return
FROM pairs_daily d
JOIN selected_pairs s USING (ticker_a, ticker_b)
GROUP BY d.ticker_a, d.ticker_b
ORDER BY total_net_return DESC;

-- Portfolio: equal capital in each pair, daily rebalanced
CREATE OR REPLACE TABLE pairs_portfolio AS
SELECT
    trade_date,
    AVG(gross_pnl)        AS gross_ret,
    AVG(gross_pnl - cost) AS net_ret
FROM pairs_daily
GROUP BY trade_date
ORDER BY trade_date;

CREATE OR REPLACE TABLE pairs_performance AS
SELECT
    COUNT(*)                                          AS n_days,
    EXP(SUM(LN(1 + net_ret))) - 1                     AS total_net_return,
    AVG(gross_ret) * 252                              AS ann_ret_gross,
    AVG(net_ret) * 252                                AS ann_ret_net,
    STDDEV_SAMP(net_ret) * SQRT(252)                  AS ann_vol,
    AVG(net_ret) / STDDEV_SAMP(net_ret) * SQRT(252)   AS sharpe_net,
    CORR(p.net_ret, m.mkt_ret)                        AS corr_to_market
FROM pairs_portfolio p
JOIN market_daily m USING (trade_date);
