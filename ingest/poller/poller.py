"""Polls the data.gov.sg real-time weather APIs and publishes each reading to Pub/Sub.

Runs as a Cloud Run job, triggered every 5 minutes by Cloud Scheduler. One message is
published per station reading. The same reading can be published twice (when the API
has not updated since the last poll, or on a retry); silver deduplicates on
(metric, station_id, reading_ts).
"""
import json
import logging
import os
import sys
from datetime import UTC, datetime

import requests

API_BASE = "https://api-open.data.gov.sg/v2/real-time/api"
# API endpoint -> metric name used everywhere downstream
ENDPOINTS = {
    "air-temperature": "air_temperature",
    "rainfall": "rainfall",
    "relative-humidity": "relative_humidity",
    "wind-speed": "wind_speed",
    "wind-direction": "wind_direction",
}

log = logging.getLogger("poller")


def fetch(session, endpoint):
    resp = session.get(f"{API_BASE}/{endpoint}", timeout=30)
    resp.raise_for_status()
    body = resp.json()
    if body.get("code") != 0:
        raise RuntimeError(f"{endpoint}: API error {body.get('errorMsg')!r}")
    return body["data"]


def to_messages(metric, data, ingested_at):
    """Flatten one API response into one dict per station reading."""
    stations = {s["id"]: s for s in data.get("stations", [])}
    unit = data.get("readingUnit")
    for reading in data.get("readings", []):
        reading_ts = datetime.fromisoformat(reading["timestamp"])
        for item in reading.get("data", []):
            station = stations.get(item["stationId"], {})
            location = station.get("location") or {}
            yield {
                "metric": metric,
                "station_id": item["stationId"],
                "station_name": station.get("name"),
                "latitude": location.get("latitude"),
                "longitude": location.get("longitude"),
                "reading_ts": reading_ts.isoformat(),
                "value": item.get("value"),
                "unit": unit,
                "source": "data.gov.sg",
                "ingested_at": ingested_at.isoformat(),
            }


def main():
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    from google.cloud import pubsub_v1  # imported here so unit tests don't need GCP libraries

    topic = os.environ["PUBSUB_TOPIC"]
    publisher = pubsub_v1.PublisherClient()
    session = requests.Session()
    session.headers["User-Agent"] = "sg-weather-pipeline/1.0"
    ingested_at = datetime.now(UTC)

    failed, total = [], 0
    for endpoint, metric in ENDPOINTS.items():
        try:
            futures = [
                publisher.publish(topic, json.dumps(m).encode(), metric=metric)
                for m in to_messages(metric, fetch(session, endpoint), ingested_at)
            ]
            for future in futures:
                future.result(timeout=60)
            log.info("%s: published %d readings", metric, len(futures))
            total += len(futures)
        except Exception:
            log.exception("%s: failed", metric)
            failed.append(metric)

    log.info("published %d readings in total", total)
    if failed:
        # A non-zero exit marks the execution as failed, which the alert policy watches.
        sys.exit(f"failed metrics: {', '.join(failed)}")


if __name__ == "__main__":
    main()
