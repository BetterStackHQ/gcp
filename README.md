# Better Stack GCP Integration

This repository contains setup scripts and Terraform modules for integrating your GCP project or organization with Better Stack.

## Repository Structure

| Directory | Description |
|-----------|-------------|
| [setup.sh](setup.sh) | Bash setup script for quick deployment |
| [terraform/](terraform/README.md) | Terraform module for infrastructure-as-code deployment |

## Getting Started

To get started with Better Stack on GCP, [create a new GCP Source in Better Stack](https://telemetry.betterstack.com/team/sources/new?platform=gcp) and note the **ingesting host** and **source token** from the source configuration.

For deployment, choose either the [setup script](#setup-script) or the [Terraform module](#terraform).

## Ingested Data

When you deploy the integration you get:

- Automatic ingestion of all GCP Cloud Logging entries into Better Stack.
- Automatic ingestion of Cloud Monitoring metrics (compute, networking, storage, and more).
- Support for org-level deployment covering all projects, including future ones.
- Remote log filter management — configure which logs are forwarded without redeploying.

## Setup Script

The fastest way to deploy. Requires the [gcloud CLI](https://cloud.google.com/sdk/docs/install).

```bash
# Org mode (all projects, including future ones):
./setup.sh \
  --project=my-project \
  --org-id=123456789 \
  --source-token=YOUR_SOURCE_TOKEN \
  --ingesting-host=s4191.g1.betterstackdata.com

# Project mode (single project only):
./setup.sh \
  --project=my-project \
  --source-token=YOUR_SOURCE_TOKEN \
  --ingesting-host=s4191.g1.betterstackdata.com
```

### Optional arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `--region` | `europe-west1` | GCP region for the Dataflow job |
| `--batch-count` | `100` | Log entries per batch sent to Better Stack |

### Teardown

```bash
./setup.sh --teardown \
  --project=my-project \
  --ingesting-host=s4191.g1.betterstackdata.com \
  --org-id=123456789
```

## Terraform

See the [Terraform module README](terraform/README.md) for full usage and variable reference.

```hcl
module "betterstack" {
  source         = "github.com/betterstack/gcp-integration//terraform"
  project_id     = "my-project"
  org_id         = "123456789"
  source_token   = var.source_token
  ingesting_host = var.ingesting_host
}
```

## What Gets Created

- **Service accounts** — `betterstack-integration` (metrics and log sink management, impersonated by Better Stack via WIF) and `betterstack-dataflow` (runs the log forwarding pipeline).
- **Workload Identity Federation** — cross-project authentication using short-lived tokens. No static keys.
- **Log sink** — captures Cloud Logging entries and routes them to Pub/Sub. Supports org-level or project-level scope.
- **Pub/Sub topic + subscription** — buffered log delivery between the sink and the forwarding pipeline.
- **Dataflow job** — batches log entries from Pub/Sub and forwards them to Better Stack.

## Prerequisites

The user running the setup needs:

- **Project-level**: `roles/owner` or `roles/editor` on the GCP project
- **Org-level** (only if deploying with `--org-id`): `roles/resourcemanager.organizationAdmin` on the organization

## Log Filter Management

After deployment, Better Stack can remotely configure which logs are forwarded by updating the Logging filter from your source's
settings page.

