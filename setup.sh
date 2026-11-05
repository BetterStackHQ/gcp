#!/usr/bin/env bash
set -euo pipefail

# Better Stack GCP Integration Setup
#
# Sets up metrics access and (optionally) log forwarding for a GCP project or whole organization.
#
# Org mode (--org-id provided): org-level IAM roles + org-level log sink (all projects)
# Project mode (no --org-id):   project-level IAM roles + project-level log sink
#
# Run with --help for usage information.

# --- Defaults ---
REGION=""
BATCH_COUNT="100"
BETTERSTACK_SA="gcp-integration@better-stack.iam.gserviceaccount.com"
ORG_ID=""
TEARDOWN=false
SKIP_LOG_FORWARDING=false

# --- AI SRE mode defaults ---
AI_SRE=false
AI_SRE_TOKEN=""
AI_SRE_SERVICES=""
AI_SRE_AUDIT_LOGS=false
AI_SRE_API_URL="https://telemetry.betterstack.com"
DRY_RUN=false

# --- Supported Dataflow regions ---
DATAFLOW_REGIONS=(
  asia-east1 asia-east2 asia-northeast1 asia-northeast2 asia-northeast3
  asia-south1 asia-south2 asia-southeast1 asia-southeast2
  australia-southeast1 australia-southeast2
  europe-central2 europe-north1 europe-southwest1
  europe-west1 europe-west2 europe-west3 europe-west4 europe-west6
  europe-west8 europe-west9 europe-west10 europe-west12
  me-central1 me-west1
  northamerica-northeast1 northamerica-northeast2
  southamerica-east1 southamerica-west1
  us-central1 us-east1 us-east4 us-east5 us-south1
  us-west1 us-west2 us-west3 us-west4
)

print_usage() {
  cat <<EOF
Better Stack GCP Integration Setup

Usage:
  $(basename "$0") --project=<id> --region=<region> --source-token=<token> --ingesting-host=<host> [options]
  $(basename "$0") --teardown --project=<id> --region=<region> --ingesting-host=<host> [--org-id=<id>]
  $(basename "$0") --ai-sre <token> [--project <id>] [AI SRE options]
  $(basename "$0") --help

Log and metrics ingestion

Required:
  --project=<id>             GCP project ID
  --region=<region>          Dataflow region (run without to see supported values)
  --source-token=<token>     Better Stack source token
  --ingesting-host=<host>    Better Stack ingesting host

Optional:
  --org-id=<id>              Configure at organization level (covers all current and future projects)
  --betterstack-sa=<email>   Better Stack service account (default: ${BETTERSTACK_SA})
  --batch-count=<n>          Dataflow batch size (default: ${BATCH_COUNT})
  --skip-log-forwarding      Skip Pub/Sub, log sink, and Dataflow setup (metrics access only)
  --teardown                 Remove all integration resources for the project (and org sink, if --org-id given)
  --help, -h                 Show this help and exit

AI SRE (read-only access for Better Stack AI SRE)

  --ai-sre <token>           Registration token from the GCP integration in Better Stack
  --project <id>             Project to connect (default: the current gcloud project).
                             The first project also holds the identity pool and the
                             service account. To add another project to the same
                             integration, use a new token and pass --project.
  --services <list>          Optional servers, comma-separated, possibly in Preview:
                             cloudtrace, clouderrorreporting, container
  --audit-logs               Turn on Data Access audit logs (DATA_READ) for
                             mcp.googleapis.com. Off by default: they are billed
                             as Cloud Logging ingestion.
  --api-url <url>            Better Stack API base URL (default: ${AI_SRE_API_URL})
  --dry-run                  Print every gcloud and curl call without running any
EOF
}

print_regions() {
  echo "Supported Dataflow regions:"
  for r in "${DATAFLOW_REGIONS[@]}"; do
    echo "  $r"
  done
}

# --- AI SRE mode (--ai-sre) ---
#
# Gives Better Stack AI SRE read-only access to GCP projects through Google's
# MCP servers. In the first project it creates (or reuses) the betterstack-pool
# workload identity pool, adds a betterstack-ai-sre provider that accepts only
# Better Stack's AI SRE caller and this integration's audience, and creates a
# read-only betterstack-ai-sre service account. Every further project only
# grants that service account its roles. Each project is then registered with
# Better Stack using the one-time token from the integration's page.
#
# Every step checks what exists first, so running the same command again after
# a failure completes the setup.

AI_SRE_CALLER="ai-sre-caller@better-stack.iam.gserviceaccount.com"
AI_SRE_POOL="betterstack-pool"
AI_SRE_PROVIDER="betterstack-ai-sre"
AI_SRE_SA_NAME="betterstack-ai-sre"
AI_SRE_ROLES=(roles/mcp.toolUser roles/logging.viewer roles/monitoring.viewer roles/run.viewer roles/browser)
AI_SRE_APIS=(logging monitoring run cloudresourcemanager)
AI_SRE_POOL_APIS=(iam iamcredentials sts)
AI_SRE_OPTIONAL_SERVICES="cloudtrace clouderrorreporting container"
AI_SRE_REGISTER_TIMEOUT=180
AI_SRE_OUT=""
AI_SRE_STATUS=""

ai_sre_service_role() {
  case "$1" in
    cloudtrace) echo "roles/cloudtrace.user" ;;
    clouderrorreporting) echo "roles/errorreporting.viewer" ;;
    container) echo "roles/container.clusterViewer" ;;
    *) return 1 ;;
  esac
}

# Whether a value is one of this script's own options (so --ai-sre got no token).
ai_sre_is_option() {
  case "${1%%=*}" in
    --help|-h|--project|--org-id|--source-token|--ingesting-host|--betterstack-sa|--region|--batch-count \
      |--skip-log-forwarding|--teardown|--ai-sre|--services|--api-url|--audit-logs|--dry-run) return 0 ;;
  esac
  return 1
}

ai_sre_error() {
  echo ""
  echo "Error: $*"
  exit 1
}

# Prints a command the way a shell would read it back.
ai_sre_show() {
  local line="  $" arg q="'"
  for arg in "$@"; do
    if [[ "$arg" =~ ^[A-Za-z0-9_@%+=:,./-]+$ ]]; then
      line+=" $arg"
    else
      line+=" ${q}${arg//${q}/${q}\\${q}${q}}${q}"
    fi
  done
  echo "$line"
}

ai_sre_rerun_hint() {
  echo ""
  echo "Fix the problem above, then run the same command again: the script picks up where it stopped."
}

# Explains a failed gcloud call and exits.
ai_sre_gcloud_failed() {
  local what="$1" role="$2" out="$3" permission line
  echo ""
  if grep -q "FAILED_PRECONDITION" <<<"$out" && grep -q "iam.workloadIdentityPoolProviders" <<<"$out"; then
    echo "Error: ${what} failed: an organization policy blocks it."
    echo "  constraints/iam.workloadIdentityPoolProviders does not allow https://accounts.google.com"
    echo "  as an identity provider. Allow it for project ${AI_SRE_POOL_PROJECT} with the command below"
    echo "  (needs roles/orgpolicy.policyAdmin), then run this script again:"
    echo ""
    echo "    gcloud resource-manager org-policies allow constraints/iam.workloadIdentityPoolProviders https://accounts.google.com --project=${AI_SRE_POOL_PROJECT}"
  elif grep -qiE "PERMISSION_DENIED|does not have permission|Permission '[^']+' denied" <<<"$out"; then
    permission=$(grep -oE "Permission '[^']+'" <<<"$out" | head -n 1 | sed -E "s/Permission '([^']+)'/\1/" || true)
    echo "Error: ${what} failed: permission denied."
    [ -n "$permission" ] && echo "  Missing permission: ${permission}"
    echo "  The account running this script needs ${role}."
    echo "  roles/owner includes it."
  else
    echo "Error: ${what} failed."
  fi
  echo ""
  echo "  gcloud said:"
  while IFS= read -r line; do
    echo "    $line"
  done <<<"$out"
  ai_sre_rerun_hint
  exit 1
}

# ai_sre_gcloud <what> <role needed> <gcloud args...>
# Runs gcloud with its output in AI_SRE_OUT, and exits with an explanation if it fails.
ai_sre_gcloud() {
  local what="$1" role="$2" attempt status
  shift 2
  if [ "$DRY_RUN" = true ]; then
    ai_sre_show gcloud "$@"
    AI_SRE_OUT=""
    return 0
  fi
  for attempt in $(seq 1 12); do
    status=0
    AI_SRE_OUT=$(gcloud "$@" 2>"$AI_SRE_TMP/gcloud.err") || status=$?
    [ "$status" -eq 0 ] && return 0
    # A service account created a moment ago can take up to a minute to reach IAM.
    if [ "$attempt" -lt 12 ] && grep -qiE "service ?account .*does not exist" "$AI_SRE_TMP/gcloud.err"; then
      sleep 5
      continue
    fi
    break
  done
  ai_sre_gcloud_failed "$what" "$role" "$(cat "$AI_SRE_TMP/gcloud.err")${AI_SRE_OUT:+$'\n'$AI_SRE_OUT}"
}

# ai_sre_probe <gcloud args...>
# Runs a read-only describe call. AI_SRE_OUT holds its output, or nothing if it failed.
ai_sre_probe() {
  if [ "$DRY_RUN" = true ]; then
    ai_sre_show gcloud "$@"
    AI_SRE_OUT=""
    return 0
  fi
  AI_SRE_OUT=$(gcloud "$@" 2>/dev/null) || AI_SRE_OUT=""
}

# ai_sre_api <method> <path> [json body]
# Calls the Better Stack API. AI_SRE_STATUS holds the HTTP status (000 if no
# answer), and the body is in $AI_SRE_TMP/body.json.
ai_sre_api() {
  local method="$1" path="$2" data="${3:-}"
  local url="${AI_SRE_API_URL}${path}"
  local args=(-sS -X "$method" -H "Accept: application/json" --connect-timeout 10 --max-time 60)
  if [ -n "$data" ]; then
    args+=(-H "Content-Type: application/json" --data "$data")
  fi
  if [ "$DRY_RUN" = true ]; then
    ai_sre_show curl "${args[@]}" -H "Authorization: Bearer <token>" "$url"
    AI_SRE_STATUS="dry-run"
    return 0
  fi
  : >"$AI_SRE_TMP/body.json"
  # The token is read from a file so it never shows in the process list.
  AI_SRE_STATUS=$(curl "${args[@]}" -H @"$AI_SRE_TMP/auth-header" \
    -o "$AI_SRE_TMP/body.json" -w '%{http_code}' "$url" 2>"$AI_SRE_TMP/curl.err") || AI_SRE_STATUS="000"
}

# ai_sre_json <field>: prints a field of the last API answer ("" when absent or null).
ai_sre_json() {
  python3 -c '
import json, sys
try:
    value = json.load(open(sys.argv[2])).get(sys.argv[1])
except Exception:
    value = None
if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, list):
    print(", ".join(str(v) for v in value))
else:
    print(value)
' "$1" "$AI_SRE_TMP/body.json"
}

# Describes the last failed API answer.
ai_sre_api_error() {
  local message
  if [ "$AI_SRE_STATUS" = "000" ]; then
    message=$(cat "$AI_SRE_TMP/curl.err")
    echo "could not reach ${AI_SRE_API_URL}${message:+: ${message}}"
    return
  fi
  message=$(ai_sre_json error)
  echo "HTTP ${AI_SRE_STATUS}${message:+: ${message}}"
}

ai_sre_token_rejected() {
  echo ""
  echo "Error: Better Stack rejected the registration token ($(ai_sre_api_error))."
  echo "  Tokens are valid for 24 hours and work once. Get a new command from the"
  echo "  GCP integration in Better Stack and run it again."
  exit 1
}

# ai_sre_retry_wait <what>: waits before retrying a Better Stack call, backing off
# from 5 to 30 seconds. Fails once the next wait would pass AI_SRE_REGISTER_TIMEOUT.
# Reset AI_SRE_WAITED=0 and AI_SRE_DELAY=5 before the first call.
ai_sre_retry_wait() {
  [ $((AI_SRE_WAITED + AI_SRE_DELAY)) -le "$AI_SRE_REGISTER_TIMEOUT" ] || return 1
  echo "  $1 ($(ai_sre_api_error)); retrying in ${AI_SRE_DELAY}s..."
  sleep "$AI_SRE_DELAY"
  AI_SRE_WAITED=$((AI_SRE_WAITED + AI_SRE_DELAY))
  AI_SRE_DELAY=$((AI_SRE_DELAY * 2))
  [ "$AI_SRE_DELAY" -gt 30 ] && AI_SRE_DELAY=30
  return 0
}

ai_sre_fetch_audience() {
  echo "Fetching the integration's details from Better Stack..."
  AI_SRE_WAITED=0
  AI_SRE_DELAY=5
  while true; do
    ai_sre_api GET /api/v1/ai-sre/gcp-registrations/audience
    case "$AI_SRE_STATUS" in
      429|5??|000) ai_sre_retry_wait "Better Stack is not answering yet" || break ;;
      *) break ;;
    esac
  done
  if [ "$DRY_RUN" = true ]; then
    AI_SRE_AUDIENCE="AUDIENCE_FROM_BETTER_STACK"
    AI_SRE_KNOWN_POOL_PROJECT=""
    AI_SRE_KNOWN_POOL_NUMBER=""
    AI_SRE_KNOWN_SA=""
    echo "  Dry run: assuming the integration has no project yet."
    echo ""
    return 0
  fi
  case "$AI_SRE_STATUS" in
    200) ;;
    401) ai_sre_token_rejected ;;
    *) ai_sre_error "Could not fetch the integration's details from Better Stack ($(ai_sre_api_error))." ;;
  esac

  AI_SRE_AUDIENCE=$(ai_sre_json audience)
  AI_SRE_KNOWN_POOL_PROJECT=$(ai_sre_json pool_project_id)
  AI_SRE_KNOWN_POOL_NUMBER=$(ai_sre_json pool_project_number)
  AI_SRE_KNOWN_SA=$(ai_sre_json service_account_email)
  local caller
  caller=$(ai_sre_json caller_service_account)

  # The audience becomes the provider's only allowed audience: one plain https URL
  # (https://betterstack.com/ai-sre/gcp/<uuid>), with no characters gcloud or a shell could misread.
  if ! [[ "$AI_SRE_AUDIENCE" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~-]+)+$ ]]; then
    ai_sre_error "Better Stack returned an unexpected audience: '${AI_SRE_AUDIENCE}'."
  fi
  if [ -n "$caller" ] && [ "$caller" != "$AI_SRE_CALLER" ]; then
    ai_sre_error "Better Stack names '${caller}' as its AI SRE caller, but this script trusts only ${AI_SRE_CALLER}. Use the latest version of this script."
  fi
  if [ -n "$AI_SRE_KNOWN_POOL_PROJECT" ]; then
    if [ "$AI_SRE_KNOWN_SA" != "${AI_SRE_SA_NAME}@${AI_SRE_KNOWN_POOL_PROJECT}.iam.gserviceaccount.com" ] \
      || ! [[ "$AI_SRE_KNOWN_POOL_NUMBER" =~ ^[0-9]+$ ]]; then
      ai_sre_error "Better Stack returned an unexpected project or service account for this integration."
    fi
  fi
  echo "  Audience: $AI_SRE_AUDIENCE"
  [ -n "$AI_SRE_KNOWN_POOL_PROJECT" ] && echo "  Already connected: $(ai_sre_json project_ids) (identity pool in ${AI_SRE_KNOWN_POOL_PROJECT})"
  echo ""
}

ai_sre_project_number() {
  echo "Reading project ${AI_SRE_PROJECT}..."
  ai_sre_gcloud "Reading project ${AI_SRE_PROJECT}" "roles/browser on project ${AI_SRE_PROJECT}" \
    projects describe "$AI_SRE_PROJECT" --format='value(projectNumber)'
  if [ "$DRY_RUN" = true ]; then
    AI_SRE_PROJECT_NUMBER="PROJECT_NUMBER"
    return 0
  fi
  AI_SRE_PROJECT_NUMBER=$(tr -d '[:space:]' <<<"$AI_SRE_OUT")
  [[ "$AI_SRE_PROJECT_NUMBER" =~ ^[0-9]+$ ]] || ai_sre_error "Could not read the project number of ${AI_SRE_PROJECT}."
}

ai_sre_enable_apis() {
  local apis=("$@") services=() api
  for api in "${apis[@]}"; do
    services+=("${api}.googleapis.com")
  done
  echo "Enabling APIs in ${AI_SRE_PROJECT}: ${apis[*]}..."
  ai_sre_gcloud "Enabling APIs" "roles/serviceusage.serviceUsageAdmin on project ${AI_SRE_PROJECT}" \
    services enable "${services[@]}" --project="$AI_SRE_PROJECT" --quiet
}

ai_sre_ensure_pool() {
  local role="roles/iam.workloadIdentityPoolAdmin on project ${AI_SRE_PROJECT}"
  echo "Setting up workload identity pool ${AI_SRE_POOL}..."
  ai_sre_probe iam workload-identity-pools describe "$AI_SRE_POOL" \
    --location=global --project="$AI_SRE_PROJECT" --format='value(state,disabled)'
  case "$AI_SRE_OUT" in
    ACTIVE*True*)
      echo "  Reusing existing pool, which is disabled: enabling it."
      ai_sre_gcloud "Enabling pool ${AI_SRE_POOL}" "$role" \
        iam workload-identity-pools update "$AI_SRE_POOL" --location=global --project="$AI_SRE_PROJECT" --no-disabled
      ;;
    ACTIVE*) echo "  Reusing existing pool." ;;
    DELETED*)
      ai_sre_gcloud "Restoring pool ${AI_SRE_POOL}" "$role" \
        iam workload-identity-pools undelete "$AI_SRE_POOL" --location=global --project="$AI_SRE_PROJECT"
      ;;
    *)
      ai_sre_gcloud "Creating pool ${AI_SRE_POOL}" "$role" \
        iam workload-identity-pools create "$AI_SRE_POOL" --location=global --project="$AI_SRE_PROJECT" \
        --display-name="Better Stack Integration"
      ;;
  esac
}

ai_sre_ensure_provider() {
  local role="roles/iam.workloadIdentityPoolAdmin on project ${AI_SRE_PROJECT}"
  local args=(
    --workload-identity-pool="$AI_SRE_POOL"
    --location=global --project="$AI_SRE_PROJECT"
    --issuer-uri="https://accounts.google.com"
    --allowed-audiences="$AI_SRE_AUDIENCE"
    --attribute-mapping="google.subject=assertion.sub,attribute.sa_email=assertion.email"
    --attribute-condition="assertion.email=='${AI_SRE_CALLER}'"
  )
  echo "Setting up identity provider ${AI_SRE_PROVIDER} (accepts only ${AI_SRE_CALLER})..."
  ai_sre_probe iam workload-identity-pools providers describe "$AI_SRE_PROVIDER" \
    --workload-identity-pool="$AI_SRE_POOL" --location=global --project="$AI_SRE_PROJECT" --format='value(state)'
  AI_SRE_OUT=$(tr -d '[:space:]' <<<"$AI_SRE_OUT")
  if [ "$AI_SRE_OUT" = "DELETED" ]; then
    ai_sre_gcloud "Restoring provider ${AI_SRE_PROVIDER}" "$role" \
      iam workload-identity-pools providers undelete "$AI_SRE_PROVIDER" \
      --workload-identity-pool="$AI_SRE_POOL" --location=global --project="$AI_SRE_PROJECT"
    AI_SRE_OUT="ACTIVE"
  fi
  if [ "$AI_SRE_OUT" = "ACTIVE" ]; then
    ai_sre_gcloud "Updating provider ${AI_SRE_PROVIDER}" "$role" \
      iam workload-identity-pools providers update-oidc "$AI_SRE_PROVIDER" "${args[@]}" --no-disabled
  else
    ai_sre_gcloud "Creating provider ${AI_SRE_PROVIDER}" "$role" \
      iam workload-identity-pools providers create-oidc "$AI_SRE_PROVIDER" "${args[@]}" \
      --display-name="Better Stack AI SRE"
  fi
}

ai_sre_ensure_service_account() {
  echo "Setting up service account ${AI_SRE_SA}..."
  ai_sre_probe iam service-accounts describe "$AI_SRE_SA" --project="$AI_SRE_PROJECT" --format='value(email)'
  if [ -n "$AI_SRE_OUT" ]; then
    echo "  Reusing existing service account."
    return 0
  fi
  ai_sre_gcloud "Creating service account ${AI_SRE_SA}" "roles/iam.serviceAccountAdmin on project ${AI_SRE_PROJECT}" \
    iam service-accounts create "$AI_SRE_SA_NAME" --project="$AI_SRE_PROJECT" \
    --display-name="Better Stack AI SRE" --description="Read-only access for Better Stack AI SRE"
}

ai_sre_grant_roles() {
  local role
  echo "Granting read-only roles to ${AI_SRE_SA} on ${AI_SRE_PROJECT}..."
  for role in "${AI_SRE_ROLES_TO_GRANT[@]}"; do
    echo "  $role"
    ai_sre_gcloud "Granting ${role}" "roles/resourcemanager.projectIamAdmin on project ${AI_SRE_PROJECT}" \
      projects add-iam-policy-binding "$AI_SRE_PROJECT" \
      --member="serviceAccount:${AI_SRE_SA}" --role="$role" --condition=None --quiet
  done
}

ai_sre_allow_impersonation() {
  local member="principalSet://iam.googleapis.com/projects/${AI_SRE_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${AI_SRE_POOL}/attribute.sa_email/${AI_SRE_CALLER}"
  echo "Letting ${AI_SRE_CALLER} impersonate ${AI_SRE_SA} through ${AI_SRE_PROVIDER}..."
  ai_sre_gcloud "Granting roles/iam.workloadIdentityUser on ${AI_SRE_SA}" \
    "roles/iam.serviceAccountAdmin on project ${AI_SRE_PROJECT}" \
    iam service-accounts add-iam-policy-binding "$AI_SRE_SA" --project="$AI_SRE_PROJECT" \
    --member="$member" --role="roles/iam.workloadIdentityUser" --condition=None --quiet
}

ai_sre_enable_audit_logs() {
  local role="roles/resourcemanager.projectIamAdmin on project ${AI_SRE_PROJECT}"
  local policy_file="$AI_SRE_TMP/policy.json" changed
  echo "Turning on Data Access audit logs (DATA_READ) for mcp.googleapis.com in ${AI_SRE_PROJECT}..."
  ai_sre_gcloud "Reading the IAM policy of ${AI_SRE_PROJECT}" "$role" \
    projects get-iam-policy "$AI_SRE_PROJECT" --format=json
  if [ "$DRY_RUN" = true ]; then
    ai_sre_show gcloud projects set-iam-policy "$AI_SRE_PROJECT" "POLICY_WITH_MCP_DATA_READ.json" --quiet
    return 0
  fi
  changed=$(python3 -c '
import json, sys
policy = json.loads(sys.argv[1])
configs = policy.setdefault("auditConfigs", [])
config = next((c for c in configs if c.get("service") == "mcp.googleapis.com"), None)
if config is None:
    config = {"service": "mcp.googleapis.com", "auditLogConfigs": []}
    configs.append(config)
logs = config.setdefault("auditLogConfigs", [])
if any(l.get("logType") == "DATA_READ" for l in logs):
    print("no")
else:
    logs.append({"logType": "DATA_READ"})
    json.dump(policy, open(sys.argv[2], "w"))
    print("yes")
' "$AI_SRE_OUT" "$policy_file") || ai_sre_error "Could not read the IAM policy of ${AI_SRE_PROJECT}."
  if [ "$changed" = "no" ]; then
    echo "  Already on."
    return 0
  fi
  ai_sre_gcloud "Turning on audit logs" "$role" \
    projects set-iam-policy "$AI_SRE_PROJECT" "$policy_file" --quiet
}

ai_sre_register() {
  local body retryable unanswered=false
  body=$(python3 -c 'import json, sys; print(json.dumps({"project_id": sys.argv[1], "project_number": sys.argv[2], "service_account_email": sys.argv[3]}))' \
    "$AI_SRE_PROJECT" "$AI_SRE_PROJECT_NUMBER" "$AI_SRE_SA")
  echo "Registering ${AI_SRE_PROJECT} with Better Stack..."
  echo "  Better Stack checks that it can use the new access. Google can take a few minutes"
  echo "  to apply IAM changes, so this retries for up to $((AI_SRE_REGISTER_TIMEOUT / 60)) minutes."
  AI_SRE_WAITED=0
  AI_SRE_DELAY=5
  while true; do
    ai_sre_api POST /api/v1/ai-sre/gcp-registrations "$body"
    case "$AI_SRE_STATUS" in
      dry-run) return 0 ;;
      200|201) return 0 ;;
      401)
        if [ "$unanswered" = true ]; then
          echo ""
          echo "Error: Better Stack rejected the token on a retry, after an earlier attempt got no answer."
          echo "  That attempt may have registered the project, which uses up the token. Check the"
          echo "  integration in Better Stack: if ${AI_SRE_PROJECT} is listed, the setup is complete."
          exit 1
        fi
        ai_sre_token_rejected
        ;;
      422)
        retryable=$(ai_sre_json retryable)
        if [ "$retryable" != "true" ]; then
          echo ""
          echo "Error: Better Stack refused the registration ($(ai_sre_api_error))."
          exit 1
        fi
        ;;
      429) ;;
      5??|000) unanswered=true ;;
      *)
        echo ""
        echo "Error: Registration failed ($(ai_sre_api_error))."
        ai_sre_rerun_hint
        exit 1
        ;;
    esac
    if ! ai_sre_retry_wait "Not ready yet"; then
      echo ""
      echo "Error: Better Stack could not use the new access after ${AI_SRE_WAITED} seconds ($(ai_sre_api_error))."
      echo "  Google can take several minutes to apply IAM changes."
      ai_sre_rerun_hint
      exit 1
    fi
  done
}

ai_sre_main() {
  local service api

  if [ -z "$AI_SRE_TOKEN" ] || ai_sre_is_option "$AI_SRE_TOKEN"; then
    ai_sre_error "--ai-sre needs the registration token shown on the GCP integration in Better Stack."
  fi
  if ! [[ "$AI_SRE_TOKEN" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
    ai_sre_error "The registration token has unexpected characters. Copy the command from Better Stack again."
  fi
  if [ "$TEARDOWN" = true ] || [ "$SKIP_LOG_FORWARDING" = true ] || [ -n "$ORG_ID" ] || [ -n "$REGION" ] \
    || [ -n "${SOURCE_TOKEN:-}" ] || [ -n "${INGESTING_HOST:-}" ] \
    || [ "$BETTERSTACK_SA" != "gcp-integration@better-stack.iam.gserviceaccount.com" ] || [ "$BATCH_COUNT" != "100" ]; then
    ai_sre_error "--ai-sre can't be combined with the ingestion options (--teardown, --org-id, --region, --source-token, --ingesting-host, --skip-log-forwarding, --betterstack-sa, --batch-count)."
  fi
  AI_SRE_API_URL="${AI_SRE_API_URL%/}"
  [[ "$AI_SRE_API_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]] || ai_sre_error "--api-url must be an https URL."

  AI_SRE_ROLES_TO_GRANT=("${AI_SRE_ROLES[@]}")
  AI_SRE_APIS_TO_ENABLE=("${AI_SRE_APIS[@]}")
  if [ -n "$AI_SRE_SERVICES" ]; then
    local requested=()
    IFS=',' read -r -a requested <<<"$AI_SRE_SERVICES"
    for service in "${requested[@]}"; do
      service=$(tr -d '[:space:]' <<<"$service")
      [ -z "$service" ] && continue
      if ! ai_sre_service_role "$service" >/dev/null; then
        ai_sre_error "Unknown service '${service}' in --services. Choose from: ${AI_SRE_OPTIONAL_SERVICES// /, }."
      fi
      # Skip duplicates.
      for api in "${AI_SRE_APIS_TO_ENABLE[@]}"; do
        [ "$api" = "$service" ] && continue 2
      done
      AI_SRE_ROLES_TO_GRANT+=("$(ai_sre_service_role "$service")")
      AI_SRE_APIS_TO_ENABLE+=("$service")
    done
  fi

  command -v python3 >/dev/null || ai_sre_error "python3 is required."
  if [ "$DRY_RUN" = false ]; then
    command -v gcloud >/dev/null || ai_sre_error "gcloud is required: https://cloud.google.com/sdk/docs/install"
    command -v curl >/dev/null || ai_sre_error "curl is required."
  fi

  AI_SRE_TMP=$(mktemp -d)
  # shellcheck disable=SC2064 # expand the path now
  trap "rm -rf '$AI_SRE_TMP'" EXIT
  printf 'Authorization: Bearer %s\n' "$AI_SRE_TOKEN" >"$AI_SRE_TMP/auth-header"

  echo "Better Stack AI SRE Setup"
  echo "========================="
  echo ""
  if [ "$DRY_RUN" = true ]; then
    echo "Dry run: printing every gcloud and curl call without running any."
    echo ""
  fi

  ai_sre_fetch_audience

  AI_SRE_PROJECT="${PROJECT:-}"
  if [ -z "$AI_SRE_PROJECT" ]; then
    if [ -n "$AI_SRE_KNOWN_POOL_PROJECT" ]; then
      ai_sre_error "This integration is already connected to ${AI_SRE_KNOWN_POOL_PROJECT}. To add another project, run the command again with --project <id>."
    fi
    if [ "$DRY_RUN" = true ]; then
      ai_sre_show gcloud config get-value project
      AI_SRE_PROJECT="CURRENT_GCLOUD_PROJECT"
    else
      AI_SRE_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
      [ -n "$AI_SRE_PROJECT" ] || ai_sre_error "No project given and no current gcloud project. Pass --project <id>."
    fi
  fi
  [[ "$AI_SRE_PROJECT" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || ai_sre_error "'${AI_SRE_PROJECT}' is not a valid project ID (domain-scoped projects are not supported)."

  if [ -z "$AI_SRE_KNOWN_POOL_PROJECT" ] || [ "$AI_SRE_KNOWN_POOL_PROJECT" = "$AI_SRE_PROJECT" ]; then
    AI_SRE_MODE="pool"
    AI_SRE_POOL_PROJECT="$AI_SRE_PROJECT"
  else
    AI_SRE_MODE="added"
    AI_SRE_POOL_PROJECT="$AI_SRE_KNOWN_POOL_PROJECT"
  fi
  AI_SRE_SA="${AI_SRE_SA_NAME}@${AI_SRE_POOL_PROJECT}.iam.gserviceaccount.com"

  echo "  Project:          $AI_SRE_PROJECT"
  if [ "$AI_SRE_MODE" = "pool" ]; then
    echo "  Setup:            identity pool, provider and service account in this project"
  else
    echo "  Setup:            roles for the existing service account (identity pool in ${AI_SRE_POOL_PROJECT})"
  fi
  echo "  Service account:  $AI_SRE_SA"
  echo "  Servers:          ${AI_SRE_APIS_TO_ENABLE[*]}"
  echo "  Audit logs:       $([ "$AI_SRE_AUDIT_LOGS" = true ] && echo "on (DATA_READ for mcp.googleapis.com)" || echo "not changed (--audit-logs turns them on)")"
  echo ""

  ai_sre_project_number
  if [ "$AI_SRE_MODE" = "pool" ] && [ -n "$AI_SRE_KNOWN_POOL_NUMBER" ] && [ "$AI_SRE_KNOWN_POOL_NUMBER" != "$AI_SRE_PROJECT_NUMBER" ]; then
    ai_sre_error "Project ${AI_SRE_PROJECT} now has number ${AI_SRE_PROJECT_NUMBER}, but Better Stack registered ${AI_SRE_KNOWN_POOL_NUMBER}."
  fi

  if [ "$AI_SRE_MODE" = "pool" ]; then
    ai_sre_enable_apis "${AI_SRE_POOL_APIS[@]}" "${AI_SRE_APIS_TO_ENABLE[@]}"
    ai_sre_ensure_pool
    ai_sre_ensure_provider
    ai_sre_ensure_service_account
    ai_sre_grant_roles
    ai_sre_allow_impersonation
  else
    ai_sre_enable_apis "${AI_SRE_APIS_TO_ENABLE[@]}"
    ai_sre_grant_roles
  fi
  [ "$AI_SRE_AUDIT_LOGS" = true ] && ai_sre_enable_audit_logs

  ai_sre_register

  echo ""
  if [ "$DRY_RUN" = true ]; then
    echo "Dry run complete: nothing was changed."
    return 0
  fi
  echo "==================================="
  echo "AI SRE setup complete!"
  echo "==================================="
  echo ""
  echo "  Project:            $AI_SRE_PROJECT"
  echo "  Service account:    $AI_SRE_SA"
  echo "  Connected projects: $(ai_sre_json project_ids)"
  echo ""
  echo "The integration is now active in Better Stack. To connect another project,"
  echo "use \"Add project\" on the integration and run the command it shows."
}

# --- Parse arguments ---
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) print_usage; echo ""; print_regions; exit 0 ;;
    --project=*) PROJECT="${1#*=}"; shift ;;
    --project) PROJECT="$2"; shift 2 ;;
    --org-id=*) ORG_ID="${1#*=}"; shift ;;
    --org-id) ORG_ID="$2"; shift 2 ;;
    --source-token=*) SOURCE_TOKEN="${1#*=}"; shift ;;
    --source-token) SOURCE_TOKEN="$2"; shift 2 ;;
    --ingesting-host=*) INGESTING_HOST="${1#*=}"; shift ;;
    --ingesting-host) INGESTING_HOST="$2"; shift 2 ;;
    --betterstack-sa=*) BETTERSTACK_SA="${1#*=}"; shift ;;
    --betterstack-sa) BETTERSTACK_SA="$2"; shift 2 ;;
    --region=*) REGION="${1#*=}"; shift ;;
    --region) REGION="$2"; shift 2 ;;
    --batch-count=*) BATCH_COUNT="${1#*=}"; shift ;;
    --batch-count) BATCH_COUNT="$2"; shift 2 ;;
    --skip-log-forwarding) SKIP_LOG_FORWARDING=true; shift ;;
    --teardown) TEARDOWN=true; shift ;;
    --ai-sre=*) AI_SRE=true; AI_SRE_TOKEN="${1#*=}"; shift ;;
    --ai-sre)
      # Tokens can start with "-", so take any next value that isn't one of this script's options.
      AI_SRE=true
      if [ $# -ge 2 ] && ! ai_sre_is_option "$2"; then AI_SRE_TOKEN="$2"; shift; fi
      shift
      ;;
    --services=*) AI_SRE_SERVICES="${1#*=}"; shift ;;
    --services) [[ "${2:--}" != -* ]] || { echo "Error: --services needs a value."; exit 1; }; AI_SRE_SERVICES="$2"; shift 2 ;;
    --api-url=*) AI_SRE_API_URL="${1#*=}"; shift ;;
    --api-url) [[ "${2:--}" != -* ]] || { echo "Error: --api-url needs a value."; exit 1; }; AI_SRE_API_URL="$2"; shift 2 ;;
    --audit-logs) AI_SRE_AUDIT_LOGS=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    *)
      # Show only an option's name: a stray value may be a token.
      if [[ "${1%%=*}" =~ ^--?[A-Za-z][A-Za-z0-9-]*$ ]]; then
        echo "Unknown argument: ${1%%=*}"
      else
        echo "Unknown argument (value not shown, in case it is a secret)."
      fi
      echo "Run with --help for usage."
      exit 1
      ;;
  esac
done

# --- AI SRE mode ---
if [ "$AI_SRE" = true ]; then
  ai_sre_main
  exit 0
fi
if [ "$DRY_RUN" = true ] || [ "$AI_SRE_AUDIT_LOGS" = true ] || [ -n "$AI_SRE_SERVICES" ] \
  || [ "$AI_SRE_API_URL" != "https://telemetry.betterstack.com" ]; then
  echo "Error: --services, --audit-logs, --api-url and --dry-run are only available with --ai-sre."
  exit 1
fi

# --- Validate region (required for both setup and teardown) ---
if [ -z "$REGION" ]; then
  echo "Error: --region is required."
  echo ""
  print_regions
  echo ""
  echo "Re-run with --region=<region>. See --help for full usage."
  exit 1
fi

SA_EMAIL="betterstack-integration@${PROJECT:-unknown}.iam.gserviceaccount.com"
SOURCE_ID="${INGESTING_HOST:+${INGESTING_HOST%%.*}}"
SINK_NAME="${SOURCE_ID:+betterstack-logs-sink-${SOURCE_ID}}"
TOPIC_NAME="${SOURCE_ID:+betterstack-logs-${SOURCE_ID}}"
TOPIC_DEADLETTER="${SOURCE_ID:+betterstack-logs-deadletter-${SOURCE_ID}}"
SUB_NAME="${SOURCE_ID:+betterstack-logs-pull-${SOURCE_ID}}"
DATAFLOW_PREFIX="${SOURCE_ID:+betterstack-logs-${SOURCE_ID}}"

ROLES=(
  roles/monitoring.viewer
  roles/compute.viewer
  roles/cloudasset.viewer
  roles/browser
  roles/logging.configWriter
  roles/logging.viewer
  roles/pubsub.editor
)

if [ -n "$ORG_ID" ]; then
  MODE="org"
else
  MODE="project"
fi

# --- Teardown ---
if [ "$TEARDOWN" = true ]; then
  MISSING=()
  [ -z "${PROJECT:-}" ] && MISSING+=("--project")
  [ -z "${INGESTING_HOST:-}" ] && MISSING+=("--ingesting-host")
  if [ ${#MISSING[@]} -gt 0 ]; then
    echo "Error: Missing required arguments for teardown: ${MISSING[*]}"
    exit 1
  fi

  echo "This will remove all Better Stack integration resources:"
  echo "  Project: $PROJECT"
  echo "  Mode:    $MODE"
  [ -n "$ORG_ID" ] && echo "  Org:     $ORG_ID"
  echo ""
  read -p "Are you sure? (y/N) " -n 1 -r
  echo ""
  [ "$REPLY" = "y" ] || { echo "Aborted."; exit 0; }

  DATAFLOW_SA_EMAIL="betterstack-dataflow@${PROJECT}.iam.gserviceaccount.com"
  DATAFLOW_ROLES=(roles/dataflow.worker roles/storage.objectAdmin roles/pubsub.subscriber roles/pubsub.viewer)
  ERRORS=0

  echo ""
  echo "Cancelling Dataflow job..."
  JOB_IDS=$(gcloud dataflow jobs list --region="$REGION" --project="$PROJECT" \
    --filter="name~^${DATAFLOW_PREFIX} AND NOT state:(JOB_STATE_CANCELLED OR JOB_STATE_DONE OR JOB_STATE_FAILED OR JOB_STATE_DRAINED)" \
    --format='value(JOB_ID)' 2>/dev/null || true)
  if [ -n "$JOB_IDS" ]; then
    while IFS= read -r JOB_ID; do
      echo "  Cancelling $JOB_ID in $REGION..."
      if ! gcloud dataflow jobs cancel "$JOB_ID" --region="$REGION" --project="$PROJECT" 2>&1; then
        echo "  WARNING: Failed to cancel Dataflow job $JOB_ID"
        ERRORS=$((ERRORS + 1))
      fi
    done <<< "$JOB_IDS"
  else
    echo "  No active Dataflow jobs found in $REGION"
  fi

  echo "Deleting Pub/Sub subscription..."
  if ! gcloud pubsub subscriptions delete "$SUB_NAME" --project="$PROJECT" --quiet 2>&1; then
    echo "  WARNING: Failed to delete Pub/Sub subscription"
    ERRORS=$((ERRORS + 1))
  fi

  echo "Deleting Pub/Sub topics..."
  for topic in "$TOPIC_NAME" "$TOPIC_DEADLETTER"; do
    if ! gcloud pubsub topics delete "$topic" --project="$PROJECT" --quiet 2>&1; then
      echo "  WARNING: Failed to delete Pub/Sub topic $topic"
      ERRORS=$((ERRORS + 1))
    fi
  done

  echo "Deleting log sink..."
  if [ "$MODE" = "org" ]; then
    if ! gcloud logging sinks delete "$SINK_NAME" --organization="$ORG_ID" --quiet 2>&1; then
      echo "  WARNING: Failed to delete org log sink"
      ERRORS=$((ERRORS + 1))
    fi
  else
    if ! gcloud logging sinks delete "$SINK_NAME" --project="$PROJECT" --quiet 2>&1; then
      echo "  WARNING: Failed to delete project log sink"
      ERRORS=$((ERRORS + 1))
    fi
  fi

  # The AI SRE setup (--ai-sre) keeps its own provider in the same pool: keep the pool for it.
  AI_SRE_PROVIDER_STATE=$(gcloud iam workload-identity-pools providers describe betterstack-ai-sre \
    --workload-identity-pool=betterstack-pool --location=global --project="$PROJECT" \
    --format='value(state)' 2>/dev/null || true)
  if [ "$AI_SRE_PROVIDER_STATE" = "ACTIVE" ]; then
    echo "Keeping WIF pool betterstack-pool: it also holds the betterstack-ai-sre provider used by Better Stack AI SRE."
    echo "Deleting WIF provider betterstack-provider..."
    if ! gcloud iam workload-identity-pools providers delete betterstack-provider \
      --workload-identity-pool=betterstack-pool --location=global --project="$PROJECT" --quiet 2>&1; then
      echo "  WARNING: Failed to delete WIF provider"
      ERRORS=$((ERRORS + 1))
    fi
  else
    echo "Deleting WIF pool (cascades providers)..."
    if ! gcloud iam workload-identity-pools delete betterstack-pool \
      --location=global --project="$PROJECT" --quiet 2>&1; then
      echo "  WARNING: Failed to delete WIF pool"
      ERRORS=$((ERRORS + 1))
    fi
  fi

  echo "Removing IAM bindings..."
  if [ "$MODE" = "org" ]; then
    for role in "${ROLES[@]}"; do
      gcloud organizations remove-iam-policy-binding "$ORG_ID" \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="$role" --quiet > /dev/null 2>&1 || true
    done
  else
    for role in "${ROLES[@]}"; do
      gcloud projects remove-iam-policy-binding "$PROJECT" \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="$role" --quiet > /dev/null 2>&1 || true
    done
  fi
  for role in "${DATAFLOW_ROLES[@]}"; do
    gcloud projects remove-iam-policy-binding "$PROJECT" \
      --member="serviceAccount:${DATAFLOW_SA_EMAIL}" \
      --role="$role" --quiet > /dev/null 2>&1 || true
  done
  echo "  IAM bindings removed."

  echo "Deleting service accounts..."
  if ! gcloud iam service-accounts delete "$SA_EMAIL" --project="$PROJECT" --quiet 2>&1; then
    echo "  WARNING: Failed to delete service account $SA_EMAIL"
    ERRORS=$((ERRORS + 1))
  fi
  if ! gcloud iam service-accounts delete "$DATAFLOW_SA_EMAIL" --project="$PROJECT" --quiet 2>&1; then
    echo "  WARNING: Failed to delete service account $DATAFLOW_SA_EMAIL"
    ERRORS=$((ERRORS + 1))
  fi

  echo ""
  if [ "$ERRORS" -gt 0 ]; then
    echo "Teardown completed with $ERRORS warning(s). Review output above."
  else
    echo "Teardown complete."
  fi
  exit 0
fi

# --- Validate required arguments ---
MISSING=()
[ -z "${PROJECT:-}" ] && MISSING+=("--project")
[ -z "${SOURCE_TOKEN:-}" ] && MISSING+=("--source-token")
[ -z "${INGESTING_HOST:-}" ] && MISSING+=("--ingesting-host")
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "Error: Missing required arguments: ${MISSING[*]}"
  echo ""
  echo "Usage:"
  echo "  ./setup.sh \\"
  echo "    --project=CUSTOMER_PROJECT \\"
  echo "    [--org-id=ORG_ID] \\"
  echo "    --source-token=SOURCE_TOKEN \\"
  echo "    --ingesting-host=INGESTING_HOST \\"
  echo "    --region=europe-west1"
  exit 1
fi

SA_EMAIL="betterstack-integration@${PROJECT}.iam.gserviceaccount.com"

echo "Better Stack GCP Integration Setup"
echo "==================================="
echo ""
echo "  Project:         $PROJECT"
echo "  Mode:            $MODE"
[ -n "$ORG_ID" ] && echo "  Organization:    $ORG_ID"
echo "  Region:          $REGION"
echo "  Ingesting host:  $INGESTING_HOST"
echo "  Better Stack SA: $BETTERSTACK_SA"
echo ""

# --- Step 0: Pre-flight permission checks ---
echo "Checking permissions..."

TOKEN=$(gcloud auth print-access-token)

# Check project-level permissions
PROJECT_PERMS=(
  iam.serviceAccounts.create
  iam.serviceAccounts.setIamPolicy
  serviceusage.services.enable
)

if [ "$SKIP_LOG_FORWARDING" = false ]; then
  PROJECT_PERMS+=(
    pubsub.topics.create
    pubsub.subscriptions.create
    logging.sinks.create
    dataflow.jobs.create
  )
fi

# In project mode, also need project-level IAM binding permission
if [ "$MODE" = "project" ]; then
  PROJECT_PERMS+=(resourcemanager.projects.setIamPolicy)
fi

PERMS_JSON=$(printf '"%s",' "${PROJECT_PERMS[@]}" | sed 's/,$//')
RESULT=$(curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"permissions\":[$PERMS_JSON]}" \
  "https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT}:testIamPermissions")

GRANTED=$(echo "$RESULT" | python3 -c "import sys,json; perms=json.load(sys.stdin).get('permissions',[]); [print(p) for p in perms]" 2>/dev/null || true)

PROJECT_MISSING=()
for perm in "${PROJECT_PERMS[@]}"; do
  if ! echo "$GRANTED" | grep -q "^${perm}$"; then
    PROJECT_MISSING+=("$perm")
  fi
done

if [ ${#PROJECT_MISSING[@]} -gt 0 ]; then
  echo ""
  echo "Error: Missing project-level permissions on '$PROJECT':"
  for perm in "${PROJECT_MISSING[@]}"; do
    echo "  - $perm"
  done
  echo ""
  echo "You likely need roles/owner or roles/editor on the project."
  exit 1
fi

# Check org-level permissions (only in org mode)
if [ "$MODE" = "org" ]; then
  ORG_PERMS=(resourcemanager.organizations.setIamPolicy)
  if [ "$SKIP_LOG_FORWARDING" = false ]; then
    ORG_PERMS+=(logging.sinks.create)
  fi

  ORG_PERMS_JSON=$(printf '"%s",' "${ORG_PERMS[@]}" | sed 's/,$//')
  ORG_RESULT=$(curl -s -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"permissions\":[$ORG_PERMS_JSON]}" \
    "https://cloudresourcemanager.googleapis.com/v1/organizations/${ORG_ID}:testIamPermissions")

  ORG_GRANTED=$(echo "$ORG_RESULT" | python3 -c "import sys,json; perms=json.load(sys.stdin).get('permissions',[]); [print(p) for p in perms]" 2>/dev/null || true)

  ORG_MISSING=()
  for perm in "${ORG_PERMS[@]}"; do
    if ! echo "$ORG_GRANTED" | grep -q "^${perm}$"; then
      ORG_MISSING+=("$perm")
    fi
  done

  if [ ${#ORG_MISSING[@]} -gt 0 ]; then
    echo ""
    echo "Error: Missing organization-level permissions on org '$ORG_ID':"
    for perm in "${ORG_MISSING[@]}"; do
      echo "  - $perm"
    done
    echo ""
    echo "You likely need roles/resourcemanager.organizationAdmin on the organization."
    exit 1
  fi
fi

echo "  All permissions verified."
echo ""

# --- Step 1: Enable APIs ---
echo "Step 1: Enabling APIs..."

APIS=(serviceusage logging monitoring compute cloudasset iamcredentials)
if [ "$SKIP_LOG_FORWARDING" = false ]; then
  APIS+=(dataflow pubsub)
fi
for api in "${APIS[@]}"; do
  gcloud services enable "${api}.googleapis.com" --project="$PROJECT" --quiet
done

echo "  APIs enabled."
echo ""

# --- Step 2: Create service accounts + IAM roles ---
echo "Step 2: Creating service accounts and granting IAM roles ($MODE mode)..."

# Integration SA (for metrics access + log sink management, impersonated by Better Stack)
gcloud iam service-accounts create betterstack-integration \
  --project="$PROJECT" \
  --display-name="Better Stack Integration" 2>/dev/null || true

DATAFLOW_SA_EMAIL="betterstack-dataflow@${PROJECT}.iam.gserviceaccount.com"
if [ "$SKIP_LOG_FORWARDING" = false ]; then
  # Dataflow worker SA (least-privilege for running the pipeline)
  gcloud iam service-accounts create betterstack-dataflow \
    --project="$PROJECT" \
    --display-name="Better Stack Dataflow Worker" 2>/dev/null || true

  DATAFLOW_ROLES=(
    roles/dataflow.worker
    roles/storage.objectAdmin
    roles/pubsub.subscriber
    roles/pubsub.viewer
  )
  for role in "${DATAFLOW_ROLES[@]}"; do
    gcloud projects add-iam-policy-binding "$PROJECT" \
      --member="serviceAccount:${DATAFLOW_SA_EMAIL}" \
      --role="$role" --condition=None --quiet > /dev/null 2>&1
  done

  echo "  Dataflow worker SA: $DATAFLOW_SA_EMAIL"
fi

if [ "$MODE" = "org" ]; then
  for role in "${ROLES[@]}"; do
    gcloud organizations add-iam-policy-binding "$ORG_ID" \
      --member="serviceAccount:${SA_EMAIL}" \
      --role="$role" --condition=None --quiet > /dev/null 2>&1
  done
  echo "  Org-level roles granted."
else
  for role in "${ROLES[@]}"; do
    gcloud projects add-iam-policy-binding "$PROJECT" \
      --member="serviceAccount:${SA_EMAIL}" \
      --role="$role" --condition=None --quiet > /dev/null 2>&1
  done
  echo "  Project-level roles granted."
fi

echo "  Service account: $SA_EMAIL"
echo ""

# --- Step 3: Workload Identity Federation ---
echo "Step 3: Setting up Workload Identity Federation..."

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')

# Create WIF pool (undelete first if it was soft-deleted)
POOL_STATE=$(gcloud iam workload-identity-pools describe betterstack-pool \
  --location=global --project="$PROJECT" --format='value(state)' 2>/dev/null || true)
if [ "$POOL_STATE" = "DELETED" ]; then
  gcloud iam workload-identity-pools undelete betterstack-pool \
    --location=global --project="$PROJECT"
elif [ "$POOL_STATE" != "ACTIVE" ]; then
  gcloud iam workload-identity-pools create betterstack-pool \
    --location=global --project="$PROJECT" \
    --display-name="Better Stack Integration"
fi

# Create or update OIDC provider (issuer is Google, locked to our SA email)
WIF_PROVIDER_ARGS=(
  --workload-identity-pool=betterstack-pool
  --location=global --project="$PROJECT"
  --issuer-uri="https://accounts.google.com"
  --attribute-mapping="google.subject=assertion.sub,attribute.sa_email=assertion.email"
  --attribute-condition="assertion.email=='${BETTERSTACK_SA}'"
  --allowed-audiences="https://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/betterstack-pool/providers/betterstack-provider"
)
if gcloud iam workload-identity-pools providers describe betterstack-provider \
  --workload-identity-pool=betterstack-pool --location=global --project="$PROJECT" > /dev/null 2>&1; then
  gcloud iam workload-identity-pools providers update-oidc betterstack-provider "${WIF_PROVIDER_ARGS[@]}" 2>/dev/null || true
else
  gcloud iam workload-identity-pools providers create-oidc betterstack-provider "${WIF_PROVIDER_ARGS[@]}" 2>/dev/null || true
fi

# Grant WIF principal Workload Identity User on customer SA
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/betterstack-pool/attribute.sa_email/${BETTERSTACK_SA}" \
  --role="roles/iam.workloadIdentityUser" --quiet > /dev/null

echo "  WIF pool: betterstack-pool"
echo "  Provider: betterstack-provider (locked to $BETTERSTACK_SA)"
echo "  $BETTERSTACK_SA can now impersonate $SA_EMAIL via WIF"
echo ""

if [ "$SKIP_LOG_FORWARDING" = false ]; then
  # --- Step 4: Pub/Sub resources ---
  echo "Step 4: Creating Pub/Sub resources..."

  gcloud pubsub topics create "$TOPIC_NAME" --project="$PROJECT" 2>/dev/null || true
  gcloud pubsub subscriptions create "$SUB_NAME" \
    --topic="$TOPIC_NAME" --project="$PROJECT" \
    --ack-deadline=60 2>/dev/null || true
  gcloud pubsub topics create "$TOPIC_DEADLETTER" --project="$PROJECT" 2>/dev/null || true

  echo "  Topic: $TOPIC_NAME"
  echo "  Subscription: $SUB_NAME"
  echo "  Deadletter topic: $TOPIC_DEADLETTER"
  echo ""

  # --- Step 5: Log sink ---
  echo "Step 5: Creating log sink ($MODE mode)..."

  SINK_EXCLUSION_FILTER='resource.type="dataflow_step" AND resource.labels.job_name=~"^betterstack-logs-"'

  if [ "$MODE" = "org" ]; then
    gcloud logging sinks create "$SINK_NAME" \
      "pubsub.googleapis.com/projects/${PROJECT}/topics/${TOPIC_NAME}" \
      --organization="$ORG_ID" --include-children \
      --exclusion="name=exclude-betterstack-dataflow,filter=${SINK_EXCLUSION_FILTER}" \
      --quiet 2>/dev/null || true

    WRITER=$(gcloud logging sinks describe "$SINK_NAME" \
      --organization="$ORG_ID" --format='value(writerIdentity)')

    echo "  Sink: $SINK_NAME (org-level, all projects)"
  else
    gcloud logging sinks create "$SINK_NAME" \
      "pubsub.googleapis.com/projects/${PROJECT}/topics/${TOPIC_NAME}" \
      --project="$PROJECT" \
      --exclusion="name=exclude-betterstack-dataflow,filter=${SINK_EXCLUSION_FILTER}" \
      --quiet 2>/dev/null || true

    WRITER=$(gcloud logging sinks describe "$SINK_NAME" \
      --project="$PROJECT" --format='value(writerIdentity)')

    echo "  Sink: $SINK_NAME (project-level)"
  fi
  echo "  Exclusion: betterstack-logs-* dataflow job logs"

  # The logging service account may take a moment to propagate after sink creation
  for i in 1 2 3 4 5; do
    if gcloud pubsub topics add-iam-policy-binding "$TOPIC_NAME" \
      --member="$WRITER" --role=roles/pubsub.publisher \
      --project="$PROJECT" --quiet > /dev/null 2>&1; then
      break
    fi
    echo "  Waiting for logging service account to propagate (attempt $i/5)..."
    sleep 10
  done

  echo "  Writer: $WRITER"
  echo ""

  # --- Step 6: Launch Dataflow job ---
  echo "Step 6: Launching Dataflow job..."

  # Check if a matching job is already running
  EXISTING_JOB=$(gcloud dataflow jobs list --region="$REGION" --project="$PROJECT" \
    --filter="name~^${DATAFLOW_PREFIX} AND state=Running" --format='value(JOB_ID)' 2>/dev/null || true)

  if [ -n "$EXISTING_JOB" ]; then
    echo "  Dataflow job already running: $EXISTING_JOB (skipping)"
  else
    gcloud dataflow flex-template run "${DATAFLOW_PREFIX}-$(date +%Y%m%d-%H%M%S)" \
      --template-file-gcs-location="gs://betterstack/pubsub-to-betterstack.json" \
      --region="$REGION" --project="$PROJECT" \
      --service-account-email="$DATAFLOW_SA_EMAIL" \
      --parameters="input_subscription=projects/${PROJECT}/subscriptions/${SUB_NAME}" \
      --parameters="better_stack_source_token=${SOURCE_TOKEN}" \
      --parameters="better_stack_ingesting_host=${INGESTING_HOST}" \
      --parameters="batch_size=${BATCH_COUNT}"
  fi

  echo ""
else
  echo "Skipping log forwarding (--skip-log-forwarding): no Pub/Sub, log sink, or Dataflow job."
  echo ""
fi

# --- Summary ---
echo "==================================="
echo "Setup complete!"
echo "==================================="
echo ""
echo "  Project:          $PROJECT"
echo "  Service account:  $SA_EMAIL"
echo "  Impersonated by:  $BETTERSTACK_SA"
if [ "$SKIP_LOG_FORWARDING" = false ]; then
  if [ "$MODE" = "org" ]; then
    echo "  Log sink:         $SINK_NAME (org-level, all projects)"
  else
    echo "  Log sink:         $SINK_NAME (project-level)"
  fi
  echo "  Dataflow job:     running in $REGION"
else
  echo "  Log forwarding:   skipped (--skip-log-forwarding)"
fi
echo ""
echo "Configure in Better Stack with:"
echo "  Project ID:     $PROJECT"
echo "  Project Number: $PROJECT_NUMBER"
echo ""
TEARDOWN_CMD="./setup.sh --teardown --project=$PROJECT --region=$REGION --ingesting-host=$INGESTING_HOST"
[ -n "$ORG_ID" ] && TEARDOWN_CMD="$TEARDOWN_CMD --org-id=$ORG_ID"
echo "To remove everything:"
echo "  $TEARDOWN_CMD"
