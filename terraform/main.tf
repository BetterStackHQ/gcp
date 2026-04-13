data "google_project" "project" {
  project_id = var.project_id
}

locals {
  sa_account_id    = "betterstack-integration"
  org_mode         = var.org_id != null
  source_id        = split(".", var.ingesting_host)[0]
  sink_name        = "betterstack-logs-sink-${local.source_id}"
  topic_name       = "betterstack-logs-${local.source_id}"
  topic_deadletter = "betterstack-logs-deadletter-${local.source_id}"
  sub_name         = "betterstack-logs-pull-${local.source_id}"
  dataflow_name    = "betterstack-logs-${local.source_id}"

  apis = [
    "dataflow.googleapis.com",
    "pubsub.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "compute.googleapis.com",
    "cloudasset.googleapis.com",
    "iamcredentials.googleapis.com",
  ]

  iam_roles = [
    "roles/monitoring.viewer",
    "roles/compute.viewer",
    "roles/cloudasset.viewer",
    "roles/browser",
    "roles/logging.configWriter",
    "roles/logging.viewer",
    "roles/pubsub.editor",
  ]
}

# --- APIs ---

resource "google_project_service" "apis" {
  for_each = toset(local.apis)
  project  = var.project_id
  service  = each.value
}

# --- Service Account ---

resource "google_service_account" "betterstack" {
  project      = var.project_id
  account_id   = local.sa_account_id
  display_name = "Better Stack Integration"
}

# --- IAM roles (org-level or project-level) ---

resource "google_organization_iam_member" "org_roles" {
  for_each = local.org_mode ? toset(local.iam_roles) : toset([])
  org_id   = var.org_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.betterstack.email}"
}

resource "google_project_iam_member" "project_roles" {
  for_each = local.org_mode ? toset([]) : toset(local.iam_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.betterstack.email}"
}

# --- Workload Identity Federation ---

resource "google_iam_workload_identity_pool" "betterstack" {
  project                   = var.project_id
  workload_identity_pool_id = "betterstack-pool"
  display_name              = "Better Stack Integration"
}

resource "google_iam_workload_identity_pool_provider" "betterstack" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.betterstack.workload_identity_pool_id
  workload_identity_pool_provider_id = "betterstack-provider"

  oidc {
    issuer_uri        = "https://accounts.google.com"
    allowed_audiences = ["https://iam.googleapis.com/${google_iam_workload_identity_pool.betterstack.name}/providers/betterstack-provider"]
  }

  attribute_mapping = {
    "google.subject"     = "assertion.sub"
    "attribute.sa_email" = "assertion.email"
  }

  attribute_condition = "assertion.email=='${var.betterstack_sa_email}'"
}

resource "google_service_account_iam_member" "wif_impersonation" {
  service_account_id = google_service_account.betterstack.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.betterstack.name}/attribute.sa_email/${var.betterstack_sa_email}"
}

# --- Pub/Sub ---

resource "google_pubsub_topic" "logs" {
  project = var.project_id
  name    = local.topic_name
}

resource "google_pubsub_topic" "deadletter" {
  project = var.project_id
  name    = local.topic_deadletter
}

resource "google_pubsub_subscription" "pull" {
  project              = var.project_id
  name                 = local.sub_name
  topic                = google_pubsub_topic.logs.id
  ack_deadline_seconds = 60
}

# --- Log sink (org-level or project-level) ---

resource "google_logging_organization_sink" "org_sink" {
  count            = local.org_mode ? 1 : 0
  name             = local.sink_name
  org_id           = var.org_id
  destination      = "pubsub.googleapis.com/${google_pubsub_topic.logs.id}"
  include_children = true
  filter           = var.log_filter

  exclusions {
    name   = "exclude-betterstack-dataflow"
    filter = "resource.type=\"dataflow_step\" AND resource.labels.job_name=~\"^betterstack-logs-\""
  }

  # Filter and exclusions are managed remotely via the Logging API after initial setup.
  # Ignore changes so Terraform doesn't revert remote filter reconfiguration.
  lifecycle {
    ignore_changes = [filter, exclusions]
  }
}

resource "google_logging_project_sink" "project_sink" {
  count       = local.org_mode ? 0 : 1
  name        = local.sink_name
  project     = var.project_id
  destination = "pubsub.googleapis.com/${google_pubsub_topic.logs.id}"
  filter      = var.log_filter

  exclusions {
    name   = "exclude-betterstack-dataflow"
    filter = "resource.type=\"dataflow_step\" AND resource.labels.job_name=~\"^betterstack-logs-\""
  }

  # Filter and exclusions are managed remotely via the Logging API after initial setup.
  # Ignore changes so Terraform doesn't revert remote filter reconfiguration.
  lifecycle {
    ignore_changes = [filter, exclusions]
  }
}

resource "google_pubsub_topic_iam_member" "sink_writer" {
  project = var.project_id
  topic   = google_pubsub_topic.logs.name
  role    = "roles/pubsub.publisher"
  member  = local.org_mode ? google_logging_organization_sink.org_sink[0].writer_identity : google_logging_project_sink.project_sink[0].writer_identity
}

# --- Dataflow worker SA ---

resource "google_service_account" "dataflow" {
  project      = var.project_id
  account_id   = "betterstack-dataflow"
  display_name = "Better Stack Dataflow Worker"
}

resource "google_project_iam_member" "dataflow_roles" {
  for_each = toset([
    "roles/dataflow.worker",
    "roles/storage.objectAdmin",
    "roles/pubsub.subscriber",
    "roles/pubsub.viewer",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}

# --- Dataflow job ---

resource "google_dataflow_flex_template_job" "logs" {
  project                 = var.project_id
  name                    = local.dataflow_name
  container_spec_gcs_path = "gs://betterstack/pubsub-to-betterstack.json"
  region                  = var.region
  service_account_email   = google_service_account.dataflow.email

  parameters = {
    input_subscription          = google_pubsub_subscription.pull.id
    better_stack_source_token   = var.source_token
    better_stack_ingesting_host = var.ingesting_host
    batch_size                  = tostring(var.batch_count)
  }

  depends_on = [google_project_service.apis, google_project_iam_member.dataflow_roles]
}
