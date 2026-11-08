# Better Stack GCP Integration

This repository contains setup scripts and Terraform modules for integrating your GCP project or organization with Better Stack.

## Repository Structure

| Directory | Description |
|-----------|-------------|
| [setup.sh](setup.sh) | Bash setup script for quick deployment |
| [ai-sre.sh](ai-sre.sh) | Bash setup script for Better Stack AI SRE's read-only access ([AI SRE](#ai-sre)) |
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

`ai-sre.sh` gives [Better Stack AI SRE](https://betterstack.com) read-only access to a project through Google's MCP servers. Create a GCP integration in Better Stack for the project, then run the command it shows, for example in Cloud Shell. It is separate from `setup.sh` and never touches the log and metrics ingestion setup:

```bash
curl -fsSL https://raw.githubusercontent.com/BetterStackHQ/gcp/main/ai-sre.sh | bash -s -- --ai-sre YOUR_TOKEN --project my-project
```

The token works once. Each integration connects one project, and the command only works for the project it was created for. To connect another project, add another integration. Several integrations, from one or more Better Stack teams, can connect the same project.

### What gets created

In the project:

- **Workload identity pool** `betterstack-ai-sre-pool`, its own: the ingestion setup's `betterstack-pool` and `betterstack-provider` are never read or changed.
- **Identity provider** `betterstack-ai-sre-<8 hex>` in that pool, one per integration, named after the integration's audience. It trusts Google-signed ID tokens (`https://accounts.google.com`) only from `ai-sre-caller@better-stack.iam.gserviceaccount.com`, and only with the audience generated for that integration.
- **Service account** `betterstack-ai-sre@<project>.iam.gserviceaccount.com`, shared by every AI SRE integration of the project, which Better Stack impersonates through their providers (`roles/iam.workloadIdentityUser`). No keys are created.

The service account gets read-only roles on the project, and the APIs behind each MCP server are enabled:

| Server | Roles | API |
|--------|-------|-----|
| Required | `roles/mcp.toolUser` | |
| Cloud Logging | `roles/logging.viewer` | `logging.googleapis.com` |
| Cloud Monitoring | `roles/monitoring.viewer` | `monitoring.googleapis.com` |
| Cloud Run | `roles/run.viewer` | `run.googleapis.com` |
| Resource Manager | `roles/browser` | `cloudresourcemanager.googleapis.com` |
| Cloud Trace | `roles/cloudtrace.user` | `cloudtrace.googleapis.com` |
| Error Reporting | `roles/errorreporting.viewer` | `clouderrorreporting.googleapis.com` |
| Kubernetes Engine | `roles/container.viewer` | `container.googleapis.com` |

The script also enables `iam`, `iamcredentials` and `sts`. The script then registers the project with Better Stack, which checks that it can list the MCP tools before the integration turns active. New IAM grants can take a few minutes to apply, so the script retries for up to 3 minutes.

### Options

| Argument | Description |
|----------|-------------|
| `--ai-sre <token>` | Registration token from the GCP integration in Better Stack |
| `--project <id>` | Project to connect (required): the one shown on the integration in Better Stack |
| `--audit-logs` | Turns on Data Access audit logs (`DATA_READ` for `mcp.googleapis.com`), so every MCP call is logged in your project. Off by default: they are billed as Cloud Logging ingestion. |
| `--api-url <url>` | Better Stack API base URL (default: `https://telemetry.betterstack.com`) |
| `--dry-run` | Prints every `gcloud` and `curl` call without running any. It assumes a first run, with placeholders for the audience, the provider and the project number. |

### Permissions and errors

The user running the script needs `roles/owner` on the project, or these roles: `roles/serviceusage.serviceUsageAdmin`, `roles/iam.workloadIdentityPoolAdmin`, `roles/iam.serviceAccountAdmin` and `roles/resourcemanager.projectIamAdmin`. When a step is denied, the script names the missing permission and the role that grants it.

If your organization restricts identity providers with `constraints/iam.workloadIdentityPoolProviders`, creating the provider fails and the script prints the command that allows `https://accounts.google.com`, which needs `roles/orgpolicy.policyAdmin`:

```bash
gcloud resource-manager org-policies allow constraints/iam.workloadIdentityPoolProviders \
  https://accounts.google.com --project=my-project
```

Every step checks what already exists, so after any failure, fix the cause and run the same command again. If Better Stack refuses the registration (for example, when the project is already connected to your team), the script deletes the provider it just created.

### Removal

A successful setup ends by printing the command that removes the integration's access:

```bash
curl -fsSL https://raw.githubusercontent.com/BetterStackHQ/gcp/main/ai-sre.sh | bash -s -- \
  --ai-sre-remove betterstack-ai-sre-<8 hex> --project my-project
```

It deletes that integration's provider. When no other AI SRE provider is left in the pool, it also removes the service account's roles and deletes the service account. The pool stays, so a later setup can reuse it (it grants nothing without a provider), and Data Access audit logs stay as they are. Add `--dry-run` to see the commands first. Removing the integration in Better Stack already ends its access: this only tidies up the project.

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

`test/ai_sre_test.sh` runs `ai-sre.sh` against mocked `gcloud` and `curl` commands, so it needs no GCP project or Better Stack account (only `bash` and `python3`):

```bash
test/ai_sre_test.sh
shellcheck ai-sre.sh test/ai_sre_test.sh
```

## Log Filter Management

After deployment, Better Stack can remotely configure which logs are forwarded by updating the Logging filter from your source's
settings page.

