# Landing zone for the legacy archive (CSV files + manifest). Versioned so an
# accidental overwrite during migration can be rolled back.
resource "google_storage_bucket" "landing" {
  name                        = "${var.project_id}-landing"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  versioning {
    enabled = true
  }

  depends_on = [google_project_service.apis]
}

# Scratch bucket for Dataproc dependencies and BigQuery-connector temp files.
resource "google_storage_bucket" "dataproc_temp" {
  name                        = "${var.project_id}-dataproc-temp"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.apis]
}
