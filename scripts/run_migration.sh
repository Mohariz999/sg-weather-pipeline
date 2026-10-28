#!/usr/bin/env bash
# Legacy migration: extract -> Cloud Storage -> Dataproc Serverless -> BigQuery bronze,
# then run Dataform, which reconciles bronze against the extract manifest.
# Run from the repo root in Cloud Shell. See docs/migration-runbook.md.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?set PROJECT_ID}"
REGION="${REGION:-asia-southeast1}"
START="${START:-}"
END="${END:-}"

echo "== 1/3 Extract legacy archive to gs://${PROJECT_ID}-landing/legacy"
pip install --quiet -r ingest/legacy_extract/requirements.txt
python3 ingest/legacy_extract/legacy_extract.py --bucket "${PROJECT_ID}-landing" \
  ${START:+--start "$START"} ${END:+--end "$END"}

echo "== 2/3 Load into BigQuery bronze with Dataproc Serverless"
gcloud dataproc batches submit pyspark dataproc/legacy_to_bronze.py \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --batch="legacy-to-bronze-$(date +%Y%m%d-%H%M%S)" \
  --version=2.2 \
  --subnet=data-subnet \
  --service-account="sa-dataproc@${PROJECT_ID}.iam.gserviceaccount.com" \
  --deps-bucket="gs://${PROJECT_ID}-dataproc-temp" \
  -- --project="$PROJECT_ID" --bucket="${PROJECT_ID}-landing" --temp-bucket="${PROJECT_ID}-dataproc-temp"

echo "== 3/3 Transform and reconcile (Dataform via Workflows)"
gcloud workflows run weather-daily-transform --project="$PROJECT_ID" --location="$REGION" \
  --data='{"check_freshness": "false"}'

bq query --project_id="$PROJECT_ID" --use_legacy_sql=false '
SELECT status, COUNT(*) AS files, SUM(source_rows) AS source_rows, SUM(target_rows) AS target_rows
FROM ops.reconciliation_legacy
WHERE checked_at = (SELECT MAX(checked_at) FROM ops.reconciliation_legacy)
GROUP BY status'
