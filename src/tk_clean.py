"""
Turn the downloaded daily Tankerkönig files into clean price changes.

Input:  data/raw/wildau/YYYY-MM-DD.csv  (one row per change, current prices of all three fuels)
        data/raw/wildau/stations.csv
Output: data/prices.csv    station, fuel, valid_from_utc, price_eur  (same format as fake_prices.csv)
        data/stations.csv  station key, Tankerkönig uuid and address, for the database

Cleaning rules:
1. Each source row holds the current price of all three fuels. It is split into one row per fuel.
2. Prices <= 0 mean "no valid price" (fuel not sold or reported as removed) and are dropped.
3. Rows where the price of a fuel did not change are dropped: only real changes remain.
4. Timestamps carry their UTC offset (+01 in winter, +02 in summer) and are converted to UTC.

Usage:
    python src/tk_clean.py
"""

from pathlib import Path

import pandas as pd

RAW_DIR = Path("data/raw/wildau")
FUELS = ["e5", "e10", "diesel"]


def main() -> None:
    files = sorted(RAW_DIR.glob("20*.csv"))
    raw = pd.concat((pd.read_csv(f, dtype=str) for f in files), ignore_index=True)
    print(f"{len(files)} daily files, {len(raw):,} source rows")

    stations = pd.read_csv(RAW_DIR / "stations.csv", dtype=str)
    stations["station"] = stations["brand"].str.lower()          # 'shell', 'sprint'
    key_by_uuid = dict(zip(stations["uuid"], stations["station"]))

    raw["valid_from_utc"] = pd.to_datetime(raw["date"], utc=True, format="ISO8601").dt.tz_localize(None)
    raw["station"] = raw["station_uuid"].map(key_by_uuid)

    # Rule 1: one row per fuel
    long = raw.melt(id_vars=["station", "valid_from_utc"], value_vars=FUELS,
                    var_name="fuel", value_name="price_eur")
    long["price_eur"] = pd.to_numeric(long["price_eur"], errors="coerce")

    # Rule 2: invalid prices
    invalid = long["price_eur"].isna() | (long["price_eur"] <= 0)
    print(f"Invalid prices (<= 0 or empty) dropped: {invalid.sum():,}")
    long = long[~invalid]

    # Rule 3: keep only real changes
    long = long.sort_values(["station", "fuel", "valid_from_utc"])
    changed = long.groupby(["station", "fuel"])["price_eur"].diff().ne(0)
    print(f"Rows without a price change dropped: {(~changed).sum():,}")
    prices = long[changed].reset_index(drop=True)

    # Quality report
    print("\nPrice changes per station and fuel:")
    print(prices.groupby(["station", "fuel"]).size().unstack())
    print("\nPrice range (EUR):")
    print(prices.groupby("fuel")["price_eur"].agg(["min", "median", "max"]))
    gaps = prices.groupby(["station", "fuel"])["valid_from_utc"].diff()
    long_gaps = prices[gaps > pd.Timedelta(hours=24)]
    print(f"\nGaps of more than 24 h without a change: {len(long_gaps)}")
    if len(long_gaps):
        print(long_gaps.assign(gap=gaps[gaps > pd.Timedelta(hours=24)]).head(20).to_string(index=False))

    prices[["station", "fuel", "valid_from_utc", "price_eur"]].to_csv(
        "data/prices.csv", index=False, date_format="%Y-%m-%d %H:%M:%S", lineterminator="\n")
    stations[["station", "uuid", "brand", "name", "street", "house_number", "post_code", "city",
              "latitude", "longitude"]].to_csv("data/stations.csv", index=False, lineterminator="\n")
    print(f"\nWritten: data/prices.csv ({len(prices):,} price changes), data/stations.csv")


if __name__ == "__main__":
    main()
