"""Run the full SQL pipeline end to end.

    python run.py

1. Downloads the Kaggle S&P 500 dataset (camnugent/sandp500) if needed.
2. Executes every file in sql/ in order against a DuckDB database file.
3. Fails if any validation check does not pass.
4. Exports result tables to results/*.csv and charts to results/*.png.
"""

import shutil
import sys
import time
from pathlib import Path

import duckdb
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data" / "all_stocks_5yr.csv"
DB = ROOT / "quant.duckdb"
SQL_DIR = ROOT / "sql"
RESULTS = ROOT / "results"

# Validated categorical palette (fixed slot order) + neutral inks
SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4"]
INK, INK_2, GRID = "#0b0b0b", "#52514e", "#e4e3df"
ORDINAL_BLUE = ["#86b6ef", "#5598e7", "#2a78d6", "#1c5cab", "#184f95"]

EXPORTS = [
    "dq_report", "dq_overridden_returns", "market_risk", "stock_risk",
    "beta_quintile_summary", "factor_ic_summary", "quintile_spread_table",
    "factor_performance", "ls_returns", "selected_pairs", "pairs_summary",
    "pairs_performance", "overnight_intraday_summary", "day_of_week_effect",
    "turn_of_month_effect", "validation_checks",
]


def ensure_data() -> None:
    if DATA.exists():
        return
    import kagglehub

    print("Downloading camnugent/sandp500 from Kaggle ...")
    src = Path(kagglehub.dataset_download("camnugent/sandp500")) / "all_stocks_5yr.csv"
    DATA.parent.mkdir(exist_ok=True)
    shutil.copy(src, DATA)


def run_sql(con: duckdb.DuckDBPyConnection) -> None:
    for path in sorted(SQL_DIR.glob("*.sql")):
        t0 = time.perf_counter()
        con.execute(path.read_text())
        print(f"  {path.name:<28} {time.perf_counter() - t0:6.2f}s")


def validate(con: duckdb.DuckDBPyConnection) -> None:
    failed = con.sql("SELECT check_name FROM validation_checks WHERE NOT passed").fetchall()
    n = con.sql("SELECT COUNT(*) FROM validation_checks").fetchone()[0]
    if failed:
        sys.exit("Validation FAILED:\n  " + "\n  ".join(r[0] for r in failed))
    print(f"  all {n} validation checks passed")


def style(ax, title: str, ylabel: str) -> None:
    ax.set_title(title, loc="left", color=INK, fontsize=12, fontweight="bold", pad=12)
    ax.set_ylabel(ylabel, color=INK_2)
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color(INK_2)
    ax.tick_params(colors=INK_2, length=0)


def chart_equity_curves(con) -> None:
    df = con.sql("""
        SELECT factor, holding_month, cum_net FROM ls_equity_curve ORDER BY factor, holding_month
    """).fetchall()
    order = [r[0] for r in con.sql("SELECT factor FROM factor_performance ORDER BY sharpe_net DESC").fetchall()]
    fig, ax = plt.subplots(figsize=(10, 5.5))
    for i, f in enumerate(order):
        pts = [(m, v) for fac, m, v in df if fac == f]
        xs, ys = zip(*pts)
        ax.plot(xs, ys, color=SERIES[i], linewidth=2, label=f)
        ax.annotate(f, (xs[-1], ys[-1]), xytext=(6, 0), textcoords="offset points",
                    va="center", fontsize=9, color=INK_2)
    ax.axhline(1.0, color=INK_2, linewidth=0.8)
    style(ax, "Long-short factor portfolios, growth of $1 (net of 10 bps costs)", "Growth of $1")
    ax.legend(frameon=False, loc="upper left", fontsize=9, labelcolor=INK_2)
    ax.margins(x=0.12)
    fig.tight_layout()
    fig.savefig(RESULTS / "factor_equity_curves.png", dpi=150)
    plt.close(fig)


def chart_quintiles(con) -> None:
    rows = con.sql("SELECT factor, Q1, Q2, Q3, Q4, Q5 FROM quintile_spread_table ORDER BY factor").fetchall()
    fig, axes = plt.subplots(1, len(rows), figsize=(12, 3.8), sharey=True)
    for ax, (factor, *q) in zip(axes, rows):
        ax.bar(["Q1", "Q2", "Q3", "Q4", "Q5"], [v * 100 for v in q], color=ORDINAL_BLUE,
               width=0.72, edgecolor="white", linewidth=2)
        style(ax, factor, "")
        ax.title.set_fontsize(10)
    axes[0].set_ylabel("Annualised return (%)", color=INK_2)
    fig.suptitle("Next-month return by factor quintile (Q5 = predicted winners)",
                 x=0.01, ha="left", color=INK, fontweight="bold")
    fig.tight_layout()
    fig.savefig(RESULTS / "quintile_returns.png", dpi=150)
    plt.close(fig)


def chart_overnight(con) -> None:
    rows = con.sql("""
        SELECT trade_date, cum_close_to_close, cum_overnight, cum_intraday
        FROM overnight_intraday ORDER BY trade_date
    """).fetchall()
    d, cc, on, intra = zip(*rows)
    fig, ax = plt.subplots(figsize=(10, 5))
    for ys, name, col in [(cc, "close-to-close", SERIES[0]),
                          (on, "overnight only", SERIES[1]),
                          (intra, "intraday only", SERIES[2])]:
        ax.plot(d, ys, color=col, linewidth=2, label=name)
        ax.annotate(name, (d[-1], ys[-1]), xytext=(6, 0), textcoords="offset points",
                    va="center", fontsize=9, color=INK_2)
    ax.axhline(1.0, color=INK_2, linewidth=0.8)
    style(ax, "Equal-weighted S&P 500: where are returns earned?", "Growth of $1")
    ax.legend(frameon=False, loc="upper left", fontsize=9, labelcolor=INK_2)
    ax.margins(x=0.14)
    fig.tight_layout()
    fig.savefig(RESULTS / "overnight_vs_intraday.png", dpi=150)
    plt.close(fig)


def main() -> None:
    ensure_data()
    RESULTS.mkdir(exist_ok=True)
    DB.unlink(missing_ok=True)
    con = duckdb.connect(str(DB))

    print("Running SQL pipeline:")
    run_sql(con)
    validate(con)

    for t in EXPORTS:
        con.sql(f"SELECT * FROM {t}").write_csv(str(RESULTS / f"{t}.csv"))
    chart_equity_curves(con)
    chart_quintiles(con)
    chart_overnight(con)
    print(f"  exported {len(EXPORTS)} tables + 3 charts to results/")

    print("\nFactor backtest (long Q5 / short Q1, monthly, net of costs):")
    print(con.sql("""
        SELECT factor,
               ROUND(ann_ret_gross * 100, 2) AS gross_pct,
               ROUND(ann_ret_net * 100, 2)   AS net_pct,
               ROUND(sharpe_net, 2)          AS sharpe,
               ROUND(t_stat_net, 2)          AS t_stat,
               ROUND(avg_monthly_turnover, 2) AS turnover,
               ROUND(max_drawdown * 100, 1)  AS max_dd_pct
        FROM factor_performance
    """))


if __name__ == "__main__":
    main()
