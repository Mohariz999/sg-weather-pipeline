variable "project_id" {
  description = "GCP project that hosts the pipeline."
  type        = string
}

variable "region" {
  description = "Region for every regional resource. BigQuery datasets use the same location."
  type        = string
  default     = "asia-southeast1"
}

variable "billing_account_id" {
  description = "Billing account the project is linked to (for the budget alert), e.g. 012345-6789AB-CDEF01."
  type        = string
}

variable "budget_amount" {
  description = "Monthly budget. Alerts fire at 50%, 90% and 100% of this, counting spend before credits."
  type        = number
  default     = 10
}

variable "budget_currency" {
  description = "Leave null to use the billing account's own currency; if set, it must match it."
  type        = string
  default     = null
}

variable "alert_email" {
  description = "Email address that receives budget and pipeline alerts."
  type        = string
}

variable "github_repo_url" {
  description = "HTTPS URL of the GitHub repo Dataform compiles from. Leave empty on the first apply; see docs/setup.md."
  type        = string
  default     = ""
}

variable "enable_poller_schedule" {
  description = "Run the data.gov.sg poller every 5 minutes."
  type        = bool
  default     = true
}

variable "enable_daily_transform" {
  description = "Run the Dataform transform workflow every morning. Turn on after the legacy migration has loaded."
  type        = bool
  default     = false
}
