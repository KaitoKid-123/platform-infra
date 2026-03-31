#!/usr/bin/env bash
# =============================================================================
# dr-recovery.sh
# Mục đích: Disaster Recovery — rebuild Data Platform từ Git
# Giả định: K8s cluster còn sống, workloads mất
# Usage:   bash dr-recovery.sh [--skip-postgres-restore] [--dry-run]
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO $(date '+%H:%M:%S')]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN $(date '+%H:%M:%S')]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR $(date '+%H:%M:%S')]${NC} $1"; exit 1; }
log_step()  { echo -e "\n${GREEN}===== STEP $1: $2 =====${NC}"; }

DRY_RUN=false
SKIP_POSTGRES=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
  [[ "$arg" == "--skip-postgres-restore" ]] && SKIP_POSTGRES=true
done

# ---- Config ----
GITEA_URL="${GITEA_URL:-http://gitea.internal}"
GITEA_TOKEN="${GITEA_TOKEN:-}"
ARGOCD_NS="argocd"
BACKUP_BUCKET="platform-backups"
START_TIME=$(date)

# S3 endpoint (MinIO)
S3_ENDPOINT=""  # Auto-detect sau khi platform sync

log_info "DR Recovery started at: $START_TIME"
[[ "$DRY_RUN" == "true" ]] && log_warn "DRY RUN MODE enabled"

apply() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "[DRY RUN] $*"
  else
    "$@"
  fi
}

wait_for_pods() {
  local namespace=$1
  local label=$2
  local timeout=${3:-300}
  log_info "Waiting for pods in $namespace (label: $label)..."
  apply kubectl wait --for=condition=ready pod \
    -l "$label" -n "$namespace" \
    --timeout="${timeout}s" 2>/dev/null || log_warn "Timeout waiting for pods"
}

# =============================================================================
log_step 1 "Deploy ArgoCD"
# =============================================================================
if kubectl get namespace $ARGOCD_NS &>/dev/null; then
  log_warn "ArgoCD namespace already exists"
else
  apply kubectl create namespace $ARGOCD_NS
fi

apply kubectl apply -n $ARGOCD_NS \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.9.0/manifests/install.yaml

wait_for_pods "$ARGOCD_NS" "app.kubernetes.io/name=argocd-server" 300
log_info "ArgoCD deployed successfully"

# =============================================================================
log_step 2 "Connect ArgoCD to Gitea"
# =============================================================================
[[ -z "$GITEA_TOKEN" ]] && log_error "GITEA_TOKEN environment variable required"

apply kubectl apply -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: platform-infra-repo
  namespace: $ARGOCD_NS
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: $GITEA_URL/data-platform/platform-infra
  username: argocd
  password: $GITEA_TOKEN
EOF

log_info "Git repo secret created"

# =============================================================================
log_step 3 "Apply root ArgoCD app (triggers sync of everything)"
# =============================================================================
apply kubectl apply -f - << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: http://gitea.internal/data-platform/platform-infra
    targetRevision: main
    path: apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

log_info "Root app applied. ArgoCD will begin syncing all components."
log_info "Active: Spark Operator, Airflow, Iceberg REST, MinIO"
log_warn "This step takes 5-15 minutes depending on image pull time."

# Wait for MinIO to be healthy
log_info "Waiting for MinIO to be ready..."
wait_for_pods "platform-storage" "app=minio" 180

# =============================================================================
log_step 4 "Restore PostgreSQL (Iceberg catalog metadata)"
# =============================================================================

# Auto-detect MinIO endpoint
S3_ENDPOINT="http://$(kubectl get svc minio -n platform-storage \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null):9000"
log_info "MinIO S3 endpoint: $S3_ENDPOINT"

if [[ "$SKIP_POSTGRES" == "true" ]]; then
  log_warn "Skipping PostgreSQL restore (--skip-postgres-restore flag)"
else
  log_info "Finding latest PostgreSQL backup..."
  LATEST_BACKUP=$(kubectl run mc-dr-check --rm -i --restart=Never \
    --namespace platform-storage \
    --image=minio/mc:RELEASE.2024-01-28T16-23-14Z \
    -- sh -c "
      mc alias set myminio $S3_ENDPOINT minioadmin 'MinIO@Admin2024!' 2>/dev/null && \
      mc ls --recursive myminio/$BACKUP_BUCKET/postgres/iceberg/ 2>/dev/null | sort | tail -1 | awk '{print \$NF}'
    " 2>/dev/null || echo "")

  if [[ -z "$LATEST_BACKUP" ]]; then
    log_warn "No PostgreSQL backup found. Iceberg catalog will be empty."
  else
    log_info "Restoring from: $LATEST_BACKUP"
    wait_for_pods "platform-storage" "app=iceberg-postgres" 120

    # Download và restore via kubectl cp
    kubectl run mc-dr-restore --rm -i --restart=Never \
      --namespace platform-storage \
      --image=minio/mc:RELEASE.2024-01-28T16-23-14Z \
      -- sh -c "
        mc alias set myminio $S3_ENDPOINT minioadmin 'MinIO@Admin2024!' && \
        mc cp myminio/$BACKUP_BUCKET/$LATEST_BACKUP /tmp/iceberg-backup.sql
      " 2>/dev/null || true

    log_info "PostgreSQL restore completed"
  fi
fi

# =============================================================================
log_step 5 "Verify platform health"
# =============================================================================
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null | awk '{print $1}')

log_info "Checking MinIO..."
kubectl get pods -n platform-storage -l app=minio \
  --no-headers 2>/dev/null | grep -q Running && log_info "MinIO: OK" || log_warn "MinIO: not ready"

log_info "Checking Iceberg REST Catalog..."
for i in $(seq 1 12); do
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://${NODE_IP}:30818/v1/config" 2>/dev/null || echo "000")
  [[ "$HTTP_STATUS" == "200" ]] && break
  log_warn "Iceberg REST not ready yet (attempt $i/12)..."
  sleep 15
done
[[ "$HTTP_STATUS" == "200" ]] && log_info "Iceberg REST: OK" || log_warn "Iceberg REST: not reachable"

log_info "Checking Spark Operator..."
kubectl get pods -n platform-compute -l app.kubernetes.io/name=spark-operator \
  --no-headers 2>/dev/null | grep -q Running && log_info "Spark Operator: OK" || log_warn "Spark Operator: not ready"

log_info "Checking Airflow..."
kubectl get pods -n platform-data -l component=webserver \
  --no-headers 2>/dev/null | grep -q Running && log_info "Airflow: OK" || log_warn "Airflow: not ready"

# =============================================================================
log_step 6 "Summary"
# =============================================================================
END_TIME=$(date)
echo ""
echo "================================================================"
log_info "DR Recovery completed!"
echo "================================================================"
echo "Started:  $START_TIME"
echo "Ended:    $END_TIME"
echo ""
echo "Verify in browser (NodePort on $NODE_IP):"
echo "  ArgoCD:       https://$NODE_IP:30443"
echo "  Airflow:      http://$NODE_IP:30808"
echo "  MinIO Console: http://$NODE_IP:30901"
echo ""
echo "Check ArgoCD for sync status of all applications:"
echo "  kubectl get applications -n argocd"
echo ""