#!/usr/bin/env bash
# =============================================================================
# onboard-team.sh
# Mục đích: Onboard một team mới vào Data Platform
# Usage:   bash onboard-team.sh <team-name> [--dry-run]
# Example: bash onboard-team.sh finance
# =============================================================================
set -euo pipefail

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---- Validate args ----
[[ $# -lt 1 ]] && log_error "Usage: $0 <team-name> [--dry-run]"
TEAM=$1
DRY_RUN=false
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true

# ---- Config ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TEMPLATE_DIR="$REPO_ROOT/teams/_template"
TEAMS_DIR="$REPO_ROOT/teams"

# Auto-detect endpoints via internal DNS (no need for ClusterIP)
ICEBERG_REST="http://iceberg-rest.platform-storage:8181"
MINIO_ENDPOINT="http://minio.platform-storage:9000"
AWS_CLI_EP="--endpoint-url $MINIO_ENDPOINT"

# MinIO credentials
MINIO_ROOT_USER=$(kubectl get secret minio-credentials -n platform-storage \
  -o jsonpath='{.data.root_user}' 2>/dev/null | base64 -d || echo "minioadmin")
MINIO_ROOT_PASSWORD=$(kubectl get secret minio-credentials -n platform-storage \
  -o jsonpath='{.data.root_password}' 2>/dev/null | base64 -d || echo "")

log_info "Detected endpoints:"
log_info "  MinIO S3:     $MINIO_ENDPOINT"
log_info "  Iceberg REST: $ICEBERG_REST"

# ---- Validate team name ----
if [[ ! "$TEAM" =~ ^[a-z][a-z0-9-]{1,20}$ ]]; then
  log_error "Team name must be lowercase alphanumeric with dashes, 2-20 chars. Got: $TEAM"
fi

# ---- Check prerequisites ----
for tool in kubectl helm curl jq; do
  command -v "$tool" &>/dev/null || log_error "Required tool not found: $tool"
done

log_info "Starting onboarding for team: $TEAM"
[[ "$DRY_RUN" == "true" ]] && log_warn "DRY RUN MODE - no changes will be made"

apply() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "[DRY RUN] Would run: $*"
  else
    "$@"
  fi
}

# =============================================================================
# STEP 1: Generate K8s manifests from template
# =============================================================================
log_info "[1/7] Generating K8s manifests from template..."

TEAM_DIR="$TEAMS_DIR/$TEAM"
if [[ -d "$TEAM_DIR" ]]; then
  log_warn "Team directory already exists: $TEAM_DIR"
else
  mkdir -p "$TEAM_DIR"
  for f in "$TEMPLATE_DIR"/*.yaml; do
    filename=$(basename "$f")
    sed "s/TEAM_NAME/$TEAM/g" "$f" > "$TEAM_DIR/$filename"
    log_info "  Generated: $TEAM_DIR/$filename"
  done

  # Generate RBAC manifests from template
  if [[ -d "$TEMPLATE_DIR/rbac" ]]; then
    mkdir -p "$TEAM_DIR/rbac"
    for f in "$TEMPLATE_DIR/rbac"/*.yaml; do
      filename=$(basename "$f")
      sed "s/TEAM_NAME/$TEAM/g" "$f" > "$TEAM_DIR/rbac/$filename"
      log_info "  Generated: $TEAM_DIR/rbac/$filename"
    done
  fi

  # Generate kustomization.yaml — s3-credentials.yaml is in the same dir (no cross-dir)
  cat > "$TEAM_DIR/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - resource-quota.yaml
  - network-policy.yaml
  - rbac/service-account.yaml
  - rbac/role-binding.yaml
  - s3-credentials.yaml
EOF
  log_info "  Generated kustomization.yaml"
fi

# =============================================================================
# STEP 3: Create K8s Secret với S3 credentials (trước khi apply manifests)
# =============================================================================
log_info "[3/6] Creating K8s secret for S3 credentials..."

S3_ACCESS_KEY="$MINIO_ROOT_USER"
S3_SECRET_KEY="$MINIO_ROOT_PASSWORD"

if [[ "$DRY_RUN" != "true" ]]; then
  kubectl create secret generic "team-$TEAM-s3-creds" \
    --from-literal=access_key="$S3_ACCESS_KEY" \
    --from-literal=secret_key="$S3_SECRET_KEY" \
    --namespace="team-$TEAM" \
    --dry-run=client -o yaml | kubectl apply -f -
  log_info "  K8s secret created: team-$TEAM-s3-creds"
fi

# =============================================================================
# STEP 4: Apply K8s manifests
# =============================================================================
log_info "[4/6] Applying K8s manifests..."
apply kubectl apply -k "$TEAM_DIR/"
apply kubectl wait --for=condition=ready \
  namespace/team-$TEAM --timeout=30s 2>/dev/null || true
log_info "  Namespace team-$TEAM created"

# =============================================================================
# STEP 5: Create S3 bucket in MinIO
# =============================================================================
log_info "[5/6] Creating S3 bucket in MinIO..."

if [[ "$DRY_RUN" != "true" ]]; then
  kubectl run "mc-onboard-$TEAM" --rm -i --restart=Never \
    --namespace platform-storage \
    --image=minio/mc:RELEASE.2024-01-28T16-23-14Z \
    --command -- sh -c "
      mc alias set myminio '$MINIO_ENDPOINT' '$S3_ACCESS_KEY' '$S3_SECRET_KEY' &&
      mc mb --ignore-existing myminio/team-$TEAM &&
      echo 'Bucket team-$TEAM created'
    " || log_warn "  Bucket may already exist"
  log_info "  Created S3 bucket: team-$TEAM"
else
  log_warn "[DRY RUN] Would create S3 bucket: team-$TEAM"
fi

# =============================================================================
# STEP 6: Create Iceberg namespace (via temp pod — Iceberg only reachable inside cluster)
# =============================================================================
log_info "[6/7] Creating Iceberg namespace..."

if [[ "$DRY_RUN" != "true" ]]; then
  # Check if namespace already exists
  CHECK_RESULT=$(kubectl run -n platform-storage "iceberg-ns-check-$TEAM" --rm -i --restart=Never \
    --image=busybox:1.36 -- \
    wget -qO- --timeout=10 "http://iceberg-rest:8181/v1/namespaces/$TEAM" 2>/dev/null || echo '{"error":"not_found"}')

  if echo "$CHECK_RESULT" | grep -q "error"; then
    # Create namespace
    kubectl run -n platform-storage "iceberg-ns-create-$TEAM" --rm -i --restart=Never \
      --image=busybox:1.36 -- \
      wget -qO- --timeout=10 -O- --post-data="{\"namespace\":[\"$TEAM\"],\"properties\":{\"owner\":\"team-$TEAM\",\"location\":\"s3://team-$TEAM/warehouse/\"}}" \
      "http://iceberg-rest:8181/v1/namespaces" \
      --header="Content-Type: application/json" 2>/dev/null || true
    log_info "  Iceberg namespace created: $TEAM"
  else
    log_warn "  Iceberg namespace $TEAM already exists"
  fi
else
  log_warn "[DRY RUN] Would create Iceberg namespace: $TEAM"
fi

# =============================================================================
# STEP 7: Generate ArgoCD Application
# =============================================================================
log_info "[7/7] Generating ArgoCD Application..."

APPS_DIR="$REPO_ROOT/apps"
mkdir -p "$APPS_DIR"
APP_FILE="$APPS_DIR/team-$TEAM-infra-app.yaml"

if [[ -f "$APP_FILE" ]]; then
  log_warn "  ArgoCD app already exists: $APP_FILE"
else
  cat > "$APP_FILE" << EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: team-$TEAM-infra
  namespace: argocd
  annotations:
    notifications.argoproj.io/subscribe.on-sync-failed.slack: platform-alerts
spec:
  project: default
  source:
    repoURL: https://github.com/KaitoKid-123/platform-infra
    targetRevision: main
    path: teams/$TEAM
  destination:
    server: https://kubernetes.default.svc
    namespace: team-$TEAM
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
EOF
  log_info "  Generated: $APP_FILE"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "================================================================"
log_info "Team $TEAM onboarding COMPLETE!"
echo "================================================================"
echo ""
echo "Resources created:"
echo "  K8s namespace:   team-$TEAM"
echo "  S3 bucket:       s3://team-$TEAM"
echo "  K8s secret:      team-$TEAM-s3-creds (in namespace team-$TEAM)"
echo "  Iceberg ns:      iceberg.$TEAM"
echo "  ArgoCD app:      team-$TEAM-infra (apps/team-$TEAM-infra-app.yaml)"
echo "  Container Reg:   ghcr.io/<github-org>/team-$TEAM/"
echo ""
echo "Next steps:"
echo "  1. Commit to GitHub:"
echo "       git add teams/$TEAM/ apps/team-$TEAM-infra-app.yaml"
echo "       git commit -m 'chore: onboard team $TEAM'"
echo "       git push"
echo "     ArgoCD will sync automatically after push."
echo "  2. Push team Docker images to: ghcr.io/<github-org>/team-$TEAM/<image>"
echo "  3. Add team DAGs to platform-dags/dags/$TEAM/"
echo "  4. Add SparkApp YAMLs to platform-dags/dags/$TEAM/spark-apps/"
echo ""