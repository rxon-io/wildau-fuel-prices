"""
Download the Tankerkönig price history for the two Wildau stations.

For every day the full prices file for Germany (~35 MB) is downloaded, only the rows of
the selected stations are kept, and the rest is discarded. The result is one small CSV per
day in data/raw/wildau/. Days that are already there are skipped, so the script can be
stopped and restarted at any time.

The day before the analysis period (31 Oct 2025) is included: the files contain only price
changes, so the price valid at midnight on 1 Nov comes from the last change of the day before.

Credentials are read from .env (TK_USER, TK_PASSWORD); a personal Tankerkönig account is needed.
The data may not be redistributed (Tankerkönig AGB), so data/ is excluded from git.

Usage:
    python src/tk_download.py --start 2025-10-31 --end 2026-10-31
"""

import argparse
import base64
import csv
import io
import time
import urllib.error
import urllib.request
from datetime import date, timedelta
from pathlib import Path

BASE_URL = "https://data.tankerkoenig.de/tankerkoenig-organization/tankerkoenig-data"
STATIONS = {
    "14df6b3e-6538-46c9-9bb1-278f8078082e": "Shell Wildau, Richard-Sorge-Str. 30",
    "979d38b5-d17e-4446-b08b-78459b00f7c4": "Sprint Wildau, Chausseestr. 1",
}
OUT_DIR = Path("data/raw/wildau")
PAUSE_SECONDS = 1.0     # be polite to the server between files
RETRIES = 3


def read_env(path: Path) -> dict:
    env = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip()
    return env


def fetch(rel_path: str, token: str) -> bytes:
    """Download one repository file, with retries; falls back to the LFS media URL."""
    last_error = None
    for attempt in range(1, RETRIES + 1):
        try:
            for kind in ("raw", "media"):
                url = f"{BASE_URL}/{kind}/branch/master/{rel_path}"
                request = urllib.request.Request(url, headers={"Authorization": f"Basic {token}"})
                with urllib.request.urlopen(request, timeout=300) as response:
                    data = response.read()
                if not data.startswith(b"version https://git-lfs"):
                    return data
            raise RuntimeError("only an LFS pointer was returned")
        except urllib.error.HTTPError as e:
            if e.code in (401, 403, 404):   # wrong credentials or missing file: retrying won't help
                raise
            last_error = e
        except (urllib.error.URLError, TimeoutError, RuntimeError) as e:
            last_error = e
        wait = 10 * attempt
        print(f"    attempt {attempt} failed ({last_error}), waiting {wait} s")
        time.sleep(wait)
    raise RuntimeError(f"giving up on {rel_path}: {last_error}")


def keep_rows(data: bytes, key_column: str, keys: set) -> tuple[list, list]:
    reader = csv.DictReader(io.StringIO(data.decode("utf-8")))
    rows = [row for row in reader if row[key_column] in keys]
    return reader.fieldnames, rows


def write_csv(path: Path, header: list, rows: list) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=header, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    tmp.replace(path)   # the day file appears only when it is complete


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--start", default="2025-10-31")
    parser.add_argument("--end", default="2026-10-31", help="last day, inclusive")
    args = parser.parse_args()

    env = read_env(Path(".env"))
    token = base64.b64encode(f"{env['TK_USER']}:{env['TK_PASSWORD']}".encode()).decode()
    keys = set(STATIONS)

    # Station master data from the last day of the period
    end = date.fromisoformat(args.end)
    stations_out = OUT_DIR / "stations.csv"
    if not stations_out.exists():
        rel = f"stations/{end:%Y}/{end:%m}/{end:%Y-%m-%d}-stations.csv"
        header, rows = keep_rows(fetch(rel, token), "uuid", keys)
        write_csv(stations_out, header, rows)
        print(f"stations.csv: {len(rows)} stations")

    day = date.fromisoformat(args.start)
    started = time.time()
    done = skipped = 0
    total_days = (end - day).days + 1
    while day <= end:
        out = OUT_DIR / f"{day:%Y-%m-%d}.csv"
        if out.exists():
            skipped += 1
        else:
            rel = f"prices/{day:%Y}/{day:%m}/{day:%Y-%m-%d}-prices.csv"
            try:
                header, rows = keep_rows(fetch(rel, token), "station_uuid", keys)
            except urllib.error.HTTPError as e:
                print(f"{day}: HTTP {e.code}, skipped (run again later to retry)")
                day += timedelta(days=1)
                continue
            write_csv(out, header, rows)
            done += 1
            elapsed = time.time() - started
            remaining = (total_days - done - skipped) * elapsed / done
            print(f"{day}: {len(rows):3d} rows | {done + skipped}/{total_days} days | ~{remaining / 60:.0f} min left")
            time.sleep(PAUSE_SECONDS)
        day += timedelta(days=1)

    missing = [d for d in (date.fromisoformat(args.start) + timedelta(days=i) for i in range(total_days))
               if not (OUT_DIR / f"{d:%Y-%m-%d}.csv").exists()]
    print(f"\nFinished: {done} downloaded, {skipped} already there, {len(missing)} missing")
    if missing:
        print("Missing days:", ", ".join(str(d) for d in missing))


if __name__ == "__main__":
    main()
