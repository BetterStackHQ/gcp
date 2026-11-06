#!/usr/bin/env bash
# Tests for setup.sh, with gcloud, curl and sleep replaced by mocks on PATH.
# Nothing here calls Google or Better Stack.
#
# Usage: test/setup_test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/setup.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TOKEN="test-token-0123456789abcdef0123456789abcdef"
CALLER="ai-sre-caller@better-stack.iam.gserviceaccount.com"
AUDIENCE="https://betterstack.com/ai-sre/gcp/3f2b9c1e-7a4d-4e1b-9c2f-8d6a5b4c3e21"
PROVIDER="betterstack-ai-sre-3f2b9c1e"
PASSED=0
FAILED=0
CASE=""

# --- Mocks ---

write_mocks() {
  mkdir -p "$WORK/bin"

  cat >"$WORK/bin/gcloud" <<'MOCK'
#!/usr/bin/env bash
# Mock gcloud: keeps the resources it "creates" as files under $MOCK/state.
set -u
S="$MOCK/state"
echo "gcloud $*" >>"$MOCK/calls.log"
ARGS="$*"

# Failure injection: MOCK_FAIL_PATTERN is a regex over the arguments.
if [ -n "${MOCK_FAIL_PATTERN:-}" ] && [[ "$ARGS" =~ $MOCK_FAIL_PATTERN ]]; then
  echo "${MOCK_FAIL_MESSAGE:-ERROR: (gcloud) INTERNAL: injected failure}" >&2
  exit 1
fi

arg_value() { # arg_value --project
  local a
  for a in $ARGS; do
    case "$a" in "$1="*) echo "${a#*=}"; return ;; esac
  done
}

case "$ARGS" in
  "config get-value project") echo "${MOCK_DEFAULT_PROJECT:-}" ;;
  "auth print-access-token") echo "ya29.mock" ;;
  "projects describe "*)
    case "$3" in
      pool-proj) echo "111111111111" ;;
      added-proj) echo "222222222222" ;;
      *) echo "999999999999" ;;
    esac
    ;;
  "iam workload-identity-pools describe "*)
    [ -f "$S/pool" ] || { echo "ERROR: NOT_FOUND" >&2; exit 1; }
    cat "$S/pool"
    ;;
  "iam workload-identity-pools create "*) echo ACTIVE >"$S/pool" ;;
  "iam workload-identity-pools undelete "*) echo ACTIVE >"$S/pool" ;;
  # A deleted provider stays describable in state DELETED, as at Google (for 30 days).
  "iam workload-identity-pools providers list "*)
    for f in "$S"/provider-*; do
      [ -f "$f" ] || continue
      [ "$(cat "$f")" = DELETED ] && continue
      echo "projects/111111111111/locations/global/workloadIdentityPools/betterstack-pool/providers/${f##*/provider-}"
    done
    ;;
  "iam workload-identity-pools providers describe "*)
    [ -f "$S/provider-$5" ] || { echo "ERROR: NOT_FOUND" >&2; exit 1; }
    state=ACTIVE
    [ "$(cat "$S/provider-$5")" = DELETED ] && state=DELETED
    if [[ "$ARGS" == *--format=* ]]; then echo "$state"; else printf 'name: %s\nstate: %s\n' "$5" "$state"; fi
    ;;
  "iam workload-identity-pools providers delete "*) echo DELETED >"$S/provider-$5" ;;
  "iam workload-identity-pools providers undelete "*) echo ACTIVE >"$S/provider-$5" ;;
  "iam workload-identity-pools providers update-oidc "*)
    if [ "$(cat "$S/provider-$5" 2>/dev/null)" = DELETED ]; then
      echo "ERROR: (gcloud.iam.workload-identity-pools.providers.update-oidc) FAILED_PRECONDITION: The provider is deleted." >&2
      exit 1
    fi
    echo "$ARGS" >"$S/provider-$5"
    ;;
  "iam workload-identity-pools providers create-oidc "*)
    [ -f "$S/provider-$5" ] && { echo "ERROR: ALREADY_EXISTS" >&2; exit 1; }
    echo "$ARGS" >"$S/provider-$5"
    ;;
  "iam service-accounts describe "*)
    [ -f "$S/sa-$4" ] || { echo "ERROR: NOT_FOUND" >&2; exit 1; }
    echo "$4"
    ;;
  "iam service-accounts delete "*) rm -f "$S/sa-$4" ;;
  "iam service-accounts create "*)
    touch "$S/sa-$4@$(arg_value --project).iam.gserviceaccount.com"
    ;;
  "iam service-accounts add-iam-policy-binding "*)
    # MOCK_SA_LAG: how many calls fail before a new service account reaches IAM.
    n=$(cat "$S/sa-lag" 2>/dev/null || echo "${MOCK_SA_LAG:-0}")
    if [ "$n" -gt 0 ]; then
      echo $((n - 1)) >"$S/sa-lag"
      echo "ERROR: (gcloud.iam.service-accounts.add-iam-policy-binding) NOT_FOUND: Service account $4 does not exist." >&2
      exit 1
    fi
    echo 0 >"$S/sa-lag"
    ;;
  "projects get-iam-policy "*)
    cat "$S/policy.json" 2>/dev/null || echo '{"bindings": [], "etag": "BwX1"}'
    ;;
  "projects set-iam-policy "*) cp "$4" "$S/policy.json" ;;
  "logging sinks describe "*) echo "serviceAccount:sink-writer@example.iam.gserviceaccount.com" ;;
  *) : ;;
esac
exit 0
MOCK

  cat >"$WORK/bin/curl" <<'MOCK'
#!/usr/bin/env bash
# Mock curl. Answers come from $MOCK/audience.response and $MOCK/post.responses,
# one "STATUS BODY" line per call; the last one repeats.
set -u
method=GET out="" write_out="" data="" url="" auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -w) write_out="$2"; shift 2 ;;
    -d|--data) data="$2"; shift 2 ;;
    -H)
      header="$2"
      [[ "$header" == @* ]] && header=$(cat "${header#@}")
      [[ "$header" == Authorization:* ]] && auth="$header"
      shift 2
      ;;
    --connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "curl $method $url auth=[$auth] data=[$data]" >>"$MOCK/calls.log"

next_response() { # next_response <file>: pops the first line, keeping the last one
  head -n 1 "$1"
  if [ "$(wc -l <"$1")" -gt 1 ]; then
    tail -n +2 "$1" >"$1.next" && mv "$1.next" "$1"
  fi
}

respond() { # respond <"STATUS BODY">
  local status="${1%% *}" body="${1#* }"
  if [ -n "$out" ]; then printf '%s' "$body" >"$out"; else printf '%s' "$body"; fi
  [ -n "$write_out" ] && printf '%s' "$status"
  [ "$status" = "000" ] && { echo "curl: (7) Failed to connect" >&2; exit 7; }
  return 0
}

case "$url" in
  *:testIamPermissions)
    respond "200 $(python3 -c 'import json,sys; print(json.dumps({"permissions": json.loads(sys.argv[1])["permissions"]}))' "$data")"
    ;;
  */api/v1/ai-sre/gcp-registrations/audience) respond "$(next_response "$MOCK/audience.response")" ;;
  */api/v1/ai-sre/gcp-registrations) respond "$(next_response "$MOCK/post.responses")" ;;
  *) echo "mock curl: unexpected URL $url" >&2; exit 2 ;;
esac
MOCK

  cat >"$WORK/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
echo "sleep $*" >>"$MOCK/calls.log"
MOCK

  chmod +x "$WORK/bin/gcloud" "$WORK/bin/curl" "$WORK/bin/sleep"
}

# --- Helpers ---

# start_case <name>: a fresh, empty mock project.
start_case() {
  CASE="$1"
  export MOCK="$WORK/cases/$1"
  rm -rf "$MOCK"
  mkdir -p "$MOCK/state"
  : >"$MOCK/calls.log"
  unset MOCK_FAIL_PATTERN MOCK_FAIL_MESSAGE MOCK_SA_LAG
  export MOCK_DEFAULT_PROJECT="pool-proj"
  audience_response 200 "$(first_audience)"
  post_responses "200 {\"status\": \"active\", \"project_ids\": [\"pool-proj\"]}"
}

# first_audience [project_id]: the audience answer of an integration with no registered project yet.
first_audience() {
  echo "{\"audience\": \"$AUDIENCE\", \"caller_service_account\": \"$CALLER\", \"project_id\": \"${1:-pool-proj}\", \"provider_id\": \"$PROVIDER\", \"pool_project_id\": null, \"pool_project_number\": null, \"service_account_email\": null, \"project_ids\": []}"
}

audience_response() { echo "$1 $2" >"$MOCK/audience.response"; }
audience_responses() { printf '%s\n' "$@" >"$MOCK/audience.response"; }
post_responses() { printf '%s\n' "$@" >"$MOCK/post.responses"; }

# run_setup <args...>: runs setup.sh with the mocks; sets OUTPUT and STATUS.
run_setup() {
  : >"$MOCK/calls.log"
  OUTPUT=$(PATH="$WORK/bin:$PATH" bash "$SCRIPT" "$@" 2>&1 </dev/null)
  STATUS=$?
}

# run_setup_answering <answer> <args...>: like run_setup, typing <answer> at the prompt.
run_setup_answering() {
  local answer="$1"
  shift
  : >"$MOCK/calls.log"
  OUTPUT=$(PATH="$WORK/bin:$PATH" bash "$SCRIPT" "$@" 2>&1 <<<"$answer")
  STATUS=$?
}

pass() { PASSED=$((PASSED + 1)); }
indent() { while IFS= read -r line; do echo "  | $line"; done; }
fail() {
  FAILED=$((FAILED + 1))
  echo "FAIL [$CASE]: $1"
  echo "  --- output ---"
  indent <<<"$OUTPUT"
  echo "  --- calls ---"
  indent <"$MOCK/calls.log"
}

# check <failure message> <command...>: passes when the command succeeds.
check() {
  local message="$1"
  shift
  if "$@"; then pass; else fail "$message"; fi
}
not() { ! "$@"; }
has_output() { grep -qF -- "$1" <<<"$OUTPUT"; }
has_call() { grep -qF -- "$1" "$MOCK/calls.log"; }
call_count_is() { [ "$(grep -cF -- "$1" "$MOCK/calls.log")" -eq "$2" ]; }

assert_status() { check "exit status $STATUS, expected $1" [ "$STATUS" -eq "$1" ]; }
assert_output() { check "output lacks: $1" has_output "$1"; }
refute_output() { check "output has: $1" not has_output "$1"; }
assert_call() { check "no call: $1" has_call "$1"; }
refute_call() { check "unexpected call: $1" not has_call "$1"; }
assert_call_count() { check "$(grep -cF -- "$1" "$MOCK/calls.log") calls of '$1', expected $2" call_count_is "$1" "$2"; }

SA="betterstack-ai-sre@pool-proj.iam.gserviceaccount.com"
ROLES=(roles/mcp.toolUser roles/logging.viewer roles/monitoring.viewer roles/run.viewer roles/browser
  roles/cloudtrace.user roles/errorreporting.viewer roles/container.viewer)
SERVER_APIS="logging.googleapis.com monitoring.googleapis.com run.googleapis.com cloudresourcemanager.googleapis.com cloudtrace.googleapis.com clouderrorreporting.googleapis.com container.googleapis.com"

# --- Cases ---

test_first_run() {
  start_case first_run
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 0
  assert_call "curl GET https://telemetry.betterstack.com/api/v1/ai-sre/gcp-registrations/audience auth=[Authorization: Bearer $TOKEN]"
  refute_call "config get-value"
  assert_call "gcloud services enable iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com $SERVER_APIS --project=pool-proj"
  assert_call "gcloud iam workload-identity-pools create betterstack-pool --location=global --project=pool-proj"
  assert_call "gcloud iam workload-identity-pools providers create-oidc $PROVIDER --workload-identity-pool=betterstack-pool --location=global --project=pool-proj --issuer-uri=https://accounts.google.com --allowed-audiences=$AUDIENCE --attribute-mapping=google.subject=assertion.sub,attribute.sa_email=assertion.email --attribute-condition=assertion.email=='$CALLER'"
  refute_call "betterstack-provider"
  assert_call "gcloud iam service-accounts create betterstack-ai-sre --project=pool-proj"
  local role
  for role in "${ROLES[@]}"; do
    assert_call "gcloud projects add-iam-policy-binding pool-proj --member=serviceAccount:$SA --role=$role --condition=None"
  done
  assert_call_count "gcloud projects add-iam-policy-binding" 8
  refute_call "roles/container.clusterViewer"
  assert_call "gcloud iam service-accounts add-iam-policy-binding $SA --project=pool-proj --member=principalSet://iam.googleapis.com/projects/111111111111/locations/global/workloadIdentityPools/betterstack-pool/attribute.sa_email/$CALLER --role=roles/iam.workloadIdentityUser"
  refute_call "get-iam-policy"
  assert_call "curl POST https://telemetry.betterstack.com/api/v1/ai-sre/gcp-registrations auth=[Authorization: Bearer $TOKEN] data=[{\"project_id\": \"pool-proj\", \"project_number\": \"111111111111\", \"service_account_email\": \"$SA\", \"provider_id\": \"$PROVIDER\"}]"
  assert_output "AI SRE setup complete!"
  assert_output "Connected projects: pool-proj"
  assert_output "To remove AI SRE's access from this project later:"
  assert_output "curl -fsSL https://raw.githubusercontent.com/BetterStackHQ/gcp/main/setup.sh | bash -s -- --ai-sre-remove $PROVIDER --project pool-proj"
  refute_output "$TOKEN"
}

test_explicit_project_reuses_ingestion_pool() {
  start_case reuse_pool
  echo ACTIVE >"$MOCK/state/pool"
  touch "$MOCK/state/provider-betterstack-provider"
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 0
  refute_call "gcloud config get-value project"
  refute_call "workload-identity-pools create"
  assert_output "Reusing existing pool."
  assert_call "providers create-oidc $PROVIDER"
  refute_call "providers update-oidc betterstack-provider"
  refute_call "providers create-oidc betterstack-provider"
}

test_added_project() {
  start_case added_project
  audience_response 200 "{\"audience\": \"$AUDIENCE\", \"caller_service_account\": \"$CALLER\", \"project_id\": \"added-proj\", \"provider_id\": \"$PROVIDER\", \"pool_project_id\": \"pool-proj\", \"pool_project_number\": \"111111111111\", \"service_account_email\": \"$SA\", \"project_ids\": [\"pool-proj\"]}"
  post_responses "200 {\"status\": \"active\", \"project_ids\": [\"pool-proj\", \"added-proj\"]}"
  run_setup --ai-sre "$TOKEN" --project added-proj
  assert_status 0
  assert_call "gcloud services enable $SERVER_APIS --project=added-proj"
  refute_call "iamcredentials"
  refute_call "workload-identity-pools"
  refute_call "service-accounts create"
  refute_call "service-accounts add-iam-policy-binding"
  local role
  for role in "${ROLES[@]}"; do
    assert_call "gcloud projects add-iam-policy-binding added-proj --member=serviceAccount:$SA --role=$role --condition=None"
  done
  refute_call "add-iam-policy-binding pool-proj"
  assert_call "data=[{\"project_id\": \"added-proj\", \"project_number\": \"222222222222\", \"service_account_email\": \"$SA\", \"provider_id\": \"$PROVIDER\"}]"
  assert_output "Connected projects: pool-proj, added-proj"
}

test_project_is_required() {
  start_case project_required
  run_setup --ai-sre "$TOKEN"
  assert_status 1
  assert_output "--project is required"
  refute_call "curl"
  refute_call "gcloud"

  run_setup --ai-sre "$TOKEN" --dry-run
  assert_status 1
  assert_output "--project is required"
}

test_wrong_project_is_refused_before_any_change() {
  start_case wrong_project
  run_setup --ai-sre "$TOKEN" --project other-proj
  assert_status 1
  assert_output "This command is for project pool-proj."
  assert_call_count "curl" 1
  refute_call "gcloud"
}

test_provider_id_must_match_the_audience() {
  start_case provider_mismatch
  audience_response 200 "{\"audience\": \"$AUDIENCE\", \"caller_service_account\": \"$CALLER\", \"project_id\": \"pool-proj\", \"provider_id\": \"betterstack-ai-sre-deadbeef\", \"pool_project_id\": null}"
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 1
  assert_output "unexpected provider ID"
  refute_call "gcloud"

  start_case provider_missing
  audience_response 200 "{\"audience\": \"$AUDIENCE\", \"caller_service_account\": \"$CALLER\", \"project_id\": \"pool-proj\", \"pool_project_id\": null}"
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 1
  assert_output "unexpected provider ID"
  refute_call "gcloud"
}

test_same_team_twice_deletes_the_new_provider() {
  start_case same_team_twice
  echo ACTIVE >"$MOCK/state/pool"
  touch "$MOCK/state/sa-$SA"
  post_responses '422 {"error": "Project pool-proj is already connected to this team.", "retryable": false}'
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 1
  assert_output "Project pool-proj is already connected to this team."
  assert_call "providers create-oidc $PROVIDER"
  assert_call "gcloud iam workload-identity-pools providers delete $PROVIDER --workload-identity-pool=betterstack-pool --location=global --project=pool-proj --quiet"
  assert_output "Deleted provider $PROVIDER, which this run created."
  check "the new provider is still there" grep -qx DELETED "$MOCK/state/provider-$PROVIDER"
  refute_output "--ai-sre-remove"
}

test_refusal_keeps_a_provider_this_run_did_not_create() {
  start_case refusal_existing_provider
  echo ACTIVE >"$MOCK/state/pool"
  touch "$MOCK/state/provider-$PROVIDER"
  post_responses '422 {"error": "Project pool-proj is already connected to this team.", "retryable": false}'
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 1
  assert_call "providers update-oidc $PROVIDER"
  refute_call "providers delete"
  refute_output "which this run created"
}

test_another_integration_in_the_same_project() {
  start_case second_integration
  echo ACTIVE >"$MOCK/state/pool"
  touch "$MOCK/state/provider-betterstack-ai-sre-0a1b2c3d" "$MOCK/state/sa-$SA"
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 0
  assert_call "providers create-oidc $PROVIDER"
  refute_call "betterstack-ai-sre-0a1b2c3d"
  assert_output "Reusing existing service account."
}

test_old_single_provider_is_never_touched() {
  start_case old_provider
  echo ACTIVE >"$MOCK/state/pool"
  touch "$MOCK/state/provider-betterstack-ai-sre"
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 0
  local verb
  for verb in describe create-oidc update-oidc undelete delete; do
    refute_call "providers $verb betterstack-ai-sre "
  done
}

test_remove_last_provider() {
  start_case remove_last
  echo ACTIVE >"$MOCK/state/pool"
  touch "$MOCK/state/provider-$PROVIDER" "$MOCK/state/provider-betterstack-provider" "$MOCK/state/sa-$SA"
  run_setup --ai-sre-remove "$PROVIDER" --project pool-proj
  assert_status 0
  assert_call "gcloud iam workload-identity-pools providers delete $PROVIDER --workload-identity-pool=betterstack-pool --location=global --project=pool-proj --quiet"
  assert_call "gcloud iam workload-identity-pools providers list --workload-identity-pool=betterstack-pool --location=global --project=pool-proj"
  local role
  for role in "${ROLES[@]}"; do
    assert_call "gcloud projects remove-iam-policy-binding pool-proj --member=serviceAccount:$SA --role=$role --condition=None"
  done
  assert_call "gcloud iam service-accounts delete $SA --project=pool-proj --quiet"
  refute_call "workload-identity-pools delete"
  refute_call "providers delete betterstack-provider"
  refute_call "curl"
  assert_output "AI SRE access removed from pool-proj."
}

test_remove_keeps_access_other_integrations_use() {
  start_case remove_shared
  echo ACTIVE >"$MOCK/state/pool"
  touch "$MOCK/state/provider-$PROVIDER" "$MOCK/state/provider-betterstack-ai-sre-0a1b2c3d" "$MOCK/state/sa-$SA"
  run_setup --ai-sre-remove "$PROVIDER" --project pool-proj
  assert_status 0
  assert_call "providers delete $PROVIDER"
  refute_call "providers delete betterstack-ai-sre-0a1b2c3d"
  refute_call "remove-iam-policy-binding"
  refute_call "service-accounts delete"
  assert_output "Kept $SA and its roles: 1 other Better Stack AI SRE integration in this project still uses them."
}

test_remove_again_completes_the_removal() {
  start_case remove_rerun
  echo ACTIVE >"$MOCK/state/pool"
  echo DELETED >"$MOCK/state/provider-$PROVIDER"
  export MOCK_FAIL_PATTERN="remove-iam-policy-binding"
  export MOCK_FAIL_MESSAGE="ERROR: Policy binding with the specified principal, role, and condition not found!"
  run_setup --ai-sre-remove "$PROVIDER" --project pool-proj
  assert_status 0
  refute_call "providers delete"
  assert_output "Provider $PROVIDER is already removed."
  assert_call_count "remove-iam-policy-binding" 8
  refute_call "service-accounts delete"
  assert_output "AI SRE access removed from pool-proj."
}

test_remove_stops_when_the_provider_is_still_there() {
  start_case remove_describe_fails
  echo ACTIVE >"$MOCK/state/pool"
  touch "$MOCK/state/provider-$PROVIDER" "$MOCK/state/sa-$SA"
  export MOCK_FAIL_PATTERN="providers describe $PROVIDER"
  export MOCK_FAIL_MESSAGE="ERROR: (gcloud.iam.workload-identity-pools.providers.describe) UNAVAILABLE: try again"
  run_setup --ai-sre-remove "$PROVIDER" --project pool-proj
  assert_status 1
  assert_output "Provider $PROVIDER is still in betterstack-pool"
  refute_call "remove-iam-policy-binding"
  refute_call "service-accounts delete"
}

test_remove_reports_an_unchecked_service_account() {
  start_case remove_sa_unchecked
  echo ACTIVE >"$MOCK/state/pool"
  touch "$MOCK/state/provider-$PROVIDER" "$MOCK/state/sa-$SA"
  export MOCK_FAIL_PATTERN="service-accounts describe $SA"
  export MOCK_FAIL_MESSAGE="ERROR: (gcloud.iam.service-accounts.describe) PERMISSION_DENIED: Permission 'iam.serviceAccounts.get' denied on resource (or it may not exist)."
  run_setup --ai-sre-remove "$PROVIDER" --project pool-proj
  assert_status 1
  assert_call "providers delete $PROVIDER"
  assert_call_count "remove-iam-policy-binding" 8
  refute_call "service-accounts delete"
  refute_output "Already deleted."
  refute_output "AI SRE access removed"
  assert_output "Could not check service account $SA, so it was not deleted."
  assert_output "PERMISSION_DENIED"
}

test_remove_permission_error() {
  start_case remove_permission
  echo ACTIVE >"$MOCK/state/pool"
  touch "$MOCK/state/provider-$PROVIDER"
  export MOCK_FAIL_PATTERN="providers delete"
  export MOCK_FAIL_MESSAGE="ERROR: (gcloud.iam.workload-identity-pools.providers.delete) PERMISSION_DENIED: Permission 'iam.workloadIdentityPoolProviders.delete' denied on resource (or it may not exist)."
  run_setup --ai-sre-remove "$PROVIDER" --project pool-proj
  assert_status 1
  assert_output "Missing permission: iam.workloadIdentityPoolProviders.delete"
  assert_output "needs roles/iam.workloadIdentityPoolAdmin on project pool-proj"
  refute_call "remove-iam-policy-binding"
}

test_remove_dry_run_and_arguments() {
  start_case remove_dry_run
  run_setup --ai-sre-remove "$PROVIDER" --project pool-proj --dry-run
  assert_status 0
  check "dry run ran a command" not test -s "$MOCK/calls.log"
  assert_output "\$ gcloud iam workload-identity-pools providers delete $PROVIDER"
  assert_output "\$ gcloud projects remove-iam-policy-binding pool-proj --member=serviceAccount:$SA --role=roles/mcp.toolUser"
  assert_output "\$ gcloud iam service-accounts delete $SA"

  start_case remove_args
  run_setup --ai-sre-remove betterstack-ai-sre --project pool-proj
  assert_status 1
  assert_output "--ai-sre-remove needs the provider ID"
  refute_call "gcloud"

  run_setup --ai-sre-remove "$PROVIDER"
  assert_status 1
  assert_output "--project is required"

  run_setup --ai-sre-remove "$PROVIDER" --project pool-proj --ai-sre "$TOKEN"
  assert_status 1
  assert_output "--ai-sre and --ai-sre-remove can't be combined"
  refute_call "gcloud"
}

test_audit_logs() {
  start_case audit_logs
  echo '{"bindings": [], "auditConfigs": [{"service": "allServices", "auditLogConfigs": [{"logType": "ADMIN_READ"}]}], "etag": "BwX1"}' >"$MOCK/state/policy.json"
  run_setup --ai-sre "$TOKEN" --project pool-proj --audit-logs
  assert_status 0
  assert_call "gcloud projects set-iam-policy pool-proj"
  check "audit config not merged into the policy" python3 -c '
import json, sys
p = json.load(open(sys.argv[1]))
mcp = [c for c in p["auditConfigs"] if c["service"] == "mcp.googleapis.com"]
assert mcp == [{"service": "mcp.googleapis.com", "auditLogConfigs": [{"logType": "DATA_READ"}]}], p
assert p["etag"] == "BwX1" and len(p["auditConfigs"]) == 2, p
' "$MOCK/state/policy.json"

  # A second run leaves the policy alone.
  run_setup --ai-sre "$TOKEN" --project pool-proj --audit-logs
  assert_status 0
  assert_output "Already on."
  refute_call "set-iam-policy"
}

test_services_option_is_gone() {
  start_case services_gone
  run_setup --ai-sre "$TOKEN" --project pool-proj --services cloudtrace
  assert_status 1
  assert_output "Unknown argument: --services"
  refute_call "curl"

  run_setup --help
  refute_output "--services"
  refute_output "Preview"
}

test_rerun_after_partial_setup() {
  start_case rerun_partial
  export MOCK_FAIL_PATTERN="service-accounts create"
  export MOCK_FAIL_MESSAGE="ERROR: (gcloud.iam.service-accounts.create) INTERNAL: An internal error occurred."
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 1
  assert_output "Error: Creating service account $SA failed."
  assert_output "INTERNAL: An internal error occurred."
  assert_output "run the same command again"
  refute_call "curl POST"

  unset MOCK_FAIL_PATTERN MOCK_FAIL_MESSAGE
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 0
  refute_call "workload-identity-pools create"
  refute_call "providers create-oidc"
  assert_call "providers update-oidc $PROVIDER --workload-identity-pool=betterstack-pool --location=global --project=pool-proj --issuer-uri=https://accounts.google.com --allowed-audiences=$AUDIENCE"
  assert_call "gcloud iam service-accounts create betterstack-ai-sre"
  assert_call "curl POST"
  assert_output "AI SRE setup complete!"

  # And a third run creates nothing.
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 0
  refute_call " create"
  assert_output "Reusing existing service account."
}

test_new_service_account_propagation() {
  start_case sa_propagation
  export MOCK_SA_LAG=2
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 0
  assert_call_count "iam service-accounts add-iam-policy-binding" 3
  assert_call_count "sleep 5" 2
}

test_org_policy_failure() {
  start_case org_policy
  export MOCK_FAIL_PATTERN="providers create-oidc"
  export MOCK_FAIL_MESSAGE="ERROR: (gcloud.iam.workload-identity-pools.providers.create-oidc) FAILED_PRECONDITION: Precondition check failed. - '@type': type.googleapis.com/google.rpc.PreconditionFailure violations: - description: Org Policy violated for value: 'https://accounts.google.com'. subject: orgpolicy:projects/111111111111 type: constraints/iam.workloadIdentityPoolProviders"
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 1
  assert_output "an organization policy blocks it"
  assert_output "gcloud resource-manager org-policies allow constraints/iam.workloadIdentityPoolProviders https://accounts.google.com --project=pool-proj"
  assert_output "roles/orgpolicy.policyAdmin"
  refute_call "service-accounts create"
  refute_call "curl POST"
}

test_permission_error() {
  start_case permission
  export MOCK_FAIL_PATTERN="projects add-iam-policy-binding"
  export MOCK_FAIL_MESSAGE="ERROR: (gcloud.projects.add-iam-policy-binding) PERMISSION_DENIED: Permission 'resourcemanager.projects.setIamPolicy' denied on resource '//cloudresourcemanager.googleapis.com/projects/pool-proj' (or it may not exist)."
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 1
  assert_output "Error: Granting roles/mcp.toolUser failed: permission denied."
  assert_output "Missing permission: resourcemanager.projects.setIamPolicy"
  assert_output "needs roles/resourcemanager.projectIamAdmin on project pool-proj"
  refute_call "curl POST"

  start_case permission_sa
  export MOCK_FAIL_PATTERN="service-accounts create"
  export MOCK_FAIL_MESSAGE="ERROR: (gcloud.iam.service-accounts.create) PERMISSION_DENIED: Permission 'iam.serviceAccounts.create' denied on resource (or it may not exist)."
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 1
  assert_output "Missing permission: iam.serviceAccounts.create"
  assert_output "needs roles/iam.serviceAccountAdmin on project pool-proj"
}

test_retryable_registration_then_success() {
  start_case retryable
  post_responses \
    '422 {"error": "Could not get an access token yet", "retryable": true}' \
    '422 {"error": "Could not get an access token yet", "retryable": true}' \
    '429 {"error": "Rate limited"}' \
    '200 {"status": "active", "project_ids": ["pool-proj"]}'
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 0
  assert_call_count "curl POST" 4
  assert_call "sleep 5"
  assert_call "sleep 10"
  assert_call "sleep 20"
  assert_output "Not ready yet (HTTP 422: Could not get an access token yet)"
  assert_output "AI SRE setup complete!"
}

test_retryable_registration_gives_up() {
  start_case retryable_timeout
  post_responses '422 {"error": "Could not list tools", "retryable": true}'
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 1
  # 5 + 10 + 20 + 30 + 30 + 30 + 30 = 155 seconds of waiting, then the next wait would pass 180.
  assert_call_count "curl POST" 8
  assert_output "Error: Better Stack could not use the new access after 155 seconds (HTTP 422: Could not list tools)"
  assert_output "run the same command again"
  refute_output "AI SRE setup complete!"
}

test_non_retryable_registration() {
  start_case non_retryable
  post_responses '422 {"error": "Project number is invalid", "retryable": false}'
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 1
  assert_call_count "curl POST" 1
  refute_call "sleep"
  assert_output "Error: Better Stack refused the registration (HTTP 422: Project number is invalid)."
}

test_rejected_token() {
  start_case rejected_token
  audience_response 401 '{"error": "Token is unknown or already used"}'
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 1
  assert_output "Better Stack rejected the registration token (HTTP 401: Token is unknown or already used)"
  assert_output "A token works once."
  assert_output "copy the command from the integration in Better Stack again and run it."
  refute_output "24 hours"
  refute_output "expire"
  refute_call "gcloud"

  start_case rejected_token_on_register
  post_responses '401 {"error": "Token is unknown or already used"}'
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 1
  assert_call_count "curl POST" 1
  assert_output "Better Stack rejected the registration token"

  run_setup --help
  refute_output "expire"
  refute_output "24 hours"
}

test_api_unreachable() {
  start_case unreachable
  audience_response 000 ""
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 1
  assert_output "could not reach https://telemetry.betterstack.com"
  refute_call "gcloud"
}

test_api_url_override() {
  start_case api_url
  run_setup --ai-sre "$TOKEN" --project pool-proj --api-url https://example.test/
  assert_status 0
  assert_call "curl GET https://example.test/api/v1/ai-sre/gcp-registrations/audience"
  assert_call "curl POST https://example.test/api/v1/ai-sre/gcp-registrations"
  refute_call "telemetry.betterstack.com"
}

test_rejects_unexpected_api_answers() {
  start_case bad_audience
  audience_response 200 "{\"audience\": \"https://a.example,https://b.example\", \"caller_service_account\": \"$CALLER\", \"pool_project_id\": null}"
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 1
  assert_output "unexpected audience"
  refute_call "gcloud"

  start_case other_caller
  audience_response 200 "{\"audience\": \"$AUDIENCE\", \"caller_service_account\": \"someone@example.iam.gserviceaccount.com\", \"pool_project_id\": null}"
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 1
  assert_output "trusts only $CALLER"
  refute_call "gcloud"
}

test_dry_run() {
  start_case dry_run
  run_setup --ai-sre "$TOKEN" --dry-run --project pool-proj --audit-logs
  assert_status 0
  check "dry run ran a command" not test -s "$MOCK/calls.log"
  assert_output "\$ curl -sS -X GET"
  assert_output "\$ gcloud iam workload-identity-pools providers create-oidc betterstack-ai-sre-XXXXXXXX"
  assert_output "\$ gcloud projects add-iam-policy-binding pool-proj --member=serviceAccount:$SA --role=roles/cloudtrace.user"
  assert_output "\$ gcloud projects set-iam-policy pool-proj"
  assert_output "\$ curl -sS -X POST"
  assert_output "Authorization: Bearer <token>"
  refute_output "$TOKEN"
  assert_output "Dry run complete: nothing was changed."
}

test_argument_errors() {
  start_case args
  run_setup --ai-sre
  assert_status 1
  assert_output "--ai-sre needs the registration token"

  run_setup --ai-sre --project pool-proj
  assert_status 1
  assert_output "--ai-sre needs the registration token"

  run_setup --ai-sre "$TOKEN" --project pool-proj --api-url --audit-logs
  assert_status 1
  assert_output "--api-url needs a value."

  run_setup --ai-sre "$TOKEN" --project example.com:my-proj
  assert_status 1
  assert_output "domain-scoped projects are not supported"

  run_setup --ai-sre "$TOKEN" --project pool-proj --region=europe-west1
  assert_status 1
  assert_output "can't be combined with the ingestion options"

  run_setup --ai-sre "$TOKEN" --project pool-proj --batch-count=50
  assert_status 1
  assert_output "can't be combined with the ingestion options"

  run_setup --dry-run --project=p --region=europe-west1 --source-token=t --ingesting-host=s1.example.com
  assert_status 1
  assert_output "only available with --ai-sre"
  refute_call "gcloud"

  run_setup --help
  assert_status 0
  assert_output "--ai-sre <token>"
  assert_output "--audit-logs"
  assert_output "billed"
}

test_disabled_pool_and_provider_are_enabled() {
  start_case disabled
  printf 'ACTIVE\tTrue\n' >"$MOCK/state/pool"
  touch "$MOCK/state/provider-$PROVIDER"
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 0
  assert_call "gcloud iam workload-identity-pools update betterstack-pool --location=global --project=pool-proj --no-disabled"
  assert_call "--attribute-condition=assertion.email=='$CALLER' --no-disabled"
}

test_lost_registration_answer() {
  start_case lost_answer
  post_responses '502 <html>Bad Gateway</html>' '401 {"error": "Token already used"}'
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 1
  assert_call_count "curl POST" 2
  assert_output "That attempt may have registered the project"
  refute_output "Get a new command"
}

test_token_starting_with_a_dash() {
  local dash_token="-Xq3vR8_kLm0pZ2aB4cD6eF8gH0iJ2kL4mN6oP8qR0s"
  start_case dash_token
  run_setup --ai-sre "$dash_token" --project pool-proj
  assert_status 0
  assert_call "curl GET https://telemetry.betterstack.com/api/v1/ai-sre/gcp-registrations/audience auth=[Authorization: Bearer $dash_token]"
  assert_output "AI SRE setup complete!"
  refute_output "$dash_token"

  start_case dash_token_equals
  run_setup "--ai-sre=$dash_token" --project pool-proj
  assert_status 0
  assert_call "auth=[Authorization: Bearer $dash_token]"
  refute_output "$dash_token"

  start_case empty_token
  run_setup --ai-sre=
  assert_status 1
  assert_output "--ai-sre needs the registration token"
  refute_call "curl"
}

test_unknown_argument_is_not_echoed() {
  start_case unknown_value
  run_setup --project pool-proj s3cr3t-looking-value
  assert_status 1
  assert_output "Unknown argument"
  refute_output "s3cr3t-looking-value"

  run_setup --no-such-flag=s3cr3t-looking-value
  assert_status 1
  assert_output "Unknown argument: --no-such-flag"
  refute_output "s3cr3t-looking-value"
}

test_audience_fetch_is_retried() {
  start_case audience_retry
  audience_responses \
    '503 {"error": "Service unavailable"}' \
    '429 {"error": "Rate limited"}' \
    "200 $(first_audience)"
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 0
  assert_call_count "curl GET" 3
  assert_call "sleep 5"
  assert_call "sleep 10"
  assert_output "AI SRE setup complete!"

  start_case audience_retry_gives_up
  audience_response 503 '{"error": "Service unavailable"}'
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 1
  assert_call_count "curl GET" 8
  assert_output "Could not fetch the integration's details from Better Stack (HTTP 503: Service unavailable)"
  refute_call "gcloud"
}

test_api_url_must_be_https() {
  start_case api_url_http
  run_setup --ai-sre "$TOKEN" --project pool-proj --api-url http://example.test
  assert_status 1
  assert_output "--api-url must be an https URL."
  refute_call "curl"
}

test_audience_charset() {
  local bad
  for bad in "https://betterstack.com/ai-sre/gcp/x'y" "https://betterstack.com/a b" "http://betterstack.com/ai-sre/gcp/1" "https://betterstack.com/ai-sre/gcp/1?a=b" "https://betterstack.com/ai-sre/gcp/not-a-uuid"; do
    start_case audience_charset
    audience_response 200 "{\"audience\": \"$bad\", \"caller_service_account\": \"$CALLER\", \"pool_project_id\": null}"
    run_setup --ai-sre "$TOKEN" --project pool-proj
    assert_status 1
    assert_output "unexpected audience"
    refute_call "gcloud"
  done
}

test_teardown_keeps_pool_with_ai_sre_provider() {
  start_case teardown_shared_pool
  echo ACTIVE >"$MOCK/state/pool"
  touch "$MOCK/state/provider-betterstack-provider" "$MOCK/state/provider-$PROVIDER"
  run_setup_answering y --teardown --project=pool-proj --region=europe-west1 --ingesting-host=s1.example.com
  assert_status 0
  assert_call "gcloud iam workload-identity-pools providers delete betterstack-provider --workload-identity-pool=betterstack-pool --location=global --project=pool-proj --quiet"
  refute_call "gcloud iam workload-identity-pools delete betterstack-pool"
  refute_call "providers delete $PROVIDER"
  refute_call "betterstack-ai-sre@"
  assert_output "Keeping WIF pool betterstack-pool: it also holds Better Stack AI SRE providers."
  assert_call "gcloud iam service-accounts delete betterstack-integration@pool-proj.iam.gserviceaccount.com"
  assert_output "Teardown complete."
}

test_teardown_keeps_pool_when_providers_cannot_be_listed() {
  start_case teardown_list_fails
  echo ACTIVE >"$MOCK/state/pool"
  touch "$MOCK/state/provider-betterstack-provider" "$MOCK/state/provider-$PROVIDER"
  export MOCK_FAIL_PATTERN="providers list"
  export MOCK_FAIL_MESSAGE="ERROR: (gcloud.iam.workload-identity-pools.providers.list) UNAVAILABLE: The service is currently unavailable."
  run_setup_answering y --teardown --project=pool-proj --region=europe-west1 --ingesting-host=s1.example.com
  assert_status 0
  refute_call "gcloud iam workload-identity-pools delete betterstack-pool"
  assert_call "gcloud iam workload-identity-pools providers delete betterstack-provider --workload-identity-pool=betterstack-pool --location=global --project=pool-proj --quiet"
  refute_call "providers delete $PROVIDER"
  assert_output "Keeping WIF pool betterstack-pool: could not check it for Better Stack AI SRE providers."
  assert_output "UNAVAILABLE"
}

test_teardown_without_ai_sre_deletes_pool() {
  start_case teardown_pool
  echo ACTIVE >"$MOCK/state/pool"
  touch "$MOCK/state/provider-betterstack-provider"
  run_setup_answering y --teardown --project=pool-proj --region=europe-west1 --ingesting-host=s1.example.com
  assert_status 0
  assert_output "Deleting WIF pool (cascades providers)..."
  assert_call "gcloud iam workload-identity-pools delete betterstack-pool --location=global --project=pool-proj --quiet"
  refute_call "providers delete"
  refute_output "Keeping WIF pool"
  assert_output "Teardown complete."
}

test_ingestion_setup_after_teardown_restores_provider() {
  start_case reinstall_after_teardown
  echo ACTIVE >"$MOCK/state/pool"
  touch "$MOCK/state/provider-betterstack-provider" "$MOCK/state/provider-$PROVIDER"
  run_setup_answering y --teardown --project=pool-proj --region=europe-west1 --ingesting-host=s1.example.com
  assert_status 0
  check "teardown did not delete the ingestion provider" grep -qx DELETED "$MOCK/state/provider-betterstack-provider"

  run_setup --project=pool-proj --region=europe-west1 --source-token=src-token --ingesting-host=s1.example.com --skip-log-forwarding
  assert_status 0
  assert_call "gcloud iam workload-identity-pools providers undelete betterstack-provider --workload-identity-pool=betterstack-pool --location=global --project=pool-proj"
  assert_call "providers update-oidc betterstack-provider"
  refute_call "betterstack-ai-sre"
  check "the ingestion provider is not active again" grep -q "update-oidc betterstack-provider" "$MOCK/state/provider-betterstack-provider"
  assert_output "Setup complete!"
}

test_restored_pool_drops_unused_ingestion_provider() {
  start_case restored_pool
  echo DELETED >"$MOCK/state/pool"
  # Restoring a pool brings back its providers, including an old ingestion one.
  touch "$MOCK/state/provider-betterstack-provider"
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 0
  assert_call "gcloud iam workload-identity-pools undelete betterstack-pool"
  assert_call "gcloud iam workload-identity-pools providers delete betterstack-provider --workload-identity-pool=betterstack-pool --location=global --project=pool-proj --quiet"
  assert_output "Deleted the restored ingestion provider betterstack-provider: the ingestion setup is no longer in this project."
  refute_call "providers delete $PROVIDER"
  assert_output "AI SRE setup complete!"

  start_case restored_pool_ingestion_in_use
  echo DELETED >"$MOCK/state/pool"
  touch "$MOCK/state/provider-betterstack-provider" "$MOCK/state/sa-betterstack-integration@pool-proj.iam.gserviceaccount.com"
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 0
  assert_call "gcloud iam workload-identity-pools undelete betterstack-pool"
  refute_call "providers delete"
  refute_output "Deleted the restored ingestion provider"
}

test_restored_pool_keeps_provider_when_check_fails() {
  start_case restored_pool_check_fails
  echo DELETED >"$MOCK/state/pool"
  touch "$MOCK/state/provider-betterstack-provider" "$MOCK/state/sa-betterstack-integration@pool-proj.iam.gserviceaccount.com"
  export MOCK_FAIL_PATTERN="service-accounts describe betterstack-integration@"
  export MOCK_FAIL_MESSAGE="ERROR: (gcloud.iam.service-accounts.describe) PERMISSION_DENIED: Permission 'iam.serviceAccounts.get' denied on resource (or it may not exist)."
  run_setup --ai-sre "$TOKEN" --project pool-proj
  assert_status 0
  assert_call "gcloud iam service-accounts describe betterstack-integration@pool-proj.iam.gserviceaccount.com"
  refute_call "providers delete"
  refute_output "Deleted the restored ingestion provider"
  assert_output "Kept the restored ingestion provider betterstack-provider: could not check whether the ingestion setup still uses it."
  assert_output "AI SRE setup complete!"
}

test_ingestion_mode_still_works() {
  start_case ingestion
  run_setup --project=pool-proj --region=europe-west1 --source-token=src-token --ingesting-host=s1234.eu-nbg-2.betterstackdata.com
  assert_status 0
  assert_output "Setup complete!"
  assert_call "providers create-oidc betterstack-provider"
  assert_call "--attribute-condition=assertion.email=='gcp-integration@better-stack.iam.gserviceaccount.com'"
  refute_call "betterstack-ai-sre"
  refute_call "/api/v1/ai-sre"
}

# --- Run ---

write_mocks
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  "$t"
done
echo ""
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
