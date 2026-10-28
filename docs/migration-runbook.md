# Legacy Archive Migration Runbook

Moves the legacy hourly archive (one CSV per station per year) into BigQuery and switches reporting to the real-time feed at a defined cutover date.

## Scope

| | |
|---|---|
| Source | Legacy hourly export: `STN_CODE, OBS_DATE (DD/MM/YYYY), OBS_HOUR (0-23, SGT), TEMP_C, RH_PCT, RAIN_MM, WIND_KMH, WIND_DIR_DEG`; `-999` = missing |
| Target | `bronze.legacy_observations`, `bronze.legacy_stations`, then `silver.observations_hourly` |
| Volume | ~88 stations × 2 years × 8,760 hours ≈ 1.5M rows |
| Control totals | `legacy/manifests/manifest_<start>-<end>.csv`, one per extract run: row count, `TEMP_C` sum and `RAIN_MM` sum per file |
| Cutover | `cutover_date` in `workflow_settings.yaml`. Hours before it come from the archive; hours from it onwards come from the stream |

## Preconditions

- [ ] Terraform applied, including the Dataform repository (setup steps 3 and 5).
- [ ] The poller has been live since at least `cutover_date`, so there is no gap after cutover.
- [ ] `cutover_date` in `workflow_settings.yaml` is set to the day the poller went live, and that change is pushed to `main`.

## 1. Extract

```bash
export PROJECT_ID=sg-weather-pipeline REGION=asia-southeast1
pip install -r ingest/legacy_extract/requirements.txt
python3 ingest/legacy_extract/legacy_extract.py --bucket "${PROJECT_ID}-landing"
```

The default range is the two years ending 7 days ago, because the archive lags behind real time. The manifest is written last, so its presence means the extract finished.

Files are named `<station>_<year>_<start>-<end>.csv`, so each run adds to landing and never overwrites an earlier one.

Check: the number of files for the run matches the rows in its manifest:
```bash
gcloud storage ls "gs://${PROJECT_ID}-landing/legacy/observations/*_<start>-<end>.csv" | wc -l
gcloud storage cat "gs://${PROJECT_ID}-landing/legacy/manifests/manifest_<start>-<end>.csv" | tail -n +2 | wc -l
```

## 2. Load to bronze

`scripts/run_migration.sh` runs steps 1–3 in one go. To run the load on its own:

```bash
gcloud dataproc batches submit pyspark dataproc/legacy_to_bronze.py \
  --region="$REGION" --version=2.2 --subnet=data-subnet \
  --service-account="sa-dataproc@${PROJECT_ID}.iam.gserviceaccount.com" \
  --deps-bucket="gs://${PROJECT_ID}-dataproc-temp" \
  -- --project="$PROJECT_ID" --bucket="${PROJECT_ID}-landing" --temp-bucket="${PROJECT_ID}-dataproc-temp"
```

The job overwrites both bronze tables, so it is safe to re-run.

## 3. Reconcile

```bash
gcloud workflows run weather-daily-transform --location="$REGION" --data='{"check_freshness": "false"}'
```

The workflow builds silver and gold, appends a reconciliation result for every file to `ops.reconciliation_legacy`, and fails if any file is not `MATCHED`.

```sql
SELECT status, COUNT(*) AS files, SUM(source_rows) AS source_rows, SUM(target_rows) AS target_rows
FROM ops.reconciliation_legacy
WHERE checked_at = (SELECT MAX(checked_at) FROM ops.reconciliation_legacy)
GROUP BY status;
```

| Status | Meaning | Action |
|---|---|---|
| `MATCHED` | Row count and sums agree | None |
| `MISSING_IN_TARGET` | File in manifest, no rows in bronze | Check the file exists and the Dataproc logs; re-run the load |
| `UNEXPECTED_IN_TARGET` | Rows in bronze from a file not in the manifest | Stale file in landing, or an extract that didn't finish; clean landing and re-extract |
| `ROW_COUNT_MISMATCH` | Rows lost or duplicated | Look for malformed lines (extra delimiters, broken quoting) in the source file |
| `CHECKSUM_MISMATCH` | Same rows, different values | Values failed to parse (NULL sums) or were truncated; inspect `temp_c`/`rain_mm` for that file |

Additional checks, run after reconciliation:

```sql
-- Sentinel values are carried into bronze and become NULLs in silver
SELECT COUNTIF(temp_c = -999) AS temp_sentinels, COUNTIF(rain_mm = -999) AS rain_sentinels
FROM bronze.legacy_observations;

-- Hour coverage per station (expect 24 per day)
SELECT station_id, MIN(observed_hour) AS first_hour, MAX(observed_hour) AS last_hour, COUNT(*) / 5 AS station_hours
FROM silver.observations_hourly WHERE source = 'legacy_archive'
GROUP BY station_id ORDER BY station_hours;
```

## 4. Delta load

The archive lags real time by a few days, which can leave a gap between the last extracted day and `cutover_date`. Close it with a delta extract and a re-run:

```bash
START=<day after previous end> END=<cutover_date - 1> bash scripts/run_migration.sh
```

The delta run writes new files and a new manifest next to the earlier ones. The load rebuilds bronze from every file in landing, and reconciliation checks every manifest. Delta ranges must not overlap earlier runs: overlapping hours would duplicate rows, which the `uniqueKey` assertion on `silver.observations_hourly` would catch.

## 5. Cutover and sign-off

- [ ] Latest reconciliation: every file `MATCHED`.
- [ ] `silver.observations_hourly` has no gap around `cutover_date`:
  ```sql
  SELECT DATE(observed_hour, 'Asia/Singapore') AS day, source, COUNT(DISTINCT station_id) AS stations
  FROM silver.observations_hourly
  WHERE DATE(observed_hour, 'Asia/Singapore') BETWEEN DATE_SUB(DATE '<cutover>', INTERVAL 3 DAY) AND DATE_ADD(DATE '<cutover>', INTERVAL 3 DAY)
  GROUP BY day, source ORDER BY day;
  ```
- [ ] Gold row counts and dashboard totals reviewed.
- [ ] Set `enable_daily_transform = true` and run `terraform apply`.

## Rollback

Bronze, silver and gold are fully rebuilt from landing and the stream, so rolling back means fixing the input and re-running. To back out a bad extract run, delete its files and its manifest from landing (`*_<start>-<end>.csv`, `manifest_<start>-<end>.csv`) and re-run steps 2–3. The bucket is versioned, so deleted objects can be restored with `gcloud storage ls --all-versions`.
