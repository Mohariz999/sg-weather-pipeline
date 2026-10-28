from datetime import UTC, datetime

from poller import to_messages

INGESTED_AT = datetime(2026, 10, 28, 4, 0, tzinfo=UTC)

AIR_TEMPERATURE = {
    "stations": [
        {"id": "S109", "deviceId": "S109", "name": "Ang Mo Kio Avenue 5",
         "location": {"latitude": 1.3764, "longitude": 103.8492}},
        {"id": "S50", "deviceId": "S50", "name": "Clementi Road",
         "location": {"latitude": 1.3337, "longitude": 103.7768}},
    ],
    "readings": [
        {"timestamp": "2026-10-28T11:59:00+08:00",
         "data": [{"stationId": "S109", "value": 29.9}, {"stationId": "S50", "value": 30.4}]},
    ],
    "readingType": "DBT 1M F",
    "readingUnit": "deg C",
}


def test_one_message_per_station_reading():
    messages = list(to_messages("air_temperature", AIR_TEMPERATURE, INGESTED_AT))

    assert len(messages) == 2
    assert messages[0] == {
        "metric": "air_temperature",
        "station_id": "S109",
        "station_name": "Ang Mo Kio Avenue 5",
        "latitude": 1.3764,
        "longitude": 103.8492,
        "reading_ts": "2026-10-28T11:59:00+08:00",
        "value": 29.9,
        "unit": "deg C",
        "source": "data.gov.sg",
        "ingested_at": "2026-10-28T04:00:00+00:00",
    }


def test_reading_from_unlisted_station_is_kept_without_metadata():
    data = {**AIR_TEMPERATURE, "readings": [
        {"timestamp": "2026-10-28T11:59:00+08:00", "data": [{"stationId": "S999", "value": 28.0}]},
    ]}

    [message] = to_messages("air_temperature", data, INGESTED_AT)

    assert message["station_id"] == "S999"
    assert message["station_name"] is None
    assert message["latitude"] is None


def test_empty_response_yields_nothing():
    assert list(to_messages("rainfall", {"stations": [], "readings": []}, INGESTED_AT)) == []

