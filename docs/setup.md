# Setup

Every command runs in **Cloud Shell**, which already has `gcloud`, `bq`, `python3` and `git` installed (Terraform is installed in step 3). Replace `<project-id>` and `<github-user>` with your own values.

## 1. Project and billing

1. In the Cloud Console, create a project and note its project ID.
2. Link it to the billing account that holds your credits: **Billing → Link a billing account**.
3. Note the billing account ID (`XXXXXX-XXXXXX-XXXXXX`) under **Billing → Account management**.

## 2. Clone and configure

Create a GitHub fine-grained personal access token first: **Settings → Developer settings → Fine-grained tokens**, limited to this repository, with **Contents: read and write**. For a private repository, `git clone` asks for it (paste it as the password). Dataform needs the same token in step 5.

```bash
git clone https://github.com/<github-user>/sg-weather-pipeline.git
cd sg-weather-pipeline

export PROJECT_ID=<project-id>
export REGION=asia-southeast1
gcloud config set project "$PROJECT_ID"

# Terraform enables every other API, but it needs these two before it can start.
gcloud services enable cloudresourcemanager.googleapis.com serviceusage.googleapis.com

# Terraform state bucket (created once, by hand)
gcloud storage buckets create "gs://${PROJECT_ID}-tfstate" --location="$REGION" --uniform-bucket-level-access
gcloud storage buckets update "gs://${PROJECT_ID}-tfstate" --versioning

cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# edit project_id, billing_account_id and alert_email
```

## 3. First Terraform apply

```bash
# Terraform is not pre-installed in Cloud Shell. Installing into ~/bin keeps it across sessions.
mkdir -p ~/bin && curl -sSLo /tmp/tf.zip https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip \
  && unzip -o -q /tmp/tf.zip -d ~/bin && export PATH="$HOME/bin:$PATH" && terraform version
```

```bash
cd terraform
terraform init -backend-config="bucket=${PROJECT_ID}-tfstate"
terraform apply
cd ..
```

This creates the APIs, network, buckets, datasets and bronze tables, Pub/Sub, service accounts and IAM, the Cloud Run job, the Workflows definition, the schedules, the alerts and the budget. The Dataform repository is skipped until step 5. The daily transform schedule starts paused.

Email alert channels need no verification; alerts start arriving when a budget threshold or alert policy fires.

## 4. Deploy the poller

```bash
gcloud builds submit --config=cloudbuild.yaml \
  --substitutions=SHORT_SHA=manual \
  --gcs-source-staging-dir="gs://${PROJECT_ID}-build-source/source" \
  --service-account="projects/${PROJECT_ID}/serviceAccounts/sa-deployer@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud run jobs execute weather-poller --region="$REGION" --wait
bq query --use_legacy_sql=false 'SELECT COUNT(*) AS messages, MAX(publish_time) AS latest FROM bronze.weather_readings_raw'
```

The scheduler now runs the poller every 5 minutes, and the BigQuery subscription writes each message into `bronze.weather_readings_raw` within seconds.

## 5. Connect Dataform to GitHub

1. Create a GitHub fine-grained personal access token with **Contents: read and write** on this repository.
2. Store it in Secret Manager. The token never goes into Terraform:
   ```bash
   printf '%s' 'github_pat_...' | gcloud secrets versions add dataform-github-token --data-file=-
   ```
3. In `terraform/terraform.tfvars`, set `github_repo_url = "https://github.com/<github-user>/sg-weather-pipeline.git"` and apply again:
   ```bash
   cd terraform && terraform apply && cd ..
   ```

## 6. Run the migration

Follow [migration-runbook.md](migration-runbook.md). In short:

```bash
bash scripts/run_migration.sh
```

Once reconciliation shows every file `MATCHED`, set `enable_daily_transform = true` in `terraform.tfvars` and apply. From then on the transform runs every day at 06:00 SGT.

## 7. Continuous deployment

In **Cloud Build → Triggers**, connect the GitHub repository (2nd gen) and create a trigger:
- Event: push to `main`
- Configuration: `cloudbuild.yaml`
- Service account: `sa-deployer@<project-id>.iam.gserviceaccount.com`

GitHub Actions (`.github/workflows/ci.yml`) runs lint, tests, `dataform compile` and `terraform validate` on every pull request.

### Terraform from GitHub Actions

`.github/workflows/terraform.yml` plans every pull request that touches `terraform/` or `orchestration/` (the plan is posted as a PR comment) and applies on merge to `main`. It logs in through Workload Identity Federation, so there are no service-account keys.

One-time bootstrap:

1. Add to `terraform/terraform.tfvars` and apply locally:
   ```hcl
   github_repository    = "<github-user>/sg-weather-pipeline"
   github_repository_id = "<numeric repo id>"   # gh api repos/<github-user>/sg-weather-pipeline --jq .id
   ```
2. Grant the two CI identities access to the budget, which lives on the billing account:
   ```bash
   gcloud billing accounts add-iam-policy-binding <billing-account-id> \
     --member="serviceAccount:sa-terraform-plan@${PROJECT_ID}.iam.gserviceaccount.com" --role=roles/billing.viewer
   gcloud billing accounts add-iam-policy-binding <billing-account-id> \
     --member="serviceAccount:sa-terraform-apply@${PROJECT_ID}.iam.gserviceaccount.com" --role=roles/billing.costsManager
   ```
3. Set the repository variables and secrets:
   ```bash
   gh variable set GCP_PROJECT_ID -b "$PROJECT_ID"
   gh variable set GCP_WORKLOAD_IDENTITY_PROVIDER -b "$(terraform -chdir=terraform output -raw github_workload_identity_provider)"
   gh variable set TF_BUDGET_AMOUNT -b 20
   gh secret set TF_BILLING_ACCOUNT_ID    # prompts for the value
   gh secret set TF_ALERT_EMAIL
   gh api -X PUT repos/<github-user>/sg-weather-pipeline/environments/production
   ```
4. Optional: in **GitHub → Settings → Environments → production**, add yourself as a required reviewer so every apply waits for approval. This needs a public repository or a paid GitHub plan.

From then on, change infrastructure through pull requests rather than local applies.

## 8. Dashboard

1. In Looker Studio, add a **BigQuery** data source pointing at `gold.island_daily_summary` and `gold.daily_station_weather`.
2. Suggested pages:
   - island trend: temperature range and rainfall by day
   - station map: average temperature and total rain by station
   - data quality: stations reporting per day, and the number of hours each station reported

`lookml/` holds the same metric definitions as a LookML project, for a Looker instance connected to BigQuery as `sg_weather_bigquery`.

## Teardown

```bash
cd terraform && terraform destroy
```

Then delete the `-tfstate` bucket, or shut down the project.
