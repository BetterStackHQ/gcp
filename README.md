# Better Stack GCP Integration

This repository holds two independent setups for connecting Google Cloud to Better Stack:

- **[Log and metrics ingestion](#log-and-metrics-ingestion)** sends a project's or organization's logs and metrics to Better Stack. It uses `setup.sh` or the Terraform module.
- **[AI SRE](#ai-sre)** gives Better Stack AI SRE read-only access to one project, so it can investigate incidents there. It uses `ai-sre-setup.sh`.

Neither setup reads or changes what the other creates. You can use either one, or both.

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

`ai-sre-setup.sh` gives Better Stack AI SRE read-only access to one Google Cloud project, through Google's MCP servers. It is separate from the ingestion setup: it never reads or changes `setup.sh`'s resources.

### Before you start

- **A Google Cloud integration in Better Stack.** Go to AI SRE → Integrations → Google Cloud → Add. Enter the project ID, then select **Create setup command**. The integration's page shows the command to run.
- **An owner of the project** runs the command, or someone with the roles under [Permissions](#permissions). `roles/editor` is not enough, because it can't change IAM policies.
- **A shell with these tools:** `gcloud` signed in as that person (`gcloud auth login`), plus `curl`, `python3` and `bash` 3.2 or later.
  - [Cloud Shell](https://shell.cloud.google.com) has all of them and is already signed in, so it's the easiest place to run the command.
  - On macOS, `python3` needs the Xcode command line tools (`xcode-select --install`).
- **Network access** to `telemetry.betterstack.com` and to Google's APIs.

### Run the setup

Copy the command from the integration's page in Better Stack and run it. It looks like this:

```bash
curl -fsSL https://raw.githubusercontent.com/BetterStackHQ/gcp/main/ai-sre-setup.sh | bash -s -- --ai-sre YOUR_TOKEN --project my-project
```

- **The Google Cloud steps** take about a minute.
- **Registration** follows. Better Stack checks that it can use the new access. Google usually takes about 2 minutes to apply new IAM grants, so the script prints `Not ready yet (HTTP 422 …)` and `Retrying in …` lines and retries for up to 10 minutes. Those lines are expected.
- **On success**, the script prints `AI SRE setup complete!` and the command that removes this access later. The integration's page in Better Stack turns **Active** by itself.

**About the token:**
- It's used up only by a run that succeeds. After a failed run, run the same command again.
- It works only for the project the integration was created for. To connect another project, add another Google Cloud integration in Better Stack.

**More than one team.** Each Better Stack team connects a given project once. Other teams can connect the same project, and each integration gets its own identity provider.

**Rerunning.** Every step checks what already exists, so rerunning the command is safe. The script continues where it stopped, and it enables the pool, the provider or the service account again if someone disabled them.

### What gets created

In the project:

- **Workload identity pool** `betterstack-ai-sre-pool`. The ingestion setup's `betterstack-pool` and `betterstack-provider` are never read or changed.
- **Identity provider** `betterstack-ai-sre-<first 8 hex characters of the integration's audience UUID>` in that pool, one per integration.
  - It trusts Google-signed ID tokens (`https://accounts.google.com`).
  - It accepts them only from `ai-sre-caller@better-stack.iam.gserviceaccount.com`.
  - It accepts them only with the audience Better Stack generated for that integration.
- **Service account** `betterstack-ai-sre@<project>.iam.gserviceaccount.com`. Every AI SRE integration of the project shares it.
- **Impersonation grant.** `roles/iam.workloadIdentityUser` on that service account, for `principalSet://iam.googleapis.com/projects/<project number>/locations/global/workloadIdentityPools/betterstack-ai-sre-pool/attribute.sa_email/ai-sre-caller@better-stack.iam.gserviceaccount.com`.
  - The grant covers the whole pool.
  - Integrations stay apart because each provider accepts only its own integration's audience.
- **No keys.** No service account keys are created.

The service account gets these roles on the project:

| MCP server | Role | API |
|------------|------|-----|
| All servers (calling MCP tools) | `roles/mcp.toolUser` | |
| Cloud Logging | `roles/logging.viewer` | `logging.googleapis.com` |
| Cloud Monitoring | `roles/monitoring.viewer` | `monitoring.googleapis.com` |
| Cloud Run | `roles/run.viewer` | `run.googleapis.com` |
| Resource Manager | `roles/browser` | `cloudresourcemanager.googleapis.com` |
| Cloud Trace | `roles/cloudtrace.user` | `cloudtrace.googleapis.com` |
| Error Reporting | `roles/errorreporting.viewer` | `clouderrorreporting.googleapis.com` |
| Kubernetes Engine | `roles/container.viewer` | `container.googleapis.com` |

**APIs.**
- **Turned on when off:** `iam`, `iamcredentials`, `sts` and `logging` (all `.googleapis.com`). Workload identity federation needs the first three, and Better Stack's check lists Cloud Logging's tools.
- **Never turned on:** the other servers' APIs. Enabling one can have side effects: for example, Kubernetes Engine also turns on Compute Engine, which creates its default service account.
- **Servers whose API is off** are listed as `Not enabled, so AI SRE has nothing to read from these servers here: …`. A project that doesn't use a product has nothing there to read anyway. If you turn an API on later, AI SRE can use that server without running the setup again.

### What AI SRE can see

With these roles, AI SRE can read:

- **Logs.** All logs except Data Access audit logs, which need `roles/logging.privateLogViewer`.
- **Monitoring.** Metrics and alerting policies.
- **Cloud Trace.** Traces.
- **Error Reporting.** Errors.
- **Cloud Run.** Services and revisions, **including the values of their environment variables**. Keep secrets in Secret Manager, not in plain environment variables.
- **GKE.** Clusters and Kubernetes objects. `roles/container.viewer` doesn't grant access to the contents of Secrets.

It can't change anything, with one exception: `roles/cloudtrace.user` can also create Cloud Trace scopes and analysis tasks. Google has no narrower predefined role for reading traces.

Better Stack's relay offers AI SRE only the MCP tools that Google marks read-only.

### Options

| Argument | Description |
|----------|-------------|
| `--ai-sre <token>` | Registration token. It is part of the command Better Stack shows. |
| `--project <id>` | The project to connect (required). It must be the project the integration was created for. |
| `--audit-logs` | Turns on Data Access audit logs (`DATA_READ`) for `mcp.googleapis.com`. Off by default, because they are billed as Cloud Logging ingestion. To use it, add it to the end of the command Better Stack shows. |
| `--api-url <url>` | Better Stack API base URL. The command Better Stack shows sets it when needed, so don't change it. Default: `https://telemetry.betterstack.com`. |
| `--ai-sre-remove <provider id>` | Removes an integration's access instead of setting it up. See [Removal](#removal). |
| `--help`, `-h` | Shows usage. |

Options that take a value also accept the `--option=value` form.

### Permissions

The person running the script needs `roles/owner` on the project, or all of these roles on it:

| Role | Used to |
|------|---------|
| `roles/serviceusage.serviceUsageAdmin` | List the enabled APIs, and enable whichever of `iam`, `iamcredentials`, `sts` and `logging` is off. When all four are on, `roles/serviceusage.serviceUsageViewer` is enough |
| `roles/iam.workloadIdentityPoolAdmin` | Create, enable, restore or delete the pool and the provider |
| `roles/iam.serviceAccountAdmin` | Create, enable or delete the service account, and grant `roles/iam.workloadIdentityUser` on it |
| `roles/resourcemanager.projectIamAdmin` | Grant or remove the service account's roles on the project, and turn on audit logs |

Removal doesn't need `roles/serviceusage.serviceUsageAdmin`.

When a step is denied, the script names the missing permission when Google reports one, and the role that grants it.

### Troubleshooting

The script prints `Error: …` and Google's own message. Once it has started changing the project, it also prints `If you can't fix it, undo what this command set up in <project>:` with the removal command. Find the error below:

| The script says | What to do |
|-----------------|------------|
| `Not ready yet (HTTP 422: Google hasn't accepted the new access yet …); retrying` | Nothing. Google is still applying the new IAM grants. |
| `Better Stack still can't use the new access after … seconds` | Google took longer than the script waited. Run the same command again in a few minutes: the token still works. If the same message keeps coming back, contact Better Stack at hello@betterstack.com and include it. One cause that waiting can't fix is a VPC Service Controls perimeter that blocks Better Stack. |
| `… failed: permission denied` and `The account running this script needs <role>` | Get that role, or `roles/owner`, on the project. Then run the same command again. `gcloud auth list` shows which account the script runs as. |
| `Reading project … failed` | Check the project ID and the signed-in account. The command works only for the project the integration was created for. |
| `This command is for project X, not Y` | The command belongs to project X. To connect Y, add a Google Cloud integration for Y in Better Stack. |
| `an organization policy blocks it` | The message names the policy. Send it to your organization policy admin. See [Organization policies](#organization-policies). |
| Another error that names an organization policy or constraint | Send it to your organization policy admin. |
| `There were concurrent policy changes` | Something else kept changing the project's IAM policy, such as Terraform or a colleague. The script retries for about a minute before it stops. Run the same command again once the other change is done. |
| `Not enabled, so AI SRE has nothing to read from these servers here: …` | Not an error. See **APIs** under "What gets created" above. |
| `Better Stack rejected the registration token` | If the integration is **Active** in Better Stack, the setup is complete. If the integration was removed, run the undo command the script prints. Otherwise, copy the command from the integration's page again. |
| `Better Stack refused the registration` | Follow the message. If this run created the provider, the script has already deleted it. |
| The integration's page says "We can no longer access this GCP project" | Run the setup command shown on that page as an owner. It restores access with the same provider. |

#### Organization policies

- **`constraints/iam.workloadIdentityPoolProviders`.** It must allow the issuer `https://accounts.google.com` for this project.
  - Ask your organization policy admin to add that issuer and to keep the values the project inherits. Replacing the inherited list could block your other identity providers in the project, such as GitHub Actions.
  - The script prints a policy that does both:

    ```yaml
    # policy.yaml; apply with: gcloud org-policies set-policy policy.yaml
    name: projects/my-project/policies/iam.workloadIdentityPoolProviders
    spec:
      inheritFromParent: true
      rules:
        - values:
            allowedValues:
              - https://accounts.google.com
    ```

- **`constraints/iam.disableServiceAccountCreation`.** Creating `betterstack-ai-sre@` needs an exception for this project.
- **Domain-restricted sharing (`constraints/iam.allowedPolicyMemberDomains`).** Google's error says `One or more users named in the policy do not belong to a permitted customer`. The allowed list must cover service accounts and workload identity pools in your own organization, for example through your organization's principal set.

### Removal

**Removing the integration in Better Stack ends AI SRE's access straight away:** Better Stack stops using it. What's left in the project grants nothing. The removal command only tidies it up.

**Where to find the command:**
- Better Stack shows it when you remove the integration, pending integrations included.
- A successful setup prints it at the end.
- The provider ID is also printed near the start of every setup run, as `Provider: betterstack-ai-sre-…`.

Run it as an owner of the project. For example, for provider `betterstack-ai-sre-1a2b3c4d`:

```bash
curl -fsSL https://raw.githubusercontent.com/BetterStackHQ/gcp/main/ai-sre-setup.sh | bash -s -- \
  --ai-sre-remove betterstack-ai-sre-1a2b3c4d --project my-project
```

What it does:

- **The provider.** It deletes the integration's provider. One that is already gone is fine.
- **When other AI SRE providers remain**, which happens when other integrations connect the project:
  - it keeps the service account and its roles;
  - it lists those providers, each with its own removal command.

  Run one of those only if its integration was removed from Better Stack.
- **When it removes the last provider**, it also removes the service account's roles and deletes the service account.
- **What stays:**
  - the pool, which grants nothing without a provider and lets a later setup reuse it;
  - the APIs the setup enabled;
  - the Data Access audit log setting.
- **Rerunning** is safe.

## Tests

`test/ai_sre_test.sh` tests `ai-sre-setup.sh` only. It replaces `gcloud`, `curl` and `sleep` with mocks, so it needs no GCP project or Better Stack account, only `bash` and `python3`. It runs in seconds and ends with `N passed, 0 failed`.

```bash
test/ai_sre_test.sh
shellcheck ai-sre-setup.sh test/ai_sre_test.sh
```

The script under test runs with the first `bash` on `PATH`. To test it with macOS's bash 3.2, put `/bin/bash` first:

```bash
mkdir -p /tmp/bash32 && ln -sf /bin/bash /tmp/bash32/bash && PATH="/tmp/bash32:$PATH" test/ai_sre_test.sh
```
