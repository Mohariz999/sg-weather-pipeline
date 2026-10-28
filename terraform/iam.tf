# One service account per component, each with only the roles it needs. Grants are
# scoped to the narrowest resource possible (topic, bucket, dataset) rather than the project.
locals {
  service_accounts = {
    poller    = "Polls data.gov.sg and publishes readings to Pub/Sub"
    dataproc  = "Runs the legacy migration Spark job"
    dataform  = "Builds silver, gold and ops tables in BigQuery"
    workflows = "Orchestrates the daily Dataform run"
    scheduler = "Triggers the poller job and the daily workflow"
    deployer  = "Cloud Build: builds and deploys the poller image"
  }

  # Roles that only exist at project level.
  project_roles = {
    dataproc_worker     = { sa = "dataproc", role = "roles/dataproc.worker" }
    dataproc_jobs       = { sa = "dataproc", role = "roles/bigquery.jobUser" }
    dataform_jobs       = { sa = "dataform", role = "roles/bigquery.jobUser" }
    workflows_dataform  = { sa = "workflows", role = "roles/dataform.editor" }
    workflows_logs      = { sa = "workflows", role = "roles/logging.logWriter" }
    scheduler_workflows = { sa = "scheduler", role = "roles/workflows.invoker" }
    deployer_logs       = { sa = "deployer", role = "roles/logging.logWriter" }
    deployer_run        = { sa = "deployer", role = "roles/run.developer" }
  }

  dataset_roles = {
    dataproc_bronze = { sa = "dataproc", dataset = "bronze", role = "roles/bigquery.dataEditor" }
    dataform_bronze = { sa = "dataform", dataset = "bronze", role = "roles/bigquery.dataViewer" }
    dataform_silver = { sa = "dataform", dataset = "silver", role = "roles/bigquery.dataEditor" }
    dataform_gold   = { sa = "dataform", dataset = "gold", role = "roles/bigquery.dataEditor" }
    dataform_ops    = { sa = "dataform", dataset = "ops", role = "roles/bigquery.dataEditor" }
  }
}

resource "google_service_account" "sa" {
  for_each = local.service_accounts

  account_id   = "sa-${each.key}"
  display_name = each.value
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "roles" {
  for_each = local.project_roles

  project = var.project_id
  role    = each.value.role
  member  = google_service_account.sa[each.value.sa].member
}

resource "google_bigquery_dataset_iam_member" "roles" {
  for_each = local.dataset_roles

  dataset_id = google_bigquery_dataset.layers[each.value.dataset].dataset_id
  role       = each.value.role
  member     = google_service_account.sa[each.value.sa].member
}

# --- Cloud Storage ---------------------------------------------------------------

resource "google_storage_bucket_iam_member" "landing_readers" {
  # Dataform reads the manifest through the external table, so it needs the bucket too.
  for_each = toset(["dataproc", "dataform"])

  bucket = google_storage_bucket.landing.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.sa[each.key].member
}

resource "google_storage_bucket_iam_member" "dataproc_temp" {
  bucket = google_storage_bucket.dataproc_temp.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.sa["dataproc"].member
}

# --- Pub/Sub ---------------------------------------------------------------------

resource "google_pubsub_topic_iam_member" "poller_publish" {
  topic  = google_pubsub_topic.readings.id
  role   = "roles/pubsub.publisher"
  member = google_service_account.sa["poller"].member
}

# The BigQuery subscription writes as Google's Pub/Sub service agent.
resource "google_project_service_identity" "pubsub" {
  provider = google-beta
  service  = "pubsub.googleapis.com"
}

resource "google_bigquery_dataset_iam_member" "pubsub_writes_bronze" {
  dataset_id = google_bigquery_dataset.layers["bronze"].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_project_service_identity.pubsub.email}"
}

# --- Cloud Run, Artifact Registry and deploys ------------------------------------

resource "google_cloud_run_v2_job_iam_member" "scheduler_runs_poller" {
  name     = google_cloud_run_v2_job.poller.name
  location = var.region
  role     = "roles/run.invoker"
  member   = google_service_account.sa["scheduler"].member
}

resource "google_storage_bucket_iam_member" "deployer_reads_source" {
  bucket = google_storage_bucket.build_source.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.sa["deployer"].member
}

resource "google_artifact_registry_repository_iam_member" "deployer_push" {
  repository = google_artifact_registry_repository.images.name
  location   = var.region
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.sa["deployer"].member
}

# Deploying a job that runs as sa-poller requires permission to "act as" sa-poller.
resource "google_service_account_iam_member" "deployer_acts_as_poller" {
  service_account_id = google_service_account.sa["poller"].name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.sa["deployer"].member
}

# --- Dataform --------------------------------------------------------------------

resource "google_service_account_iam_member" "workflows_acts_as_dataform" {
  service_account_id = google_service_account.sa["dataform"].name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.sa["workflows"].member
}

# Google's own Dataform service agent runs queries by impersonating sa-dataform and
# reads the GitHub token to pull the repo.
resource "google_project_service_identity" "dataform" {
  provider = google-beta
  service  = "dataform.googleapis.com"
}

resource "google_service_account_iam_member" "dataform_agent_impersonates" {
  service_account_id = google_service_account.sa["dataform"].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_project_service_identity.dataform.email}"
}

resource "google_secret_manager_secret_iam_member" "dataform_agent_reads_token" {
  secret_id = google_secret_manager_secret.github_token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_project_service_identity.dataform.email}"
}
