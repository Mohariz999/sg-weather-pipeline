import csv
import io
import random
from datetime import UTC, datetime

from legacy_extract import LEGACY_COLUMNS, SENTINEL, control_totals, to_csv, to_legacy_rows

HOURLY = {
    "time": ["2025-12-31T23:00", "2026-01-01T00:00"],
    "temperature_2m": [27.1, 26.8],
    "relative_humidity_2m": [88, None],
    "precipitation": [0.0, 1.4],
    "wind_speed_10m": [7.2, 6.5],
    "wind_direction_10m": [40, 35],
}


def test_rows_use_legacy_date_format_and_local_hour():
    rows = list(to_legacy_rows("S109", HOURLY, random.Random(0), sentinel_rate=0))

    assert rows[0]["OBS_DATE"] == "31/12/2025"
    assert rows[0]["OBS_HOUR"] == 23
    assert rows[1]["OBS_DATE"] == "01/01/2026"
    assert rows[1]["OBS_HOUR"] == 0


def test_missing_values_become_sentinel():
    rows = list(to_legacy_rows("S109", HOURLY, random.Random(0), sentinel_rate=0))

    assert rows[1]["RH_PCT"] == SENTINEL


def test_sentinel_rate_one_replaces_everything():
    rows = list(to_legacy_rows("S109", HOURLY, random.Random(0), sentinel_rate=1))

    assert {rows[0][c] for c in LEGACY_COLUMNS[3:]} == {SENTINEL}


def test_control_totals_match_csv_contents():
    rows = list(to_legacy_rows("S109", HOURLY, random.Random(0), sentinel_rate=0))
    totals = control_totals("S109_2026.csv", rows, datetime(2026, 10, 28, tzinfo=UTC))

    parsed = list(csv.DictReader(io.StringIO(to_csv(rows, LEGACY_COLUMNS))))
    assert totals["row_count"] == len(parsed) == 2
    assert totals["temp_c_sum"] == round(sum(float(r["TEMP_C"]) for r in parsed), 4) == 53.9
    assert totals["rain_mm_sum"] == 1.4
