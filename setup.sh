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
  $(basename "$0") --help

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
EOF
}

print_regions() {
  echo "Supported Dataflow regions:"
  for r in "${DATAFLOW_REGIONS[@]}"; do
    echo "  $r"
  done
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
    *) echo "Unknown argument: $1"; echo "Run with --help for usage."; exit 1 ;;
  esac
done

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

  echo "Deleting WIF pool (cascades providers)..."
  if ! gcloud iam workload-identity-pools delete betterstack-pool \
    --location=global --project="$PROJECT" --quiet 2>&1; then
    echo "  WARNING: Failed to delete WIF pool"
    ERRORS=$((ERRORS + 1))
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

APIS=(logging monitoring compute cloudasset iamcredentials)
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
