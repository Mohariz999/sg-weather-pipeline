"""Builds the legacy archive that the migration loads into BigQuery.

Hourly history is pulled from the Open-Meteo archive at each data.gov.sg station's
location and written in the legacy system's export format: one CSV per station per
year per extract run, DD/MM/YYYY dates in Singapore time, and -999 for missing values. A manifest of
control totals (row count and column sums per file) is written alongside it so that
the load can be reconciled against the source.

Usage:
    python3 legacy_extract.py --bucket <project>-landing --start 2024-10-01 --end 2026-10-20
    python3 legacy_extract.py --local-dir ./legacy_out ...   # write to disk instead
"""
import argparse
import csv
import io
import logging
import random
import time
from collections import defaultdict
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

import requests

STATIONS_API = "https://api-open.data.gov.sg/v2/real-time/api"
STATION_ENDPOINTS = ["air-temperature", "rainfall", "relative-humidity", "wind-speed", "wind-direction"]
ARCHIVE_API = "https://archive-api.open-meteo.com/v1/archive"

# Open-Meteo variable -> legacy column name
HOURLY_VARS = {
    "temperature_2m": "TEMP_C",
    "relative_humidity_2m": "RH_PCT",
    "precipitation": "RAIN_MM",
    "wind_speed_10m": "WIND_KMH",
    "wind_direction_10m": "WIND_DIR_DEG",
}
LEGACY_COLUMNS = ["STN_CODE", "OBS_DATE", "OBS_HOUR", *HOURLY_VARS.values()]
MANIFEST_COLUMNS = ["file_name", "row_count", "temp_c_sum", "rain_mm_sum", "extracted_at"]
SENTINEL = -999  # how the legacy system recorded a missing value

log = logging.getLogger("legacy_extract")


def fetch_stations(session):
    """Every station that appears in any real-time endpoint: {id: {name, latitude, longitude}}."""
    stations = {}
    for endpoint in STATION_ENDPOINTS:
        resp = session.get(f"{STATIONS_API}/{endpoint}", timeout=30)
        resp.raise_for_status()
        for s in resp.json()["data"]["stations"]:
            stations.setdefault(s["id"], {
                "name": s.get("name"),
                "latitude": s["location"]["latitude"],
                "longitude": s["location"]["longitude"],
            })
    return stations


def fetch_history(session, latitude, longitude, start, end):
    params = {
        "latitude": latitude,
        "longitude": longitude,
        "start_date": start.isoformat(),
        "end_date": end.isoformat(),
        "hourly": ",".join(HOURLY_VARS),
        "timezone": "Asia/Singapore",
        "wind_speed_unit": "kmh",
    }
    last_error = None
    for attempt in range(5):
        try:
            resp = session.get(ARCHIVE_API, params=params, timeout=120)
            if resp.status_code == 429 or resp.status_code >= 500:
                raise requests.HTTPError(f"HTTP {resp.status_code}")
            resp.raise_for_status()
            return resp.json()["hourly"]
        except (requests.HTTPError, requests.ConnectionError, requests.Timeout, ValueError) as e:
            # Rate limits, server errors and the occasional truncated or empty body are
            # all transient; anything else (e.g. a 400 for bad parameters) is raised above.
            if isinstance(e, requests.HTTPError) and e.response is not None and e.response.status_code < 500:
                raise
            last_error = e
            log.warning("retrying %s,%s after: %s", latitude, longitude, e)
            time.sleep(30 * (attempt + 1))
    raise RuntimeError(f"giving up on {latitude},{longitude}: {last_error}")


def to_legacy_rows(station_id, hourly, rng, sentinel_rate):
    """Convert Open-Meteo hourly arrays to legacy-format rows.

    Times come back in Singapore local time because of timezone=Asia/Singapore.
    A small share of values is replaced with the sentinel, as the old system did for
    sensor outages, so the migration has to handle it.
    """
    for i, ts in enumerate(hourly["time"]):
        local = datetime.fromisoformat(ts)
        row = {"STN_CODE": station_id, "OBS_DATE": local.strftime("%d/%m/%Y"), "OBS_HOUR": local.hour}
        for api_name, column in HOURLY_VARS.items():
            value = hourly[api_name][i]
            if value is None or rng.random() < sentinel_rate:
                value = SENTINEL
            row[column] = value
        yield row


def control_totals(file_name, rows, extracted_at):
    return {
        "file_name": file_name,
        "row_count": len(rows),
        "temp_c_sum": round(sum(float(r["TEMP_C"]) for r in rows), 4),
        "rain_mm_sum": round(sum(float(r["RAIN_MM"]) for r in rows), 4),
        "extracted_at": extracted_at.isoformat(sep=" "),  # BigQuery CSV timestamp format
    }


def to_csv(rows, columns):
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=columns, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return buf.getvalue()


class Sink:
    """Writes either to a Cloud Storage bucket or to a local directory."""

    def __init__(self, bucket=None, local_dir=None, prefix="legacy"):
        self.prefix = prefix
        self.local_dir = Path(local_dir) if local_dir else None
        if bucket:
            from google.cloud import storage
            self.bucket = storage.Client().bucket(bucket)

    def write(self, path, content):
        full = f"{self.prefix}/{path}"
        if self.local_dir:
            target = self.local_dir / full
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
        else:
            self.bucket.blob(full).upload_from_string(content, content_type="text/csv")


def main():
    default_end = date.today() - timedelta(days=7)  # the archive lags a few days behind
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--bucket", help="Landing bucket, e.g. <project>-landing")
    target.add_argument("--local-dir", help="Write files locally instead of to Cloud Storage")
    parser.add_argument("--start", type=date.fromisoformat, default=default_end - timedelta(days=730))
    parser.add_argument("--end", type=date.fromisoformat, default=default_end)
    parser.add_argument("--sentinel-rate", type=float, default=0.001)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    sink = Sink(bucket=args.bucket, local_dir=args.local_dir)
    session = requests.Session()
    session.headers["User-Agent"] = "sg-weather-pipeline/1.0"
    rng = random.Random(args.seed)
    extracted_at = datetime.now(UTC)

    stations = fetch_stations(session)
    log.info("found %d stations; extracting %s to %s", len(stations), args.start, args.end)

    # Every run writes uniquely named files and its own manifest, so a delta extract adds
    # to the landing zone instead of overwriting an earlier run.
    run_tag = f"{args.start:%Y%m%d}-{args.end:%Y%m%d}"
    manifest = []
    for station_id, meta in sorted(stations.items()):
        hourly = fetch_history(session, meta["latitude"], meta["longitude"], args.start, args.end)
        by_year = defaultdict(list)
        for row in to_legacy_rows(station_id, hourly, rng, args.sentinel_rate):
            by_year[row["OBS_DATE"][-4:]].append(row)
        for year, rows in sorted(by_year.items()):
            file_name = f"{station_id}_{year}_{run_tag}.csv"
            sink.write(f"observations/{file_name}", to_csv(rows, LEGACY_COLUMNS))
            manifest.append(control_totals(file_name, rows, extracted_at))
        log.info("%s: %d hourly rows", station_id, sum(len(r) for r in by_year.values()))
        # Long date ranges count as several calls against Open-Meteo's per-minute limit.
        time.sleep(3)

    station_rows = [
        {"STN_CODE": sid, "STN_NAME": m["name"], "LAT": m["latitude"], "LON": m["longitude"]}
        for sid, m in sorted(stations.items())
    ]
    sink.write("stations/stations.csv", to_csv(station_rows, ["STN_CODE", "STN_NAME", "LAT", "LON"]))
    # Written last: its presence means the extract finished.
    sink.write(f"manifests/manifest_{run_tag}.csv", to_csv(manifest, MANIFEST_COLUMNS))
    log.info("wrote %d files, %d rows", len(manifest), sum(m["row_count"] for m in manifest))


if __name__ == "__main__":
    main()
