output "landing_bucket" {
  value = google_storage_bucket.landing.name
}

output "pubsub_topic" {
  value = google_pubsub_topic.readings.id
}

output "bigquery_subscription" {
  value = google_pubsub_subscription.bigquery.id
}

output "poller_image_repo" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "service_accounts" {
  value = { for k, sa in google_service_account.sa : k => sa.email }
}
