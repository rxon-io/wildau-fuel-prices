"""
First look at the Tankerkönig history: download ONE stations file and ONE prices file,
find the Wildau stations and show the file format and size.

Credentials are read from the file .env in the project folder (never committed to git):
    TK_USER=...
    TK_PASSWORD=...
A personal Tankerkönig account is required; see https://creativecommons.tankerkoenig.de

Usage:
    python src/tk_sample.py --date 2025-11-01
"""

import argparse
import base64
import csv
import io
import time
import urllib.request
from pathlib import Path

BASE_URL = "https://data.tankerkoenig.de/tankerkoenig-organization/tankerkoenig-data"
WILDAU_POST_CODE = "15745"


def read_env(path: Path) -> dict:
    """Minimal .env reader: KEY=value per line, # starts a comment."""
    env = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip()
    return env


def download(rel_path: str, user: str, password: str, target: Path) -> Path:
    """Download one file from the repository; falls back to the LFS media URL if needed."""
    token = base64.b64encode(f"{user}:{password}".encode()).decode()
    for kind in ("raw", "media"):
        url = f"{BASE_URL}/{kind}/branch/master/{rel_path}"
        request = urllib.request.Request(url, headers={"Authorization": f"Basic {token}"})
        started = time.time()
        with urllib.request.urlopen(request, timeout=300) as response:
            data = response.read()
        # A Git LFS pointer is a tiny text file instead of the real data
        if data.startswith(b"version https://git-lfs"):
            print(f"  {kind}: got an LFS pointer, trying the media URL")
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        print(f"  {rel_path}: {len(data) / 1e6:.1f} MB in {time.time() - started:.1f} s")
        return target
    raise RuntimeError(f"Could not download {rel_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--date", default="2025-11-01", help="day to download, YYYY-MM-DD")
    args = parser.parse_args()

    env = read_env(Path(".env"))
    user, password = env["TK_USER"], env["TK_PASSWORD"]
    yyyy, mm, _ = args.date.split("-")
    raw = Path("data/raw")

    print("Downloading...")
    stations_file = download(f"stations/{yyyy}/{mm}/{args.date}-stations.csv", user, password,
                             raw / f"{args.date}-stations.csv")
    prices_file = download(f"prices/{yyyy}/{mm}/{args.date}-prices.csv", user, password,
                           raw / f"{args.date}-prices.csv")

    # Stations: find everything in Wildau
    with stations_file.open(encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        print("\nStations file columns:", reader.fieldnames)
        stations = list(reader)
    print(f"Stations in Germany: {len(stations):,}")
    wildau = [s for s in stations if s.get("post_code") == WILDAU_POST_CODE]
    print(f"\nStations with post code {WILDAU_POST_CODE}:")
    for s in wildau:
        print(f"  {s.get('uuid')} | {s.get('brand')} | {s.get('name')} | {s.get('street')} {s.get('house_number')}")
    wildau_ids = {s.get("uuid") for s in wildau}

    # Prices: format, size, and the rows of the Wildau stations
    with prices_file.open(encoding="utf-8", newline="") as f:
        text = f.read()
    reader = csv.DictReader(io.StringIO(text))
    rows = list(reader)
    print("\nPrices file columns:", reader.fieldnames)
    print(f"Price rows for all of Germany on {args.date}: {len(rows):,}")
    ours = [r for r in rows if r.get("station_uuid") in wildau_ids]
    print(f"Rows for the Wildau stations: {len(ours)}")
    for r in ours[:15]:
        print("  ", r)


if __name__ == "__main__":
    main()
