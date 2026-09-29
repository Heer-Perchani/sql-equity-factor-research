-- =============================================================================
-- 99_validation.sql
-- Automated sanity checks. run.py fails loudly if any check does not pass.
-- =============================================================================

CREATE OR REPLACE TABLE validation_checks AS
SELECT 'no duplicate (ticker, date) rows' AS check_name,
       (SELECT COUNT(*) - COUNT(DISTINCT (ticker, trade_date)) FROM raw_prices) = 0 AS passed
UNION ALL
SELECT 'no daily return beyond +/-100% after cleaning',
       (SELECT COUNT(*) FROM daily_returns WHERE ABS(ret) >= 1.0) = 0
UNION ALL
SELECT 'known spin-offs removed (EBAY 2015-07-20 return is NULL)',
       (SELECT ret IS NULL FROM daily_returns WHERE ticker = 'EBAY' AND trade_date = DATE '2015-07-20')
UNION ALL
SELECT 'market index has >= 400 stocks every day',
       (SELECT MIN(n_stocks) FROM market_daily) >= 400
UNION ALL
SELECT 'no look-ahead: holding month is always after formation month',
       (SELECT COUNT(*) FROM factor_scores WHERE holding_month <= formation_month) = 0
UNION ALL
SELECT 'long leg weights sum to +1 and short leg to -1 every month',
       (SELECT MAX(ABS(s)) FROM (
            SELECT SUM(weight) FILTER (WHERE weight > 0) - 1 AS s FROM ls_weights GROUP BY factor, formation_month
            UNION ALL
            SELECT SUM(weight) FILTER (WHERE weight < 0) + 1 FROM ls_weights GROUP BY factor, formation_month
       )) < 1e-9
UNION ALL
SELECT 'each quintile holds >= 80 stocks',
       (SELECT MIN(n_stocks) FROM quintile_returns) >= 80
UNION ALL
-- $1 long + $1 short = $2 gross; flipping every name from long to short = 4
SELECT 'turnover is between 0 and 4 (every name flips side = 4)',
       (SELECT MIN(turnover) >= 0 AND MAX(turnover) <= 4 + 1e-9 FROM ls_turnover)
UNION ALL
SELECT 'long-short gross return = long leg - short leg',
       (SELECT MAX(ABS(gross_ret - (long_ret - short_leg_ret))) FROM ls_returns) < 1e-12
UNION ALL
SELECT 'pairs z-scores use formation data only (trading starts after formation_end)',
       (SELECT MIN(trade_date) FROM pairs_daily) > (SELECT formation_end FROM pairs_params)
UNION ALL
SELECT 'no NULL or non-finite strategy returns',
       (SELECT COUNT(*) FROM ls_returns WHERE net_ret IS NULL OR NOT ISFINITE(net_ret)) = 0;
