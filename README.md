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

## AI SRE

`--ai-sre` gives [Better Stack AI SRE](https://betterstack.com) read-only access to your projects through Google's MCP servers. Create a GCP integration in Better Stack, then run the command it shows, for example in Cloud Shell:

```bash
curl -fsSL https://raw.githubusercontent.com/BetterStackHQ/gcp/main/setup.sh | bash -s -- --ai-sre YOUR_TOKEN
```

The token is valid for 24 hours and works once. The first project defaults to the current `gcloud` project; pass `--project <id>` to choose another. To connect a further project, use **Add project** on the integration and run its command, which adds `--project <id>`.

### What gets created

In the first project:

- **Workload identity pool** `betterstack-pool`, reused if the ingestion setup already created it.
- **Identity provider** `betterstack-ai-sre` in that pool. It trusts Google-signed ID tokens (`https://accounts.google.com`) only from `ai-sre-caller@better-stack.iam.gserviceaccount.com`, and only with the audience generated for your integration. The ingestion provider is left as it is.
- **Service account** `betterstack-ai-sre@<project>.iam.gserviceaccount.com`, which Better Stack impersonates through that provider (`roles/iam.workloadIdentityUser`). No keys are created.

In every connected project, the service account gets read-only roles and the APIs behind each MCP server are enabled:

| Server | Roles | API |
|--------|-------|-----|
| Required | `roles/mcp.toolUser` | |
| Cloud Logging | `roles/logging.viewer` | `logging.googleapis.com` |
| Cloud Monitoring | `roles/monitoring.viewer` | `monitoring.googleapis.com` |
| Cloud Run | `roles/run.viewer` | `run.googleapis.com` |
| Resource Manager | `roles/browser` | `cloudresourcemanager.googleapis.com` |
| Cloud Trace (`--services cloudtrace`) | `roles/cloudtrace.user` | `cloudtrace.googleapis.com` |
| Error Reporting (`--services clouderrorreporting`) | `roles/errorreporting.viewer` | `clouderrorreporting.googleapis.com` |
| Kubernetes Engine (`--services container`) | `roles/container.clusterViewer` | `container.googleapis.com` |

The first project also enables `iam`, `iamcredentials` and `sts`. The script then registers the project with Better Stack, which checks that it can list the MCP tools before the integration turns active. New IAM grants can take a few minutes to apply, so the script retries for up to 3 minutes.

### Options

| Argument | Description |
|----------|-------------|
| `--ai-sre <token>` | Registration token from the GCP integration in Better Stack |
| `--project <id>` | Project to connect (default: the current `gcloud` project) |
| `--services <list>` | Optional servers, comma-separated: `cloudtrace`, `clouderrorreporting`, `container`. These may still be in Preview at Google. |
| `--audit-logs` | Turns on Data Access audit logs (`DATA_READ` for `mcp.googleapis.com`), so every MCP call is logged in your project. Off by default: they are billed as Cloud Logging ingestion. |
| `--api-url <url>` | Better Stack API base URL (default: `https://telemetry.betterstack.com`) |
| `--dry-run` | Prints every `gcloud` and `curl` call without running any. It assumes a first run, with placeholders for the audience and the project number. |

### Permissions and errors

The user running the script needs `roles/owner` on the project, or these roles: `roles/serviceusage.serviceUsageAdmin`, `roles/iam.workloadIdentityPoolAdmin`, `roles/iam.serviceAccountAdmin` and `roles/resourcemanager.projectIamAdmin` (only the last two in further projects). When a step is denied, the script names the missing permission and the role that grants it.

If your organization restricts identity providers with `constraints/iam.workloadIdentityPoolProviders`, creating the provider fails and the script prints the command that allows `https://accounts.google.com`, which needs `roles/orgpolicy.policyAdmin`:

```bash
gcloud resource-manager org-policies allow constraints/iam.workloadIdentityPoolProviders \
  https://accounts.google.com --project=my-project
```

Every step checks what already exists, so after any failure, fix the cause and run the same command again.

## Terraform

See the [Terraform module README](terraform/README.md) for full usage and variable reference.

```hcl
module "betterstack" {
  source         = "github.com/BetterStackHQ/gcp//terraform"
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

## Tests

`test/setup_test.sh` runs `setup.sh` against mocked `gcloud` and `curl` commands, so it needs no GCP project or Better Stack account (only `bash` and `python3`):

```bash
test/setup_test.sh
shellcheck setup.sh test/setup_test.sh
```

## Log Filter Management

After deployment, Better Stack can remotely configure which logs are forwarded by updating the Logging filter from your source's
settings page.

