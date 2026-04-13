output "service_account_email" {
  description = "Customer SA email (impersonated by Better Stack)"
  value       = google_service_account.betterstack.email
}

output "dataflow_job_id" {
  description = "Dataflow job ID"
  value       = google_dataflow_flex_template_job.logs.job_id
}

output "log_sink_name" {
  description = "Log sink name"
  value       = local.org_mode ? google_logging_organization_sink.org_sink[0].name : google_logging_project_sink.project_sink[0].name
}

output "log_sink_mode" {
  description = "Whether the sink is org-level or project-level"
  value       = local.org_mode ? "organization" : "project"
}

output "project_id" {
  description = "GCP project ID (configure in Better Stack)"
  value       = var.project_id
}

output "project_number" {
  description = "GCP project number (configure in Better Stack)"
  value       = data.google_project.project.number
}

output "wif_pool_name" {
  description = "Full resource name of the WIF pool (needed for remote API authentication)"
  value       = google_iam_workload_identity_pool.betterstack.name
}
