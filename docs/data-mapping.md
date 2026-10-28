# Data Mapping

## Real-time feed → bronze → silver

Source: `https://api-open.data.gov.sg/v2/real-time/api/{endpoint}`

| Endpoint | `metric` | Source unit | Silver unit | Conversion |
|---|---|---|---|---|
| `air-temperature` | `air_temperature` | deg C | degC | none |
| `relative-humidity` | `relative_humidity` | percentage | pct | none |
| `rainfall` | `rainfall` | mm (5-minute total) | mm | summed to hourly |
| `wind-speed` | `wind_speed` | knots | km/h | × 1.852 |
| `wind-direction` | `wind_direction` | degrees | deg | circular mean per hour |

`bronze.weather_readings_raw` stores each Pub/Sub message as-is: `message_id`, `publish_time`, `data` (the JSON payload as text), `attributes` and `subscription_name`. The payload fields are extracted in `silver.readings_parsed`.

| API field | Payload field (`data`) | `silver.readings_clean` |
|---|---|---|
| `readings[].data[].stationId` | `station_id` | `station_id` |
| `stations[].name` | `station_name` | `station_name` |
| `stations[].location.latitude/longitude` | `latitude`, `longitude` | same |
| `readings[].timestamp` (+08:00) | `reading_ts` (ISO, +08:00) | `reading_ts` (TIMESTAMP, UTC) |
| `readings[].data[].value` | `value` | `value` (standard unit) |
| `readingUnit` | `unit` | `unit` (standard unit name) |
| (poll time) | `ingested_at` | `ingested_at` |
| (Pub/Sub) | `message_id`, `publish_time` columns | `_published_at` |

Quarantine rules, applied in `silver.readings_parsed`. A message goes to `silver.readings_quarantine` for invalid JSON, a missing `metric`/`station_id`/`reading_ts`/`value`, an unknown metric, a non-numeric value, or a timestamp without a timezone.

Range rules, enforced as Dataform assertions on silver: temperature 15–45, humidity 0–100, rainfall 0–200, wind speed 0–200, wind direction 0–360.

## Legacy archive → bronze → silver

| Legacy column | Format | `bronze.legacy_observations` | `silver.observations_hourly` |
|---|---|---|---|
| `STN_CODE` | string | `stn_code` | `station_id` |
| `OBS_DATE` | DD/MM/YYYY, SGT | `obs_date` (DATE) | combined with `OBS_HOUR` → `observed_hour` (UTC) |
| `OBS_HOUR` | 0–23, SGT | `obs_hour` (INT64) | |
| (derived) | | `observed_at_utc` = SGT → UTC | |
| `TEMP_C` | decimal, `-999` = missing | `temp_c` | `metric = 'air_temperature'`, `-999` → NULL, row dropped |
| `RH_PCT` | integer, `-999` = missing | `rh_pct` | `relative_humidity` |
| `RAIN_MM` | decimal, `-999` = missing | `rain_mm` | `rainfall` |
| `WIND_KMH` | decimal, `-999` = missing | `wind_kmh` | `wind_speed` (already km/h) |
| `WIND_DIR_DEG` | integer, `-999` = missing | `wind_dir_deg` | `wind_direction` |
| (file name) | | `_source_file` | lineage, used by reconciliation |
| (load time) | | `_loaded_at` | |

## Silver → gold

`gold.daily_station_weather` (grain: `obs_date` × `station_id`, Singapore calendar day):

| Column | Rule |
|---|---|
| `min_temp_c`, `max_temp_c`, `avg_temp_c` | min, max and mean of the hourly temperatures |
| `total_rain_mm` | sum of hourly rainfall |
| `rainy_hours` | hours with rainfall > 0 |
| `avg_humidity_pct` | mean hourly humidity |
| `max_wind_kmh` | highest hourly-average wind speed |
| `hours_reported` | distinct hours with a temperature value (completeness) |
| `sources` | `legacy_archive`, `realtime_stream`, or both on cutover day |
| `latitude`, `longitude`, `station_location` | from `silver.stations`; `station_location` is `"lat,long"` text for maps |

`gold.island_daily_summary` (grain: `obs_date`) aggregates the table above across stations. `heavy_rain_stations` counts stations with ≥ 30 mm in the day.
