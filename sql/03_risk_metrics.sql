-- =============================================================================
-- 03_risk_metrics.sql
-- Per-stock risk/return statistics over the full sample, plus rolling
-- (time-varying) volatility and beta.
-- Risk-free rate is taken as 0: US T-bill yields averaged < 1% over 2013-2017.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Rolling 63-day (~3 month) volatility and 252-day (~1 year) beta, computed
-- with window aggregates. A value is only reported once the window is full.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE rolling_risk AS
WITH x AS (
    SELECT d.ticker, d.trade_date, d.ret, m.mkt_ret
    FROM daily_returns d
    JOIN market_daily m USING (trade_date)
    WHERE d.ret IS NOT NULL
)
SELECT
    ticker,
    trade_date,
    CASE WHEN COUNT(ret) OVER w63 = 63
         THEN STDDEV_SAMP(ret) OVER w63 * SQRT(252) END              AS vol_63d,
    CASE WHEN COUNT(ret) OVER w252 = 252
         THEN REGR_SLOPE(ret, mkt_ret) OVER w252 END                 AS beta_252d
FROM x
WINDOW
    w63  AS (PARTITION BY ticker ORDER BY trade_date ROWS BETWEEN 62  PRECEDING AND CURRENT ROW),
    w252 AS (PARTITION BY ticker ORDER BY trade_date ROWS BETWEEN 251 PRECEDING AND CURRENT ROW);

-- -----------------------------------------------------------------------------
-- Full-sample statistics per stock (stocks with >= 1 year of clean returns)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE stock_risk AS
WITH x AS (
    SELECT d.ticker, d.trade_date, d.ret, m.mkt_ret
    FROM daily_returns d
    JOIN market_daily m USING (trade_date)
    WHERE d.ret IS NOT NULL
),
eligible AS (
    SELECT ticker FROM x GROUP BY ticker HAVING COUNT(*) >= 252
),
-- wealth path of $1 invested, and its running peak -> drawdown
wealth AS (
    SELECT
        ticker, trade_date,
        EXP(SUM(LN(1 + ret)) OVER (PARTITION BY ticker ORDER BY trade_date)) AS wealth
    FROM x
    WHERE ticker IN (SELECT ticker FROM eligible)
),
drawdown AS (
    SELECT
        ticker,
        MIN(wealth / GREATEST(1.0, peak) - 1) AS max_drawdown
    FROM (
        SELECT ticker, wealth,
               MAX(wealth) OVER (PARTITION BY ticker ORDER BY trade_date) AS peak
        FROM wealth
    )
    GROUP BY ticker
),
var AS (
    SELECT ticker, QUANTILE_CONT(ret, 0.05) AS q05
    FROM x GROUP BY ticker
),
stats AS (
    SELECT
        x.ticker,
        COUNT(*)                                             AS n_days,
        MIN(trade_date)                                      AS first_date,
        MAX(trade_date)                                      AS last_date,
        EXP(AVG(LN(1 + ret)) * 252) - 1                      AS ann_return,
        STDDEV_SAMP(ret) * SQRT(252)                         AS ann_vol,
        AVG(ret) / STDDEV_SAMP(ret) * SQRT(252)              AS sharpe,
        -- Sortino: only penalise downside deviation
        AVG(ret) / SQRT(AVG(POW(LEAST(ret, 0), 2))) * SQRT(252) AS sortino,
        REGR_SLOPE(ret, mkt_ret)                             AS beta,
        CORR(ret, mkt_ret)                                   AS corr_mkt,
        -- idiosyncratic (stock-specific) vol = total vol * sqrt(1 - R^2)
        STDDEV_SAMP(ret) * SQRT(252) * SQRT(1 - POW(CORR(ret, mkt_ret), 2)) AS idio_vol,
        -- alpha: annualised intercept of the market-model regression
        REGR_INTERCEPT(ret, mkt_ret) * 252                   AS alpha_ann,
        -MAX(v.q05)                                          AS var_95_1d,
        -AVG(ret) FILTER (WHERE ret <= v.q05)                AS cvar_95_1d,
        SKEWNESS(ret)                                        AS skew,
        KURTOSIS(ret)                                        AS excess_kurtosis
    FROM x
    JOIN var v USING (ticker)
    WHERE x.ticker IN (SELECT ticker FROM eligible)
    GROUP BY x.ticker
)
SELECT s.*, d.max_drawdown
FROM stats s
JOIN drawdown d USING (ticker)
ORDER BY sharpe DESC;

-- -----------------------------------------------------------------------------
-- Same statistics for the equal-weighted market index
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE market_risk AS
WITH w AS (
    SELECT trade_date, mkt_ret,
           EXP(SUM(LN(1 + mkt_ret)) OVER (ORDER BY trade_date)) AS wealth
    FROM market_daily
)
SELECT
    COUNT(*)                                  AS n_days,
    EXP(AVG(LN(1 + mkt_ret)) * 252) - 1       AS ann_return,
    STDDEV_SAMP(mkt_ret) * SQRT(252)          AS ann_vol,
    AVG(mkt_ret) / STDDEV_SAMP(mkt_ret) * SQRT(252) AS sharpe,
    -QUANTILE_CONT(mkt_ret, 0.05)             AS var_95_1d,
    SKEWNESS(mkt_ret)                         AS skew,
    KURTOSIS(mkt_ret)                         AS excess_kurtosis,
    MIN(wealth / GREATEST(1.0, peak) - 1)     AS max_drawdown
FROM (SELECT *, MAX(wealth) OVER (ORDER BY trade_date) AS peak FROM w);

-- -----------------------------------------------------------------------------
-- Does low-beta / low-vol mean low return? Bucket stocks into beta quintiles.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE risk_buckets AS
SELECT
    NTILE(5) OVER (ORDER BY beta) AS beta_quintile,
    *
FROM stock_risk;

CREATE OR REPLACE TABLE beta_quintile_summary AS
SELECT
    beta_quintile,
    COUNT(*)                   AS n_stocks,
    ROUND(AVG(beta), 2)        AS avg_beta,
    ROUND(AVG(ann_return), 4)  AS avg_ann_return,
    ROUND(AVG(ann_vol), 4)     AS avg_ann_vol,
    ROUND(AVG(sharpe), 2)      AS avg_sharpe,
    ROUND(AVG(max_drawdown), 4) AS avg_max_drawdown
FROM risk_buckets
GROUP BY beta_quintile
ORDER BY beta_quintile;
