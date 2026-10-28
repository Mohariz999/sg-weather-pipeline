# Terraform CI/CD from GitHub Actions, with no service-account keys.
#
# GitHub issues each workflow run a short-lived OIDC token. Workload Identity Federation
# exchanges it for Google credentials, but only for this repository (matched by its
# numeric ID). Two identities keep the blast radius small:
#   sa-terraform-plan   read-only; any workflow run in the repo (pull requests included)
#   sa-terraform-apply  can change infrastructure; only runs on the main branch
#
# Bootstrap: the first apply of this file is run by a person. Billing-account roles for
# the budget are granted by hand (docs/setup.md), as they sit outside the project.
locals {
  cicd_enabled = var.github_repository_id != ""

  plan_roles = [
    "roles/viewer",
    "roles/iam.securityReviewer",              # read IAM policies on buckets, datasets, topics
    "roles/serviceusage.serviceUsageConsumer", # requests are billed to this project
  ]

  # Terraform creates service accounts, grants IAM on many resource types and attaches
  # service accounts to Cloud Run, Workflows and Scheduler, so this set is necessarily
  # broad. What limits it is who can use it: main-branch runs of this repository only.
  apply_roles = [
    "roles/editor",
    "roles/resourcemanager.projectIamAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/iam.workloadIdentityPoolAdmin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/storage.admin",
    "roles/bigquery.admin",
    "roles/pubsub.admin",
    "roles/run.admin",
    "roles/secretmanager.admin",
    "roles/artifactregistry.admin",
    "roles/dataform.admin",
  ]
}

resource "google_iam_workload_identity_pool" "github" {
  count = local.cicd_enabled ? 1 : 0

  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
  depends_on                = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  count = local.cicd_enabled ? 1 : 0

  workload_identity_pool_id          = google_iam_workload_identity_pool.github[0].workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"          = "assertion.sub"
    "attribute.repository"    = "assertion.repository"
    "attribute.repository_id" = "assertion.repository_id"
    "attribute.ref"           = "assertion.ref"
    "attribute.event_name"    = "assertion.event_name"
  }

  # Tokens from any other repository are rejected outright.
  attribute_condition = "assertion.repository_id == '${var.github_repository_id}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "terraform" {
  for_each = local.cicd_enabled ? toset(["plan", "apply"]) : toset([])

  account_id   = "sa-terraform-${each.key}"
  display_name = each.key == "plan" ? "Terraform plan from GitHub Actions (read-only)" : "Terraform apply from GitHub Actions (main branch only)"
}

resource "google_project_iam_member" "terraform_plan" {
  for_each = local.cicd_enabled ? toset(local.plan_roles) : toset([])

  project = var.project_id
  role    = each.value
  member  = google_service_account.terraform["plan"].member
}

resource "google_project_iam_member" "terraform_apply" {
  for_each = local.cicd_enabled ? toset(local.apply_roles) : toset([])

  project = var.project_id
  role    = each.value
  member  = google_service_account.terraform["apply"].member
}

# The state bucket is created by hand before Terraform exists, so it isn't a resource here.
resource "google_storage_bucket_iam_member" "terraform_state" {
  for_each = local.cicd_enabled ? {
    plan  = "roles/storage.objectViewer" # plans run with -lock=false, so read-only is enough
    apply = "roles/storage.objectAdmin"
  } : {}

  bucket = "${var.project_id}-tfstate"
  role   = each.value
  member = google_service_account.terraform[each.key].member
}

# Any workflow run in the repository may plan.
resource "google_service_account_iam_member" "github_plan" {
  count = local.cicd_enabled ? 1 : 0

  service_account_id = google_service_account.terraform["plan"].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github[0].name}/attribute.repository_id/${var.github_repository_id}"
}

# Only runs on main may apply.
resource "google_service_account_iam_member" "github_apply" {
  count = local.cicd_enabled ? 1 : 0

  service_account_id = google_service_account.terraform["apply"].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github[0].name}/attribute.ref/refs/heads/main"
}
