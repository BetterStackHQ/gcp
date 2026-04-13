variable "project_id" {
  type        = string
  description = "GCP project ID where resources will be created"
}

variable "org_id" {
  type        = string
  default     = null
  description = "GCP organization ID. If set: org-level sink + IAM. If null: project-level only."
}

variable "source_token" {
  type        = string
  sensitive   = true
  description = "Better Stack source token"
}

variable "ingesting_host" {
  type        = string
  description = "Better Stack ingestion host (provided in your Better Stack source settings)"
}

variable "betterstack_sa_email" {
  type        = string
  default     = "gcp-integration@better-stack.iam.gserviceaccount.com"
  description = "Better Stack SA email for impersonation"
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "batch_count" {
  type    = number
  default = 100
}

variable "log_filter" {
  type        = string
  default     = ""
  description = "Initial inclusion filter for the log sink (Logging query language). Empty = all logs. Managed remotely via API after setup."
}
