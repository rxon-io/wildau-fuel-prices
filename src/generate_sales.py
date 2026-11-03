"""
Simulated sales for the two Wildau fuel stations, driven by the real price history.

The prices are real (Tankerkönig / MTS-K). The sales are NOT: no station publishes its
transactions, so they are generated from the rules below. Every rule is a parameter in
this file; numbers marked "source" come from published statistics, the rest are assumptions.

1. Volume: about 250 fills per station and day (~10,000 l). Source: average German station
   sold 3,736 m3 in 2022 (Tankstellenstudie 2022).
2. Time of day: peaks at 7-9 and 16-19 on working days, later and flatter at weekends and on
   public holidays in Brandenburg. Assumption.
3. Fuel mix: 35 % of fills are diesel (assumption). Of the petrol fills, E10 is 29 % before
   April 2026 and 35 % from April 2026 (source: BDBe market data 2025 and press release 2026).
4. Price response: in hours when a fuel is cheaper than its daily average, more people fill up
   (DAY_ALPHA), and customers lean towards the cheaper of the two stations (STATION_BETA).
   Assumption: this is what links the simulated sales to the real prices.
5. Litres per fill: log-normal, median 35 l for petrol and 45 l for diesel, 5-150 l. Assumption.
6. Payment: card / cash / fuel card, fuel cards mostly for diesel. Assumption.
7. Each sale gets the price that was valid at its exact second, like dbo.pr_record_sale.

Input:  prices CSV with columns station, fuel, valid_from_utc, price_eur
Output: sales CSV with columns station, fuel, payment_method, sold_at_utc, liters, price_eur

Usage:
    python src/generate_sales.py --prices data/fake_prices.csv --out data/sales.csv
"""

import argparse

import numpy as np
import pandas as pd

TZ = "Europe/Berlin"
REFORM_DAY = pd.Timestamp("2026-04-01").date()   # "12-Uhr-Regel": price increases only at 12:00

FILLS_PER_DAY = {"shell": 250, "sprint": 250}

# Relative weight of each local hour 0..23 (normalised below)
HOUR_WEIGHTS_WORKDAY = [0.4, 0.3, 0.2, 0.2, 0.3, 0.8, 2.2, 3.8, 4.5, 3.6, 3.2, 3.4,
                        3.8, 3.6, 3.7, 4.2, 5.0, 5.4, 4.8, 3.8, 2.8, 2.0, 1.4, 0.8]
HOUR_WEIGHTS_WEEKEND = [0.6, 0.5, 0.3, 0.2, 0.2, 0.4, 0.8, 1.6, 2.8, 3.8, 4.6, 5.0,
                        5.0, 4.8, 4.6, 4.6, 4.6, 4.4, 4.0, 3.4, 2.6, 1.9, 1.3, 0.9]

# Day-of-week factor (Mon=0 .. Sun=6); public holidays count as Sunday
WEEKDAY_FACTOR = [1.0, 1.0, 1.0, 1.0, 1.1, 0.95, 0.8]
# Month factor: a little less in winter, a little more in the summer holidays
MONTH_FACTOR = {1: 0.92, 2: 0.94, 3: 0.98, 4: 1.0, 5: 1.02, 6: 1.04,
                7: 1.06, 8: 1.06, 9: 1.02, 10: 1.0, 11: 0.97, 12: 0.95}

# Public holidays in Brandenburg, Nov 2025 - Oct 2026
HOLIDAYS = pd.to_datetime([
    "2025-12-25", "2025-12-26", "2026-01-01", "2026-04-03", "2026-04-05", "2026-04-06",
    "2026-05-01", "2026-05-14", "2026-05-24", "2026-05-25", "2026-10-03", "2026-10-31",
]).date

DIESEL_SHARE = 0.35
E10_SHARE_OF_PETROL_BEFORE = 0.29
E10_SHARE_OF_PETROL_AFTER = 0.35

DAY_ALPHA = 0.03      # per cent below the daily average: exp(0.03 * 10 ct) = 1.35x more fills
STATION_BETA = 0.05   # per cent price difference between the stations

LITERS_MEDIAN = {"e5": 35.0, "e10": 35.0, "diesel": 45.0}
LITERS_SIGMA = {"e5": 0.35, "e10": 0.35, "diesel": 0.40}

PAYMENT_METHODS = ["Card", "Cash", "Fuel card"]
PAYMENT_PROBS = {"e5": [0.62, 0.33, 0.05], "e10": [0.62, 0.33, 0.05], "diesel": [0.55, 0.25, 0.20]}


def load_prices(path: str) -> pd.DataFrame:
    prices = pd.read_csv(path, parse_dates=["valid_from_utc"])
    return prices.sort_values("valid_from_utc").reset_index(drop=True)


def price_at(prices: pd.DataFrame, events: pd.DataFrame, time_col: str) -> pd.Series:
    """Price valid at each event time for the event's station and fuel (as-of join)."""
    merged = pd.merge_asof(
        events.reset_index().sort_values(time_col),
        prices.rename(columns={"valid_from_utc": time_col}),
        on=time_col, by=["station", "fuel"], direction="backward",
    )
    return merged.set_index("index")["price_eur"].reindex(events.index)


def expected_fills(prices: pd.DataFrame, start: str, end: str) -> pd.DataFrame:
    """Expected number of fills per station, fuel and hour."""
    hours = pd.date_range(pd.Timestamp(start, tz=TZ), pd.Timestamp(end, tz=TZ),
                          freq="h", inclusive="left").tz_convert("UTC").tz_localize(None)
    grid = pd.MultiIndex.from_product([FILLS_PER_DAY.keys(), ["e5", "e10", "diesel"], hours],
                                      names=["station", "fuel", "hour_utc"]).to_frame(index=False)

    # Price in the middle of each hour
    grid["mid_utc"] = grid["hour_utc"] + pd.Timedelta(minutes=30)
    grid["price"] = price_at(prices, grid, "mid_utc")

    local = grid["hour_utc"].dt.tz_localize("UTC").dt.tz_convert(TZ)
    grid["local_date"] = local.dt.date
    grid["local_hour"] = local.dt.hour
    is_holiday = grid["local_date"].isin(HOLIDAYS)
    weekday = np.where(is_holiday, 6, local.dt.day_of_week)
    weekend = weekday >= 5

    w_work = np.array(HOUR_WEIGHTS_WORKDAY) / sum(HOUR_WEIGHTS_WORKDAY)
    w_end = np.array(HOUR_WEIGHTS_WEEKEND) / sum(HOUR_WEIGHTS_WEEKEND)
    hour_share = np.where(weekend, w_end[grid["local_hour"]], w_work[grid["local_hour"]])

    after_reform = grid["local_date"] >= REFORM_DAY
    e10 = np.where(after_reform, E10_SHARE_OF_PETROL_AFTER, E10_SHARE_OF_PETROL_BEFORE)
    fuel_share = np.select([grid["fuel"] == "diesel", grid["fuel"] == "e10"],
                           [DIESEL_SHARE, (1 - DIESEL_SHARE) * e10],
                           (1 - DIESEL_SHARE) * (1 - e10))

    # Rule 4a: cheaper than the day's average -> more fills
    day_mean = grid.groupby(["station", "fuel", "local_date"])["price"].transform("mean")
    day_effect = np.exp(-DAY_ALPHA * (grid["price"] - day_mean) * 100)

    # Rule 4b: customers lean towards the cheaper station (factor 1 when prices are equal)
    attract = np.exp(-STATION_BETA * grid["price"] * 100)
    n_open = grid.groupby(["fuel", "hour_utc"])["price"].transform("count")
    station_effect = n_open * attract / attract.groupby([grid["fuel"], grid["hour_utc"]]).transform("sum")

    base = grid["station"].map(FILLS_PER_DAY)
    month = local.dt.month.map(MONTH_FACTOR)
    grid["expected"] = (base * hour_share * np.array(WEEKDAY_FACTOR)[weekday] * month
                        * fuel_share * day_effect * station_effect).fillna(0)
    return grid[["station", "fuel", "hour_utc", "expected"]]


def generate(prices: pd.DataFrame, start: str, end: str, seed: int) -> pd.DataFrame:
    rng = np.random.default_rng(seed)
    grid = expected_fills(prices, start, end)

    counts = rng.poisson(grid["expected"].to_numpy())
    sales = grid.loc[grid.index.repeat(counts), ["station", "fuel", "hour_utc"]].reset_index(drop=True)
    sales["sold_at_utc"] = sales["hour_utc"] + pd.to_timedelta(rng.integers(0, 3600, len(sales)), unit="s")

    # Rule 7: the price valid at the exact second of the sale
    sales["price_eur"] = price_at(prices, sales, "sold_at_utc")
    sales = sales.dropna(subset=["price_eur"]).reset_index(drop=True)

    median = sales["fuel"].map(LITERS_MEDIAN)
    sigma = sales["fuel"].map(LITERS_SIGMA)
    sales["liters"] = np.clip(median * np.exp(sigma * rng.standard_normal(len(sales))), 5, 150).round(2)

    sales["payment_method"] = ""
    for fuel, probs in PAYMENT_PROBS.items():
        mask = sales["fuel"] == fuel
        sales.loc[mask, "payment_method"] = rng.choice(PAYMENT_METHODS, size=mask.sum(), p=probs)

    sales = sales.sort_values("sold_at_utc").reset_index(drop=True)
    return sales[["station", "fuel", "payment_method", "sold_at_utc", "liters", "price_eur"]]


def summary(sales: pd.DataFrame) -> None:
    days = sales["sold_at_utc"].dt.tz_localize("UTC").dt.tz_convert(TZ).dt.date.nunique()
    amount = (sales["liters"] * sales["price_eur"]).round(2)
    print(f"{len(sales):,} sales over {days} days")
    print("Fills per station and day:", (sales.groupby("station").size() / days).round(0).to_dict())
    print("Litres per station and day:", (sales.groupby("station")["liters"].sum() / days).round(0).to_dict())
    print("Fuel mix (% of fills):", (sales["fuel"].value_counts(normalize=True) * 100).round(1).to_dict())
    print("Payment mix (% of fills):", (sales["payment_method"].value_counts(normalize=True) * 100).round(1).to_dict())
    print(f"Revenue: {amount.sum():,.0f} EUR, average fill {amount.mean():.2f} EUR")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--prices", required=True, help="CSV: station, fuel, valid_from_utc, price_eur")
    parser.add_argument("--out", default="data/sales.csv")
    parser.add_argument("--start", default="2025-11-01", help="first local day")
    parser.add_argument("--end", default="2026-11-01", help="local day after the last day")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    sales = generate(load_prices(args.prices), args.start, args.end, args.seed)
    sales.to_csv(args.out, index=False, date_format="%Y-%m-%d %H:%M:%S", lineterminator="\n")
    summary(sales)
    print(f"Written to {args.out}")


if __name__ == "__main__":
    main()
