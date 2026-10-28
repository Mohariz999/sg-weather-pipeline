resource "google_pubsub_topic" "readings" {
  name                       = "weather-readings"
  message_retention_duration = "604800s"
  depends_on                 = [google_project_service.apis]
}

# Pub/Sub writes every message straight into bronze: no pipeline to run or pay for.
# Failed writes are retried, and unacked messages are kept for 7 days.
resource "google_pubsub_subscription" "bigquery" {
  name                       = "weather-readings-bigquery"
  topic                      = google_pubsub_topic.readings.id
  message_retention_duration = "604800s"

  bigquery_config {
    table          = "${var.project_id}.${google_bigquery_table.readings_raw.dataset_id}.${google_bigquery_table.readings_raw.table_id}"
    write_metadata = true
  }

  expiration_policy {
    ttl = ""
  }

  depends_on = [google_bigquery_dataset_iam_member.pubsub_writes_bronze]
}
