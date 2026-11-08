#!/usr/bin/env bash
set -euo pipefail

# Better Stack AI SRE setup for Google Cloud
#
# Gives Better Stack AI SRE read-only access to a GCP project through Google's
# MCP servers. It creates (or reuses) its own workload identity pool,
# betterstack-ai-sre-pool, adds a provider for this integration
# (betterstack-ai-sre-<8 hex>) that accepts only Better Stack's AI SRE caller and
# the integration's audience, and creates a read-only betterstack-ai-sre service
# account. Several integrations, from one or more Better Stack teams, can connect
# the same project: each gets its own provider, and they share the service
# account. The project is then registered with Better Stack using the one-time
# token from the integration.
#
# It never touches the log and metrics ingestion setup (setup.sh): not its
# betterstack-pool, its betterstack-provider or its service accounts.
#
# Every step checks what exists first, so running the same command again after
# a failure completes the setup. --ai-sre-remove undoes it for one integration.
#
# Run with --help for usage information.

# --- Defaults ---
PROJECT=""
AI_SRE=false
AI_SRE_TOKEN=""
AI_SRE_REMOVE=false
AI_SRE_REMOVE_PROVIDER=""
AI_SRE_AUDIT_LOGS=false
AI_SRE_DEFAULT_API_URL="https://telemetry.betterstack.com"
AI_SRE_API_URL="$AI_SRE_DEFAULT_API_URL"
DRY_RUN=false

AI_SRE_CALLER="ai-sre-caller@better-stack.iam.gserviceaccount.com"
# Not the ingestion setup's betterstack-pool: AI SRE never touches it.
AI_SRE_POOL="betterstack-ai-sre-pool"
AI_SRE_PROVIDER_PREFIX="betterstack-ai-sre-"
AI_SRE_PROVIDER=""
AI_SRE_PROVIDER_CREATED=false
AI_SRE_SCRIPT_URL="https://raw.githubusercontent.com/BetterStackHQ/gcp/main/ai-sre-setup.sh"
AI_SRE_SA_NAME="betterstack-ai-sre"
# Read-only roles for the MCP servers: Logging, Monitoring, Cloud Run, Resource
# Manager, Cloud Trace, Error Reporting and Kubernetes Engine.
AI_SRE_ROLES=(
  roles/mcp.toolUser
  roles/logging.viewer
  roles/monitoring.viewer
  roles/run.viewer
  roles/browser
  roles/cloudtrace.user
  roles/errorreporting.viewer
  roles/container.viewer
)
AI_SRE_APIS=(logging monitoring run cloudresourcemanager cloudtrace clouderrorreporting container)
AI_SRE_POOL_APIS=(iam iamcredentials sts)
AI_SRE_REGISTER_TIMEOUT=180
AI_SRE_OUT=""
AI_SRE_STATUS=""
# A line ai_sre_gcloud_failed adds to its explanation, for the call that sets it.
AI_SRE_FAIL_NOTE=""
# Whether this run has started changing the project (so a failure can point at --ai-sre-remove).
AI_SRE_CHANGED=false

# Whether a value is one of this script's own options (so --ai-sre got no token).
ai_sre_is_option() {
  case "${1%%=*}" in
    --help|-h|--project|--ai-sre|--ai-sre-remove|--api-url|--audit-logs|--dry-run) return 0 ;;
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
    echo "  as an identity provider. Allow it for project ${AI_SRE_PROJECT} with the command below"
    echo "  (needs roles/orgpolicy.policyAdmin), then run this script again:"
    echo ""
    echo "    gcloud resource-manager org-policies allow constraints/iam.workloadIdentityPoolProviders https://accounts.google.com --project=${AI_SRE_PROJECT}"
  elif grep -qiE "PERMISSION_DENIED|does not have permission|Permission '[^']+' denied" <<<"$out"; then
    permission=$(grep -oE "Permission '[^']+'" <<<"$out" | head -n 1 | sed -E "s/Permission '([^']+)'/\1/" || true)
    echo "Error: ${what} failed: permission denied."
    [ -n "$permission" ] && echo "  Missing permission: ${permission}"
    echo "  The account running this script needs ${role}."
    echo "  roles/owner includes it."
  else
    echo "Error: ${what} failed."
  fi
  [ -n "$AI_SRE_FAIL_NOTE" ] && echo "  $AI_SRE_FAIL_NOTE"
  echo ""
  echo "  gcloud said:"
  while IFS= read -r line; do
    echo "    $line"
  done <<<"$out"
  ai_sre_rerun_hint
  exit 1
}

# ai_sre_gcloud [--missing-ok] <what> <role needed> <gcloud args...>
# Runs gcloud with its output in AI_SRE_OUT, and exits with an explanation if it fails.
# With --missing-ok, a missing resource or binding returns 1 (AI_SRE_OUT empty) instead.
ai_sre_gcloud() {
  local missing_ok=false what role attempt status
  if [ "$1" = "--missing-ok" ]; then
    missing_ok=true
    shift
  fi
  what="$1" role="$2"
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
    if [ "$missing_ok" = true ] && grep -qE "NOT_FOUND|not found!" "$AI_SRE_TMP/gcloud.err"; then
      AI_SRE_OUT=""
      return 1
    fi
    # A service account created a moment ago can take up to a minute to reach IAM.
    if [ "$attempt" -lt 12 ] && grep -qiE "service ?account .*does not exist" "$AI_SRE_TMP/gcloud.err"; then
      sleep 5
      continue
    fi
    break
  done
  ai_sre_gcloud_failed "$what" "$role" "$(cat "$AI_SRE_TMP/gcloud.err")${AI_SRE_OUT:+$'\n'$AI_SRE_OUT}"
}

# ai_sre_probe <what> <role needed> <gcloud args...>
# Runs a read-only call. AI_SRE_OUT holds its output, or nothing if the resource doesn't
# exist. Any other failure (a denied permission, an outage) stops the script.
ai_sre_probe() {
  ai_sre_gcloud --missing-ok "$@" || true
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
  echo "  A token works once. If the integration in Better Stack is already active, the setup is complete."
  echo "  If it isn't, copy the command from the integration in Better Stack again and run it."
  if [ "$AI_SRE_CHANGED" = true ]; then
    echo "  If the integration was removed from Better Stack, undo what this command set up in ${AI_SRE_PROJECT}:"
    echo "    $(ai_sre_remove_command)"
  fi
  exit 1
}

# ai_sre_remove_command [provider]: the command that removes a provider (this integration's by
# default) and, with the last one, the service account.
ai_sre_remove_command() {
  echo "curl -fsSL ${AI_SRE_SCRIPT_URL} | bash -s -- --ai-sre-remove ${1:-$AI_SRE_PROVIDER} --project ${AI_SRE_PROJECT}"
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
    AI_SRE_PROVIDER="${AI_SRE_PROVIDER_PREFIX}XXXXXXXX"
    echo "  Dry run: using placeholders for the audience and the provider."
    echo ""
    return 0
  fi
  case "$AI_SRE_STATUS" in
    200) ;;
    401) ai_sre_token_rejected ;;
    *) ai_sre_error "Could not fetch the integration's details from Better Stack ($(ai_sre_api_error))." ;;
  esac

  AI_SRE_AUDIENCE=$(ai_sre_json audience)
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

  # The integration's provider is named after the UUID that ends its audience.
  if ! [[ "$AI_SRE_AUDIENCE" =~ /([0-9A-Fa-f]{8})-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    ai_sre_error "Better Stack returned an unexpected audience: '${AI_SRE_AUDIENCE}'."
  fi
  AI_SRE_PROVIDER="${AI_SRE_PROVIDER_PREFIX}$(tr 'A-F' 'a-f' <<<"${BASH_REMATCH[1]}")"
  local provider_id project_id
  provider_id=$(ai_sre_json provider_id)
  if [ "$provider_id" != "$AI_SRE_PROVIDER" ]; then
    ai_sre_error "Better Stack returned an unexpected provider ID: '${provider_id}' (expected ${AI_SRE_PROVIDER}). Use the latest version of this script."
  fi
  # Nothing has changed yet: refuse a project other than the integration's.
  project_id=$(ai_sre_json project_id)
  if [ "$project_id" != "$AI_SRE_PROJECT" ]; then
    ai_sre_error "This command is for project ${project_id:-(none)}, not ${AI_SRE_PROJECT}. To connect ${AI_SRE_PROJECT}, add a Google Cloud integration for it in Better Stack."
  fi
  echo "  Audience: $AI_SRE_AUDIENCE"
  echo "  Provider: $AI_SRE_PROVIDER"
  echo ""
}

ai_sre_project_number() {
  echo "Reading project ${AI_SRE_PROJECT}..."
  # Google answers the same for a project that doesn't exist and one the caller can't read.
  AI_SRE_FAIL_NOTE="If ${AI_SRE_PROJECT} isn't the right project ID: this command works only for it. To connect another project, add a Google Cloud integration for it in Better Stack."
  ai_sre_gcloud "Reading project ${AI_SRE_PROJECT}" "roles/browser on project ${AI_SRE_PROJECT}" \
    projects describe "$AI_SRE_PROJECT" --format='value(projectNumber)'
  AI_SRE_FAIL_NOTE=""
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
  ai_sre_probe "Checking pool ${AI_SRE_POOL}" "$role" iam workload-identity-pools describe "$AI_SRE_POOL" \
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
        --display-name="Better Stack AI SRE"
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
  ai_sre_probe "Checking provider ${AI_SRE_PROVIDER}" "$role" \
    iam workload-identity-pools providers describe "$AI_SRE_PROVIDER" \
    --workload-identity-pool="$AI_SRE_POOL" --location=global --project="$AI_SRE_PROJECT" --format='value(state)'
  AI_SRE_OUT=$(tr -d '[:space:]' <<<"$AI_SRE_OUT")
  if [ "$AI_SRE_OUT" = "DELETED" ]; then
    ai_sre_gcloud "Restoring provider ${AI_SRE_PROVIDER}" "$role" \
      iam workload-identity-pools providers undelete "$AI_SRE_PROVIDER" \
      --workload-identity-pool="$AI_SRE_POOL" --location=global --project="$AI_SRE_PROJECT"
    AI_SRE_PROVIDER_CREATED=true
    AI_SRE_OUT="ACTIVE"
  fi
  if [ "$AI_SRE_OUT" = "ACTIVE" ]; then
    ai_sre_gcloud "Updating provider ${AI_SRE_PROVIDER}" "$role" \
      iam workload-identity-pools providers update-oidc "$AI_SRE_PROVIDER" "${args[@]}" --no-disabled
  else
    ai_sre_gcloud "Creating provider ${AI_SRE_PROVIDER}" "$role" \
      iam workload-identity-pools providers create-oidc "$AI_SRE_PROVIDER" "${args[@]}" \
      --display-name="Better Stack AI SRE"
    AI_SRE_PROVIDER_CREATED=true
  fi
}

# ai_sre_service_account_exists <role needed>: whether the AI SRE service account exists.
# Listed, not described: for weeks after a service account is deleted, Google answers describe
# and delete on its email with PERMISSION_DENIED, not NOT_FOUND, but no longer lists it.
ai_sre_service_account_exists() {
  ai_sre_gcloud "Checking service account ${AI_SRE_SA}" "$1" \
    iam service-accounts list --project="$AI_SRE_PROJECT" --filter="email=${AI_SRE_SA}" --format='value(email)'
  [ -n "$(tr -d '[:space:]' <<<"$AI_SRE_OUT")" ]
}

ai_sre_ensure_service_account() {
  local role="roles/iam.serviceAccountAdmin on project ${AI_SRE_PROJECT}"
  echo "Setting up service account ${AI_SRE_SA}..."
  if ai_sre_service_account_exists "$role"; then
    echo "  Reusing existing service account."
    return 0
  fi
  ai_sre_gcloud "Creating service account ${AI_SRE_SA}" "$role" \
    iam service-accounts create "$AI_SRE_SA_NAME" --project="$AI_SRE_PROJECT" \
    --display-name="Better Stack AI SRE" --description="Read-only access for Better Stack AI SRE"
}

ai_sre_grant_roles() {
  local role
  echo "Granting read-only roles to ${AI_SRE_SA} on ${AI_SRE_PROJECT}..."
  for role in "${AI_SRE_ROLES[@]}"; do
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

# After a refusal, deletes the integration's provider if this run created it.
ai_sre_delete_own_provider() {
  [ "$AI_SRE_PROVIDER_CREATED" = true ] || return 0
  ai_sre_gcloud "Deleting provider ${AI_SRE_PROVIDER}" "roles/iam.workloadIdentityPoolAdmin on project ${AI_SRE_PROJECT}" \
    iam workload-identity-pools providers delete "$AI_SRE_PROVIDER" \
    --workload-identity-pool="$AI_SRE_POOL" --location=global --project="$AI_SRE_PROJECT" --quiet
  echo "  Deleted provider ${AI_SRE_PROVIDER}, which this run created."
}

ai_sre_register() {
  local body retryable unanswered=false
  body=$(python3 -c 'import json, sys; print(json.dumps({"project_id": sys.argv[1], "project_number": sys.argv[2], "service_account_email": sys.argv[3], "provider_id": sys.argv[4]}))' \
    "$AI_SRE_PROJECT" "$AI_SRE_PROJECT_NUMBER" "$AI_SRE_SA" "$AI_SRE_PROVIDER")
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
          ai_sre_delete_own_provider
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
      echo "To undo what this command set up in ${AI_SRE_PROJECT} instead:"
      echo "  $(ai_sre_remove_command)"
      exit 1
    fi
  done
}

# Creates the script's private working directory, removed on exit.
ai_sre_make_tmp() {
  AI_SRE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ai-sre.XXXXXX")
  # shellcheck disable=SC2064 # expand the path now
  trap "rm -rf '$AI_SRE_TMP'" EXIT
}

# Sets AI_SRE_PROJECT from --project, which is required.
ai_sre_require_project() {
  AI_SRE_PROJECT="${PROJECT:-}"
  [ -n "$AI_SRE_PROJECT" ] || ai_sre_error "--project is required: pass the project ID shown on the integration in Better Stack."
  [[ "$AI_SRE_PROJECT" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || ai_sre_error "'${AI_SRE_PROJECT}' is not a valid project ID (domain-scoped projects are not supported)."
}

ai_sre_main() {
  if [ "$AI_SRE_REMOVE" = true ]; then
    ai_sre_error "--ai-sre and --ai-sre-remove can't be combined."
  fi
  if [ -z "$AI_SRE_TOKEN" ] || ai_sre_is_option "$AI_SRE_TOKEN"; then
    ai_sre_error "--ai-sre needs the registration token shown on the GCP integration in Better Stack."
  fi
  if ! [[ "$AI_SRE_TOKEN" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
    ai_sre_error "The registration token has unexpected characters. Copy the command from Better Stack again."
  fi
  ai_sre_require_project
  AI_SRE_API_URL="${AI_SRE_API_URL%/}"
  [[ "$AI_SRE_API_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]] || ai_sre_error "--api-url must be an https URL."

  command -v python3 >/dev/null || ai_sre_error "python3 is required."
  if [ "$DRY_RUN" = false ]; then
    command -v gcloud >/dev/null || ai_sre_error "gcloud is required: https://cloud.google.com/sdk/docs/install"
    command -v curl >/dev/null || ai_sre_error "curl is required."
  fi

  ai_sre_make_tmp
  printf 'Authorization: Bearer %s\n' "$AI_SRE_TOKEN" >"$AI_SRE_TMP/auth-header"

  echo "Better Stack AI SRE Setup"
  echo "========================="
  echo ""
  if [ "$DRY_RUN" = true ]; then
    echo "Dry run: printing every gcloud and curl call without running any."
    echo ""
  fi

  ai_sre_fetch_audience

  AI_SRE_SA="${AI_SRE_SA_NAME}@${AI_SRE_PROJECT}.iam.gserviceaccount.com"

  echo "  Project:          $AI_SRE_PROJECT"
  echo "  Identity pool:    $AI_SRE_POOL (its own; the ingestion setup's pool is not touched)"
  echo "  Service account:  $AI_SRE_SA"
  echo "  Servers:          ${AI_SRE_APIS[*]}"
  echo "  Audit logs:       $([ "$AI_SRE_AUDIT_LOGS" = true ] && echo "on (DATA_READ for mcp.googleapis.com)" || echo "not changed (--audit-logs turns them on)")"
  echo ""

  ai_sre_project_number
  AI_SRE_CHANGED=true
  ai_sre_enable_apis "${AI_SRE_POOL_APIS[@]}" "${AI_SRE_APIS[@]}"
  ai_sre_ensure_pool
  ai_sre_ensure_provider
  ai_sre_ensure_service_account
  ai_sre_grant_roles
  ai_sre_allow_impersonation
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
  echo ""
  echo "The integration is now active in Better Stack."
  echo ""
  echo "To remove AI SRE's access from this project later:"
  echo "  $(ai_sre_remove_command)"
}

# --- AI SRE removal (--ai-sre-remove) ---

ai_sre_remove_main() {
  local role pool_role sa_role name others=()
  if [ "$AI_SRE" = true ]; then
    ai_sre_error "--ai-sre and --ai-sre-remove can't be combined."
  fi
  if ! [[ "$AI_SRE_REMOVE_PROVIDER" =~ ^betterstack-ai-sre-[0-9a-f]{8}$ ]]; then
    ai_sre_error "--ai-sre-remove needs the provider ID printed at the end of the setup (betterstack-ai-sre-<8 hex>)."
  fi
  if [ "$AI_SRE_AUDIT_LOGS" = true ] || [ "$AI_SRE_API_URL" != "$AI_SRE_DEFAULT_API_URL" ]; then
    ai_sre_error "--ai-sre-remove takes only --project and --dry-run."
  fi
  ai_sre_require_project
  if [ "$DRY_RUN" = false ]; then
    command -v gcloud >/dev/null || ai_sre_error "gcloud is required: https://cloud.google.com/sdk/docs/install"
  fi
  ai_sre_make_tmp
  AI_SRE_PROVIDER="$AI_SRE_REMOVE_PROVIDER"
  AI_SRE_SA="${AI_SRE_SA_NAME}@${AI_SRE_PROJECT}.iam.gserviceaccount.com"
  pool_role="roles/iam.workloadIdentityPoolAdmin on project ${AI_SRE_PROJECT}"

  echo "Better Stack AI SRE Removal"
  echo "==========================="
  echo ""
  if [ "$DRY_RUN" = true ]; then
    echo "Dry run: printing every gcloud call without running any."
    echo ""
  fi

  echo "Removing provider ${AI_SRE_PROVIDER} from ${AI_SRE_POOL} in ${AI_SRE_PROJECT}..."
  ai_sre_probe "Checking provider ${AI_SRE_PROVIDER}" "$pool_role" \
    iam workload-identity-pools providers describe "$AI_SRE_PROVIDER" \
    --workload-identity-pool="$AI_SRE_POOL" --location=global --project="$AI_SRE_PROJECT" --format='value(state)'
  if [ "$DRY_RUN" = true ] || [ "$(tr -d '[:space:]' <<<"$AI_SRE_OUT")" = "ACTIVE" ]; then
    ai_sre_gcloud "Deleting provider ${AI_SRE_PROVIDER}" "$pool_role" \
      iam workload-identity-pools providers delete "$AI_SRE_PROVIDER" \
      --workload-identity-pool="$AI_SRE_POOL" --location=global --project="$AI_SRE_PROJECT" --quiet
    [ "$DRY_RUN" = true ] || echo "  Deleted provider ${AI_SRE_PROVIDER}."
  else
    echo "  Provider ${AI_SRE_PROVIDER} is already removed."
  fi

  # The service account and its roles go only with the last AI SRE provider.
  echo "Checking for other Better Stack AI SRE providers..."
  ai_sre_probe "Listing the providers in ${AI_SRE_POOL}" "$pool_role" \
    iam workload-identity-pools providers list --workload-identity-pool="$AI_SRE_POOL" \
    --location=global --project="$AI_SRE_PROJECT" --format='value(name)'
  while IFS= read -r name; do
    name="${name##*/}"
    if [ "$name" != "$AI_SRE_PROVIDER" ] && [[ "$name" =~ ^betterstack-ai-sre-[0-9a-f]{8}$ ]]; then
      others+=("$name")
    fi
  done <<<"$AI_SRE_OUT"
  if [ "${#others[@]}" -gt 0 ]; then
    # This script can't tell whether their integrations still exist in Better Stack: name them.
    echo "  Kept ${AI_SRE_SA} and its roles: these AI SRE providers in ${AI_SRE_PROJECT} still use them:"
    for name in "${others[@]}"; do
      echo "    ${name}"
    done
    echo "  Each belongs to a Google Cloud integration in Better Stack. If that integration was removed, remove its provider too:"
    for name in "${others[@]}"; do
      echo "    $(ai_sre_remove_command "$name")"
    done
  else
    echo "Removing the roles of ${AI_SRE_SA}..."
    for role in "${AI_SRE_ROLES[@]}"; do
      echo "  $role"
      # A binding that is already gone is fine.
      ai_sre_gcloud --missing-ok "Removing ${role}" "roles/resourcemanager.projectIamAdmin on project ${AI_SRE_PROJECT}" \
        projects remove-iam-policy-binding "$AI_SRE_PROJECT" \
        --member="serviceAccount:${AI_SRE_SA}" --role="$role" --condition=None --quiet || true
    done
    echo "Deleting service account ${AI_SRE_SA}..."
    sa_role="roles/iam.serviceAccountAdmin on project ${AI_SRE_PROJECT}"
    if ai_sre_service_account_exists "$sa_role" || [ "$DRY_RUN" = true ]; then
      ai_sre_gcloud --missing-ok "Deleting service account ${AI_SRE_SA}" "$sa_role" \
        iam service-accounts delete "$AI_SRE_SA" --project="$AI_SRE_PROJECT" --quiet || echo "  Already deleted."
    else
      echo "  Already deleted."
    fi
  fi

  echo ""
  if [ "$DRY_RUN" = true ]; then
    echo "Dry run complete: nothing was changed."
    return 0
  fi
  if [ "${#others[@]}" -gt 0 ]; then
    echo "Removed provider ${AI_SRE_PROVIDER} from ${AI_SRE_PROJECT}. AI SRE can still reach ${AI_SRE_PROJECT} through the providers listed above."
    return 0
  fi
  echo "AI SRE access removed from ${AI_SRE_PROJECT}."
  echo "The workload identity pool ${AI_SRE_POOL} stays, so a later setup can reuse it; it grants no access without a provider."
}


print_usage() {
  cat <<USAGE
Better Stack AI SRE Setup for Google Cloud

Usage:
  $(basename "$0") --ai-sre <token> --project <id> [options]
  $(basename "$0") --ai-sre-remove <provider id> --project <id> [--dry-run]
  $(basename "$0") --help

  --ai-sre <token>           Registration token from the GCP integration in Better Stack
  --project <id>             Project to connect (required; the one shown in Better Stack)
  --audit-logs               Turn on Data Access audit logs (DATA_READ) for
                             mcp.googleapis.com. Off by default: they are billed
                             as Cloud Logging ingestion.
  --api-url <url>            Better Stack API base URL (default: ${AI_SRE_DEFAULT_API_URL})
  --dry-run                  Print every gcloud and curl call without running any
  --ai-sre-remove <id>       Remove an integration's provider (betterstack-ai-sre-<8 hex>,
                             printed at the end of the setup). With no other AI SRE
                             provider left, also removes the service account and its roles.
  --help, -h                 Show this help and exit

Log and metrics ingestion is set up by setup.sh, not this script.
USAGE
}

# --- Parse arguments ---
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) print_usage; exit 0 ;;
    --project=*) PROJECT="${1#*=}"; shift ;;
    --project) [[ "${2:--}" != -* ]] || ai_sre_error "--project needs a value."; PROJECT="$2"; shift 2 ;;
    --ai-sre=*) AI_SRE=true; AI_SRE_TOKEN="${1#*=}"; shift ;;
    --ai-sre)
      # Tokens can start with "-", so take any next value that isn't one of this script's options.
      AI_SRE=true
      if [ $# -ge 2 ] && ! ai_sre_is_option "$2"; then AI_SRE_TOKEN="$2"; shift; fi
      shift
      ;;
    --ai-sre-remove=*) AI_SRE_REMOVE=true; AI_SRE_REMOVE_PROVIDER="${1#*=}"; shift ;;
    --ai-sre-remove)
      AI_SRE_REMOVE=true
      if [ $# -ge 2 ] && ! ai_sre_is_option "$2"; then AI_SRE_REMOVE_PROVIDER="$2"; shift; fi
      shift
      ;;
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

if [ "$AI_SRE" = true ]; then
  ai_sre_main
elif [ "$AI_SRE_REMOVE" = true ]; then
  ai_sre_remove_main
else
  print_usage
  exit 1
fi
