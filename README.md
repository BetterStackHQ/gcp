# Better Stack GCP Integration

This repository holds two independent setups for connecting Google Cloud to Better Stack:

- **[Log and metrics ingestion](#log-and-metrics-ingestion)** sends a project's or organization's logs and metrics to Better Stack, with `setup.sh` or the Terraform module.
- **[AI SRE](#ai-sre)** gives Better Stack AI SRE read-only access to one project, with `ai-sre-setup.sh`.

## Repository Structure

| Directory | Description |
|-----------|-------------|
| [setup.sh](setup.sh) | Bash setup script for quick deployment |
| [ai-sre-setup.sh](ai-sre-setup.sh) | Bash setup script for Better Stack AI SRE's read-only access ([AI SRE](#ai-sre)) |
| [terraform/](terraform/README.md) | Terraform module for infrastructure-as-code deployment |

## Log and metrics ingestion

### Getting Started

To get started with Better Stack on GCP, [create a new GCP Source in Better Stack](https://telemetry.betterstack.com/team/sources/new?platform=gcp) and note the **ingesting host** and **source token** from the source configuration.

For deployment, choose either the [setup script](#setup-script) or the [Terraform module](#terraform).

### Ingested Data

When you deploy the integration you get:

- Automatic ingestion of all GCP Cloud Logging entries into Better Stack.
- Automatic ingestion of Cloud Monitoring metrics (compute, networking, storage, and more).
- Support for org-level deployment covering all projects, including future ones.
- Remote log filter management — configure which logs are forwarded without redeploying.

### Setup Script

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

#### Optional arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `--region` | `europe-west1` | GCP region for the Dataflow job |
| `--batch-count` | `100` | Log entries per batch sent to Better Stack |

#### Teardown

```bash
./setup.sh --teardown \
  --project=my-project \
  --ingesting-host=s4191.g1.betterstackdata.com \
  --org-id=123456789
```

### Terraform

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

### What Gets Created

- **Service accounts** — `betterstack-integration` (metrics and log sink management, impersonated by Better Stack via WIF) and `betterstack-dataflow` (runs the log forwarding pipeline).
- **Workload Identity Federation** — cross-project authentication using short-lived tokens. No static keys.
- **Log sink** — captures Cloud Logging entries and routes them to Pub/Sub. Supports org-level or project-level scope.
- **Pub/Sub topic + subscription** — buffered log delivery between the sink and the forwarding pipeline.
- **Dataflow job** — batches log entries from Pub/Sub and forwards them to Better Stack.

### Prerequisites

The user running the setup needs:

- **Project-level**: `roles/owner` or `roles/editor` on the GCP project
- **Org-level** (only if deploying with `--org-id`): `roles/resourcemanager.organizationAdmin` on the organization

### Log Filter Management

After deployment, Better Stack can remotely configure which logs are forwarded by updating the Logging filter from your source's
settings page.

## AI SRE

`ai-sre-setup.sh` gives Better Stack AI SRE read-only access to one Google Cloud project. It's separate from the ingestion setup and never changes its resources.

### Getting Started

In Better Stack, go to AI SRE → Integrations → Google Cloud and add an integration for your project. Copy the setup command it shows and run it as an owner of the project, for example in [Cloud Shell](https://shell.cloud.google.com):

```bash
curl -fsSL https://raw.githubusercontent.com/BetterStackHQ/gcp/main/ai-sre-setup.sh | bash -s -- --ai-sre YOUR_TOKEN --project my-project
```

It takes a few minutes, because Google needs time to apply the new access and the script waits for it. When it finishes, the integration in Better Stack turns **Active**.

If the script stops with an error, fix what it says and run the same command again. It picks up where it stopped.

### What Gets Created

- **Workload identity pool** `betterstack-ai-sre-pool`, with one identity provider per integration (`betterstack-ai-sre-<8 hex>`). A provider accepts only Better Stack's AI SRE identity, and only for its own integration.
- **Service account** `betterstack-ai-sre`, which Better Stack uses through short-lived tokens. No keys are created. It gets these roles on the project: `roles/logging.viewer`, `roles/monitoring.viewer`, `roles/run.viewer`, `roles/container.viewer`, `roles/cloudtrace.user`, `roles/errorreporting.viewer`, `roles/browser` and `roles/mcp.toolUser`.
- **APIs** `iam`, `iamcredentials`, `sts` and `logging`, enabled if they're off.

### Prerequisites

- `roles/owner` on the project. `roles/editor` isn't enough: it can't change IAM policies.
- `gcloud`, `curl` and `python3`. Cloud Shell has all of them.

### Removal

Removing the integration in Better Stack ends its access, and the confirmation shows the command that removes what the script created. Run it as an owner of the project:

```bash
curl -fsSL https://raw.githubusercontent.com/BetterStackHQ/gcp/main/ai-sre-setup.sh | bash -s -- \
  --ai-sre-remove betterstack-ai-sre-1a2b3c4d --project my-project
```
