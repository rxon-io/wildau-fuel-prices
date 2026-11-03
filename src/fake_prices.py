"""
TEST DATA ONLY: made-up price changes for the two Wildau stations.

Used to develop and test the sales generator until the real Tankerkönig data arrives.
The output has the same columns as the real prices after cleaning, so the rest of the
pipeline does not change when the real data replaces it.

Rough shape of the fake prices:
- before 1 April 2026: several changes a day, expensive in the morning, cheapest around 19-20 h;
- from 1 April 2026 (the "12-Uhr-Regel"): one increase a day at 12:00, then only decreases.

Usage:
    python src/fake_prices.py --out data/fake_prices.csv
"""

import argparse

import numpy as np
import pandas as pd

TZ = "Europe/Berlin"
REFORM_DAY = pd.Timestamp("2026-04-01").date()

BASE_PRICE = {"e5": 1.78, "e10": 1.72, "diesel": 1.68}   # EUR per litre, rough 2025/26 level
STATION_OFFSET = {"shell": 0.015, "sprint": 0.0}          # Shell a bit more expensive

# (local hour, offset from the day's price level in EUR)
SCHEDULE_BEFORE = [(5.0, 0.08), (7.5, 0.06), (9.0, 0.04), (10.5, 0.02), (12.0, 0.06),
                   (13.5, 0.03), (15.0, 0.01), (17.0, 0.04), (18.0, 0.01), (19.0, -0.03),
                   (20.5, -0.02), (22.0, 0.05)]
# After the reform the morning decrease continues yesterday's level; the only increase is at 12:00.
SCHEDULE_AFTER = [(6.0, -0.03, "yesterday"), (12.0, 0.07, "today"), (13.0, 0.05, "today"),
                  (14.5, 0.035, "today"), (16.0, 0.02, "today"), (17.5, 0.0, "today"),
                  (19.0, -0.01, "today"), (21.0, -0.02, "today")]


def to_pump_price(x: float) -> float:
    """German pump prices end in 9 tenths of a cent, e.g. 1.789."""
    return round(np.floor(x * 100) / 100 + 0.009, 3)


def make_prices(start: str, end: str, seed: int) -> pd.DataFrame:
    rng = np.random.default_rng(seed)
    days = pd.date_range(start, end, freq="D", inclusive="left")

    # One shared daily price level per fuel: a mean-reverting random walk
    level = {}
    for fuel, base in BASE_PRICE.items():
        walk = np.zeros(len(days))
        for i in range(1, len(days)):
            walk[i] = 0.97 * walk[i - 1] + rng.normal(0, 0.012)
        level[fuel] = base + walk

    rows = []
    for station, offset in STATION_OFFSET.items():
        for fuel in BASE_PRICE:
            for i, day in enumerate(days):
                if day.date() < REFORM_DAY:
                    changes = [(h, level[fuel][i] + d) for h, d in SCHEDULE_BEFORE]
                else:
                    changes = [(h, (level[fuel][i - 1] if which == "yesterday" and i > 0 else level[fuel][i]) + d)
                               for h, d, which in SCHEDULE_AFTER]
                for hour, price in changes:
                    jitter_min = 0 if (day.date() >= REFORM_DAY and hour == 12.0) else rng.integers(-20, 21)
                    local = day + pd.Timedelta(hours=hour) + pd.Timedelta(minutes=int(jitter_min))
                    local = local + pd.Timedelta(seconds=int(rng.integers(0, 60)))
                    rows.append((station, fuel, local, to_pump_price(price + offset)))

    df = pd.DataFrame(rows, columns=["station", "fuel", "valid_from_local", "price_eur"])
    df["valid_from_utc"] = (df["valid_from_local"].dt.tz_localize(TZ, ambiguous="NaT", nonexistent="NaT")
                            .dt.tz_convert("UTC").dt.tz_localize(None))
    df = df.dropna(subset=["valid_from_utc"]).sort_values(["station", "fuel", "valid_from_utc"])
    # Keep only real changes (same price twice in a row is not a change)
    df = df[df.groupby(["station", "fuel"])["price_eur"].diff().ne(0)]
    return df[["station", "fuel", "valid_from_utc", "price_eur"]].reset_index(drop=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--start", default="2025-10-31", help="first local day (one day before the analysis period)")
    parser.add_argument("--end", default="2026-11-01", help="local day after the last day")
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--out", default="data/fake_prices.csv")
    args = parser.parse_args()

    prices = make_prices(args.start, args.end, args.seed)
    prices.to_csv(args.out, index=False, date_format="%Y-%m-%d %H:%M:%S", lineterminator="\n")
    print(f"{len(prices):,} fake price changes written to {args.out}")


if __name__ == "__main__":
    main()
