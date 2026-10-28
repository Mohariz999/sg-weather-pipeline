# --- Dataform repository ---------------------------------------------------------

# Terraform creates the empty secret; the token itself is added with gcloud so it
# never ends up in Terraform state (docs/setup.md step 6).
resource "google_secret_manager_secret" "github_token" {
  secret_id = "dataform-github-token"

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_dataform_repository" "weather" {
  provider = google-beta
  count    = var.github_repo_url == "" ? 0 : 1

  name            = "weather-dataform"
  region          = var.region
  service_account = google_service_account.sa["dataform"].email

  git_remote_settings {
    url                                 = var.github_repo_url
    default_branch                      = "main"
    authentication_token_secret_version = "${google_secret_manager_secret.github_token.id}/versions/latest"
  }

  depends_on = [
    google_service_account_iam_member.dataform_agent_impersonates,
    google_secret_manager_secret_iam_member.dataform_agent_reads_token,
  ]
}

# --- Workflows -------------------------------------------------------------------

resource "google_workflows_workflow" "daily_transform" {
  name            = "weather-daily-transform"
  region          = var.region
  description     = "Compiles the Dataform project from Git and runs it, failing loudly on any assertion."
  service_account = google_service_account.sa["workflows"].id
  source_contents = file("${path.module}/../orchestration/daily_transform.yaml")

  user_env_vars = {
    DATAFORM_REPOSITORY = "weather-dataform"
  }

  depends_on = [google_project_service.apis]
}

# --- Cloud Scheduler -------------------------------------------------------------

resource "google_cloud_scheduler_job" "poller" {
  name      = "weather-poller-every-5-min"
  region    = var.region
  schedule  = "*/5 * * * *"
  time_zone = "Asia/Singapore"
  paused    = !var.enable_poller_schedule

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.poller.name}:run"

    oauth_token {
      service_account_email = google_service_account.sa["scheduler"].email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }
}

resource "google_cloud_scheduler_job" "daily_transform" {
  name      = "weather-daily-transform"
  region    = var.region
  schedule  = "0 6 * * *"
  time_zone = "Asia/Singapore"
  paused    = !var.enable_daily_transform

  http_target {
    http_method = "POST"
    uri         = "https://workflowexecutions.googleapis.com/v1/${google_workflows_workflow.daily_transform.id}/executions"
    body        = base64encode(jsonencode({ argument = jsonencode({ check_freshness = "true" }) }))

    oauth_token {
      service_account_email = google_service_account.sa["scheduler"].email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }
}
