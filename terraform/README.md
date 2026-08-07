# Better Stack GCP Integration — Terraform Module

Sets up metrics access and log forwarding for your GCP project or organization.

## What this creates

- **Service account** (`betterstack-integration`) with read roles for
  metrics, compute metadata, and resource discovery
- **Cross-account impersonation** so Better Stack can use short-lived tokens
  (no static keys)
- **Log sink** that captures logs and routes them to Pub/Sub
- **Pub/Sub topic + pull subscription** for log delivery
- **Dataflow job** that batches and forwards logs to Better Stack

Two modes:
- **Org mode** (`org_id` set): org-level IAM roles + org-level log sink covering
  all projects (including future ones)
- **Project mode** (`org_id` omitted): project-level IAM roles + project-level
  log sink (single project only)

## Usage

```hcl
# Org mode (all projects):
module "betterstack" {
  source        = "github.com/BetterStackHQ/gcp//terraform"
  project_id    = "my-project"
  org_id        = "123456789"
  source_token  = "<source-token>"
  ingesting_host = "<ingesting-host>"
}

# Project mode (single project only):
module "betterstack" {
  source        = "github.com/BetterStackHQ/gcp//terraform"
  project_id    = "my-project"
  source_token  = "<source-token>"
  ingesting_host = "<ingesting-host>"
}
```

## Connecting the source with Terraform

The `source_token` and `ingesting_host` above come from a Better Stack source, and the `project_id` / `project_number` outputs have to be configured back in Better Stack.

Both handoffs can be Terraform-managed with the [Better Stack Telemetry provider](https://registry.terraform.io/providers/BetterStackHQ/logtail/latest),
so the whole integration applies in a single run. See [Connecting a GCP project to a source](https://registry.terraform.io/providers/BetterStackHQ/logtail/latest/docs/guides/connect-gcp-project) for details.

## Variables

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `project_id` | GCP project ID where resources are created | Yes | — |
| `org_id` | GCP org ID. If set: org-level. If omitted: project-level. | No | `null` |
| `source_token` | Better Stack source token | Yes | — |
| `ingesting_host` | Better Stack ingestion host | Yes | — |
| `betterstack_sa_email` | Better Stack SA email for impersonation | No | `gcp-integration@better-stack.iam.gserviceaccount.com` |
| `region` | GCP region for Dataflow | No | `europe-west1` |
| `batch_count` | Log entries per batch | No | `100` |

## Outputs

| Name | Description |
|------|-------------|
| `project_id` | GCP project ID (configure in Better Stack) |
| `project_number` | GCP project number (configure in Better Stack) |
| `service_account_email` | Customer SA email impersonated by Better Stack |
| `dataflow_job_id` | Dataflow job ID |
| `log_sink_name` | Log sink name |
| `log_sink_mode` | `organization` or `project` |
| `wif_pool_name` | Full resource name of the WIF pool |

## Prerequisites

The user running `terraform apply` needs:

- **Project-level**: `roles/owner` or `roles/editor` on the project
- **Org-level** (only if `org_id` is set): `roles/resourcemanager.organizationAdmin`

## Teardown

```bash
terraform destroy
```
