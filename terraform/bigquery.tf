# Medallion layers. Bronze tables are created here (their schema is a contract with the
# ingestion code); silver, gold and ops tables are created by Dataform.
locals {
  datasets = {
    bronze = "Raw data as it landed: real-time messages and the migrated legacy archive."
    silver = "Cleaned, deduplicated, unit-standardised data."
    gold   = "Analytics-ready tables that dashboards and the Looker model read."
    ops    = "Reconciliation results, data-quality assertions and pipeline metadata."
  }
}

resource "google_bigquery_dataset" "layers" {
  for_each = local.datasets

  dataset_id                 = each.key
  description                = each.value
  location                   = var.region
  delete_contents_on_destroy = true

  depends_on = [google_project_service.apis]
}

# Written directly by the Pub/Sub BigQuery subscription: one row per message, payload
# kept as the original JSON text. Parsing and validation happen in Dataform (silver).
resource "google_bigquery_table" "readings_raw" {
  dataset_id          = google_bigquery_dataset.layers["bronze"].dataset_id
  table_id            = "weather_readings_raw"
  description         = "Raw Pub/Sub messages from the data.gov.sg poller, written by a BigQuery subscription."
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "publish_time"
  }

  # Column names are fixed by the BigQuery subscription's write_metadata option.
  schema = jsonencode([
    { name = "subscription_name", type = "STRING", mode = "NULLABLE" },
    { name = "message_id", type = "STRING", mode = "NULLABLE" },
    { name = "publish_time", type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "data", type = "STRING", mode = "NULLABLE", description = "Message payload (JSON text)" },
    { name = "attributes", type = "STRING", mode = "NULLABLE", description = "Message attributes (JSON text)" },
  ])
}

resource "google_bigquery_table" "legacy_observations" {
  dataset_id          = google_bigquery_dataset.layers["bronze"].dataset_id
  table_id            = "legacy_observations"
  description         = "Legacy hourly archive, loaded by the Dataproc migration job. Values kept as-is, including the -999 sentinel."
  deletion_protection = false
  clustering          = ["stn_code"]

  # Monthly, not daily: the archive is small per day, and daily partitions would mean ~730 tiny ones.
  time_partitioning {
    type  = "MONTH"
    field = "observed_at_utc"
  }

  # The Dataproc migration job overwrites this table, and BigQuery then reports the schema
  # in its own form (FLOAT vs FLOAT64, REQUIRED lineage columns). Spark owns it from here.
  lifecycle {
    ignore_changes = [schema]
  }

  schema = jsonencode([
    { name = "stn_code", type = "STRING", mode = "NULLABLE" },
    { name = "obs_date", type = "DATE", mode = "NULLABLE" },
    { name = "obs_hour", type = "INT64", mode = "NULLABLE" },
    { name = "temp_c", type = "FLOAT64", mode = "NULLABLE" },
    { name = "rh_pct", type = "FLOAT64", mode = "NULLABLE" },
    { name = "rain_mm", type = "FLOAT64", mode = "NULLABLE" },
    { name = "wind_kmh", type = "FLOAT64", mode = "NULLABLE" },
    { name = "wind_dir_deg", type = "FLOAT64", mode = "NULLABLE" },
    { name = "observed_at_utc", type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "_source_file", type = "STRING", mode = "NULLABLE", description = "Lineage: legacy file this row came from" },
    { name = "_loaded_at", type = "TIMESTAMP", mode = "NULLABLE" },
  ])
}

resource "google_bigquery_table" "legacy_stations" {
  dataset_id          = google_bigquery_dataset.layers["bronze"].dataset_id
  table_id            = "legacy_stations"
  deletion_protection = false

  # The Dataproc migration job overwrites this table, and BigQuery then reports the schema
  # in its own form (FLOAT vs FLOAT64, REQUIRED lineage columns). Spark owns it from here.
  lifecycle {
    ignore_changes = [schema]
  }

  schema = jsonencode([
    { name = "stn_code", type = "STRING", mode = "NULLABLE" },
    { name = "stn_name", type = "STRING", mode = "NULLABLE" },
    { name = "latitude", type = "FLOAT64", mode = "NULLABLE" },
    { name = "longitude", type = "FLOAT64", mode = "NULLABLE" },
    { name = "_loaded_at", type = "TIMESTAMP", mode = "NULLABLE" },
  ])
}

# Control totals from every legacy extract run, read straight from Cloud Storage. Reconciliation
# compares these "source" numbers with what actually landed in bronze.
resource "google_bigquery_table" "legacy_manifest" {
  dataset_id          = google_bigquery_dataset.layers["ops"].dataset_id
  table_id            = "legacy_manifest_ext"
  description         = "External table over the legacy extract manifest in Cloud Storage."
  deletion_protection = false

  external_data_configuration {
    source_format = "CSV"
    autodetect    = false
    source_uris   = ["gs://${google_storage_bucket.landing.name}/legacy/manifests/*.csv"]

    csv_options {
      quote             = "\""
      skip_leading_rows = 1
    }

    schema = jsonencode([
      { name = "file_name", type = "STRING" },
      { name = "row_count", type = "INT64" },
      { name = "temp_c_sum", type = "FLOAT64" },
      { name = "rain_mm_sum", type = "FLOAT64" },
      { name = "extracted_at", type = "TIMESTAMP" },
    ])
  }
}
