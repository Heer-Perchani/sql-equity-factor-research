-- =============================================================================
-- 05_backtest.sql
-- Monthly-rebalanced, equal-weighted quintile portfolios for every factor,
-- a dollar-neutral long-short (Q5 - Q1) strategy, turnover and transaction
-- costs, and performance statistics.
--
-- Timing: scores are formed at the close of formation_month and the positions
-- earn holding_month's return, so no future information is used.
-- Simplification: weights are reset to equal at each rebalance and intra-month
-- weight drift is ignored when computing turnover.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Average next-month return of each quintile
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE quintile_returns AS
SELECT
    factor,
    formation_month,
    holding_month,
    quintile,
    COUNT(*)      AS n_stocks,
    AVG(fwd_ret)  AS port_ret
FROM factor_scores
GROUP BY factor, formation_month, holding_month, quintile;

-- Annualised mean return per quintile, pivoted Q1..Q5 (a good factor is monotonic)
CREATE OR REPLACE TABLE quintile_spread_table AS
PIVOT (
    SELECT factor, 'Q' || quintile AS q, AVG(port_ret) * 12 AS ann_ret
    FROM quintile_returns
    GROUP BY factor, quintile
)
ON q IN ('Q1', 'Q2', 'Q3', 'Q4', 'Q5')
USING FIRST(ann_ret)
ORDER BY factor;

-- -----------------------------------------------------------------------------
-- Portfolio weights: +1/N on each Q5 stock, -1/N on each Q1 stock
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE ls_weights AS
SELECT
    factor,
    formation_month,
    ticker,
    CASE quintile
        WHEN 5 THEN  1.0 / COUNT(*) OVER (PARTITION BY factor, formation_month, quintile)
        WHEN 1 THEN -1.0 / COUNT(*) OVER (PARTITION BY factor, formation_month, quintile)
    END AS weight,
    fwd_ret
FROM factor_scores
WHERE quintile IN (1, 5);

-- -----------------------------------------------------------------------------
-- Turnover: sum of |w_t - w_{t-1}| across stocks. A FULL OUTER JOIN catches
-- names that entered (no previous weight) and names that exited (no new one).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE ls_turnover AS
WITH months AS (
    SELECT DISTINCT factor, formation_month,
           LAG(formation_month) OVER (PARTITION BY factor ORDER BY formation_month) AS prev_month
    FROM (SELECT DISTINCT factor, formation_month FROM ls_weights)
),
cur AS (
    SELECT w.factor, w.formation_month, m.prev_month, w.ticker, w.weight
    FROM ls_weights w JOIN months m USING (factor, formation_month)
),
prev AS (
    SELECT m.factor, m.formation_month, w.ticker, w.weight
    FROM months m
    JOIN ls_weights w ON w.factor = m.factor AND w.formation_month = m.prev_month
)
SELECT
    COALESCE(c.factor, p.factor)                   AS factor,
    COALESCE(c.formation_month, p.formation_month) AS formation_month,
    SUM(ABS(COALESCE(c.weight, 0) - COALESCE(p.weight, 0))) AS turnover
FROM cur c
FULL OUTER JOIN prev p
  ON c.factor = p.factor AND c.formation_month = p.formation_month AND c.ticker = p.ticker
GROUP BY 1, 2;

-- -----------------------------------------------------------------------------
-- Long-short returns, gross and net of costs
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE ls_returns AS
SELECT
    w.factor,
    w.formation_month,
    MIN(q.holding_month)                                   AS holding_month,
    SUM(w.weight * w.fwd_ret) FILTER (WHERE w.weight > 0)  AS long_ret,
    -SUM(w.weight * w.fwd_ret) FILTER (WHERE w.weight < 0) AS short_leg_ret,
    SUM(w.weight * w.fwd_ret)                              AS gross_ret,
    MAX(t.turnover)                                        AS turnover,
    MAX(t.turnover) * MAX(p.cost_bps) / 10000              AS cost,
    SUM(w.weight * w.fwd_ret) - MAX(t.turnover) * MAX(p.cost_bps) / 10000 AS net_ret
FROM ls_weights w
JOIN ls_turnover t USING (factor, formation_month)
JOIN (SELECT DISTINCT factor, formation_month, holding_month FROM quintile_returns) q
  USING (factor, formation_month)
CROSS JOIN params p
GROUP BY w.factor, w.formation_month;

-- Cumulative equity curves ($1 invested) for charting
CREATE OR REPLACE TABLE ls_equity_curve AS
SELECT
    factor,
    holding_month,
    gross_ret,
    net_ret,
    EXP(SUM(LN(1 + gross_ret)) OVER w) AS cum_gross,
    EXP(SUM(LN(1 + net_ret))   OVER w) AS cum_net
FROM ls_returns
WINDOW w AS (PARTITION BY factor ORDER BY holding_month);

-- -----------------------------------------------------------------------------
-- Performance summary (monthly data, annualised with 12 periods/year)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE factor_performance AS
WITH dd AS (
    SELECT factor,
           MIN(cum_net / GREATEST(1.0, peak) - 1) AS max_drawdown
    FROM (SELECT *, MAX(cum_net) OVER (PARTITION BY factor ORDER BY holding_month) AS peak
          FROM ls_equity_curve)
    GROUP BY factor
),
mkt AS (
    SELECT r.factor, CORR(r.net_ret, m.mkt_ret_m) AS corr_to_market
    FROM ls_returns r
    JOIN market_monthly m ON m.month = r.holding_month
    GROUP BY r.factor
)
SELECT
    r.factor,
    COUNT(*)                                           AS n_months,
    MIN(r.holding_month)                               AS first_month,
    MAX(r.holding_month)                               AS last_month,
    AVG(r.gross_ret) * 12                              AS ann_ret_gross,
    AVG(r.net_ret) * 12                                AS ann_ret_net,
    STDDEV_SAMP(r.net_ret) * SQRT(12)                  AS ann_vol,
    AVG(r.gross_ret) / STDDEV_SAMP(r.gross_ret) * SQRT(12) AS sharpe_gross,
    AVG(r.net_ret) / STDDEV_SAMP(r.net_ret) * SQRT(12) AS sharpe_net,
    AVG(r.net_ret) / (STDDEV_SAMP(r.net_ret) / SQRT(COUNT(*))) AS t_stat_net,
    AVG(CASE WHEN r.net_ret > 0 THEN 1.0 ELSE 0.0 END) AS hit_rate,
    AVG(r.turnover)                                    AS avg_monthly_turnover,
    MAX(d.max_drawdown)                                AS max_drawdown,
    MAX(m.corr_to_market)                              AS corr_to_market
FROM ls_returns r
JOIN dd  d USING (factor)
JOIN mkt m USING (factor)
GROUP BY r.factor
ORDER BY sharpe_net DESC;
