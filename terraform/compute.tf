resource "google_artifact_registry_repository" "images" {
  repository_id = "weather-repo"
  location      = var.region
  format        = "DOCKER"

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 5
    }
  }

  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      older_than = "2592000s"
    }
  }

  depends_on = [google_project_service.apis]
}

# Terraform owns the job's shape (service account, env, limits); Cloud Build owns which
# image version runs. Hence the placeholder image and ignore_changes below.
resource "google_cloud_run_v2_job" "poller" {
  name                = "weather-poller"
  location            = var.region
  deletion_protection = false

  template {
    task_count = 1

    template {
      service_account = google_service_account.sa["poller"].email
      max_retries     = 1
      timeout         = "120s"

      containers {
        image = "us-docker.pkg.dev/cloudrun/container/job:latest"

        env {
          name  = "PUBSUB_TOPIC"
          value = google_pubsub_topic.readings.id
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  depends_on = [google_project_service.apis]
}
