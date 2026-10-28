resource "google_monitoring_notification_channel" "email" {
  display_name = "Pipeline alerts"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
  depends_on = [google_project_service.apis]
}

# Measured before credits, so you see how fast the free credits are being used.
resource "google_billing_budget" "monthly" {
  billing_account = var.billing_account_id
  display_name    = "sg-weather-pipeline monthly"

  budget_filter {
    projects               = ["projects/${data.google_project.this.number}"]
    credit_types_treatment = "EXCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = var.budget_currency
      units         = tostring(var.budget_amount)
    }
  }

  dynamic "threshold_rules" {
    for_each = [0.5, 0.9, 1.0]
    content {
      threshold_percent = threshold_rules.value
    }
  }

  all_updates_rule {
    monitoring_notification_channels = [google_monitoring_notification_channel.email.id]
  }
}

# The daily Dataform run failed (a model errored or a data-quality assertion failed).
resource "google_monitoring_alert_policy" "transform_failed" {
  display_name          = "Weather pipeline: daily transform failed"
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.id]

  conditions {
    display_name = "Workflow execution failed"
    condition_threshold {
      filter          = "resource.type = \"workflows.googleapis.com/Workflow\" AND metric.type = \"workflows.googleapis.com/finished_execution_count\" AND metric.label.status = \"FAILED\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }
}

# The poller failed to fetch or publish at least one metric.
resource "google_monitoring_alert_policy" "poller_failed" {
  display_name          = "Weather pipeline: poller job failed"
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.id]

  conditions {
    display_name = "Cloud Run job execution failed"
    condition_threshold {
      filter          = "resource.type = \"cloud_run_job\" AND resource.label.job_name = \"${google_cloud_run_v2_job.poller.name}\" AND metric.type = \"run.googleapis.com/job/completed_execution_count\" AND metric.label.result = \"failed\""
      comparison      = "COMPARISON_GT"
      threshold_value = 2
      duration        = "0s"
      aggregations {
        alignment_period   = "1800s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }
}

# Messages are piling up: the BigQuery subscription cannot write (permissions, schema).
resource "google_monitoring_alert_policy" "ingestion_backlog" {
  display_name          = "Weather pipeline: ingestion backlog"
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.id]

  conditions {
    display_name = "Oldest unacked message older than 30 minutes"
    condition_threshold {
      filter          = "resource.type = \"pubsub_subscription\" AND resource.label.subscription_id = \"${google_pubsub_subscription.bigquery.name}\" AND metric.type = \"pubsub.googleapis.com/subscription/oldest_unacked_message_age\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1800
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }
}
