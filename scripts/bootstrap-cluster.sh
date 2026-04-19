#!/usr/bin/env bash
# =============================================================================
# bootstrap-cluster.sh
# Mục đích: Bootstrap toàn bộ Data Platform từ cluster K8s trống
# Thứ tự: local-path-provisioner → MinIO → ArgoCD + root-app
# GitOps: ArgoCD syncs from GitHub (KaitoKid-123/platform-infra, platform-dags)
#
# Usage:   bash bootstrap-cluster.sh [--dry-run]
# Yêu cầu: kubectl, helm, git đã cài và kubeconfig đã trỏ đúng cluster
# =============================================================================
set -euo pipefail

# ---- Colors & logging ----
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO  $(date '+%H:%M:%S')]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN  $(date '+%H:%M:%S')]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR $(date '+%H:%M:%S')]${NC} $1"; exit 1; }
log_step()  { echo -e "\n${CYAN}══════════════════════════════════════════════════${NC}"; \
              echo -e "${CYAN}  PHASE $1: $2${NC}"; \
              echo -e "${CYAN}══════════════════════════════════════════════════${NC}"; }

# ---- Parse args ----
DRY_RUN=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

# ---- Config ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

ARGOCD_VERSION="v2.14.21"
GITHUB_USER="KaitoKid-123"
GITHUB_PAT="${GITHUB_PAT:-}"           # Set via env: export GITHUB_PAT=ghp_...
GITHUB_REPO_INFRA="platform-infra"
GITHUB_REPO_DAGS="platform-dags"

START_TIME=$(date)

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
  log_info "Waiting for pods: namespace=$namespace label=$label (timeout ${timeout}s)..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "[DRY RUN] Would wait for pods"
    return 0
  fi
  kubectl wait --for=condition=ready pod \
    -l "$label" -n "$namespace" \
    --timeout="${timeout}s" 2>/dev/null || {
      log_warn "Timeout waiting for pods (namespace=$namespace, label=$label)"
      return 1
    }
}

# ---- Validate prerequisites ----
log_info "Validating prerequisites..."
for tool in kubectl helm git curl; do
  command -v "$tool" &>/dev/null || log_error "Required tool not found: $tool"
done

kubectl cluster-info &>/dev/null || log_error "Cannot connect to Kubernetes cluster. Check kubeconfig."

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
log_info "Cluster connected: $NODE_COUNT node(s) detected"
[[ "$NODE_COUNT" -lt 1 ]] && log_error "No nodes found in cluster"

# Node IP cho NodePort access (override bằng env NODE_IP)
NODE_IP="${NODE_IP:-103.249.117.229}"
log_info "Node IP (for summary display): $NODE_IP"

[[ "$DRY_RUN" == "true" ]] && log_warn "DRY RUN MODE — no changes will be made"

echo ""
log_info "Bootstrap plan:"
log_info "  Phase 1: local-path-provisioner (StorageClass for PVCs)"
log_info "  Phase 2: MinIO (S3-compatible object storage)"
log_info "  Phase 3: ArgoCD $ARGOCD_VERSION + root-app (sync from GitHub)"
log_info ""
log_info "  Access: NodePort trên $NODE_IP"
log_info "  GitOps:  GitHub ($GITHUB_USER/$GITHUB_REPO_INFRA)"
log_info "  Active services: Airflow, Spark Operator, Iceberg REST + PostgreSQL, MinIO"
log_info "  Disabled: Trino, Kafka, OpenMetadata, Harbor, Flink, Rook-Ceph"
echo ""

# =============================================================================
log_step 1 "local-path-provisioner — StorageClass"
# =============================================================================

log_info "Installing local-path-provisioner..."
apply kubectl apply -f "$REPO_ROOT/services/storage/local-path-provisioner.yaml"

wait_for_pods "local-path-storage" "app=local-path-provisioner" 120

if [[ "$DRY_RUN" != "true" ]]; then
  SC=$(kubectl get storageclass local-path --no-headers 2>/dev/null || echo "")
  if [[ -n "$SC" ]]; then
    log_info "StorageClass 'local-path' created (default)"
  else
    log_warn "StorageClass not found, checking..."
    kubectl get storageclass
  fi
fi

# =============================================================================
log_step 2 "MinIO — S3-compatible Object Storage"
# =============================================================================

log_info "Creating platform-storage namespace..."
if [[ "$DRY_RUN" == "true" ]]; then
  log_warn "[DRY RUN] kubectl create namespace platform-storage"
else
  kubectl create namespace platform-storage --dry-run=client -o yaml | kubectl apply -f -
fi

log_info "Installing MinIO..."
apply kubectl apply -f "$REPO_ROOT/services/storage/minio.yaml"

wait_for_pods "platform-storage" "app=minio" 180

log_info "Waiting for MinIO bucket creation job..."
if [[ "$DRY_RUN" != "true" ]]; then
  for i in $(seq 1 20); do
    JOB_STATUS=$(kubectl get job minio-create-buckets -n platform-storage \
      -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
    if [[ "$JOB_STATUS" == "1" ]]; then
      log_info "MinIO buckets created (data-lake, platform-backups, team-finance)"
      break
    fi
    log_warn "Bucket creation job not done yet (attempt $i/20)..."
    sleep 10
  done
fi

log_info "MinIO available (ClusterIP: minio.platform-storage:9000 / Console NodePort: 30901)"

# =============================================================================
log_step 3 "ArgoCD — GitOps Controller"
# =============================================================================

# --- 3a. Validate GitHub credentials ---
if [[ -z "$GITHUB_PAT" ]]; then
  log_error "GITHUB_PAT not set. Please run: export GITHUB_PAT=ghp_..."
fi

log_info "Validating GitHub PAT..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: token $GITHUB_PAT" \
  "https://api.github.com/user" 2>/dev/null || echo "000")
if [[ "$HTTP_STATUS" != "200" ]]; then
  log_error "GitHub PAT invalid (HTTP $HTTP_STATUS). Check your token has 'repo' scope."
fi
log_info "GitHub PAT valid"

# --- 3b. Install ArgoCD ---
log_info "Installing ArgoCD $ARGOCD_VERSION..."
if [[ "$DRY_RUN" == "true" ]]; then
  log_warn "[DRY RUN] kubectl create namespace argocd"
else
  if kubectl get namespace argocd 2>/dev/null | grep -q Terminating; then
    log_info "Waiting for old argocd namespace to finish terminating..."
    kubectl wait --for=delete namespace/argocd --timeout=120s 2>/dev/null || true
  fi
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
fi
kubectl apply -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml" || {
    log_warn "First apply failed (may be transient), retrying in 10s..."
    sleep 10
    kubectl apply -n argocd \
      -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"
  }

log_info "Waiting for ALL ArgoCD pods to be ready..."
if [[ "$DRY_RUN" != "true" ]]; then
  kubectl wait --for=condition=ready pod --all -n argocd --timeout=300s 2>/dev/null || {
    log_warn "Some ArgoCD pods not ready yet, waiting 30s more..."
    sleep 30
    kubectl wait --for=condition=ready pod --all -n argocd --timeout=120s 2>/dev/null || true
  }
fi

# Xóa NetworkPolicies — CFKE Cilium enforce chúng, block kết nối nội bộ ArgoCD
log_info "Removing ArgoCD NetworkPolicies (incompatible with CFKE Cilium)..."
kubectl delete networkpolicies --all -n argocd 2>/dev/null || true

# Restart ArgoCD pods sau khi xóa NetworkPolicies để đảm bảo kết nối thông
log_info "Restarting ArgoCD pods to apply network changes..."
kubectl rollout restart deployment argocd-repo-server -n argocd 2>/dev/null || true
kubectl rollout restart deployment argocd-server -n argocd 2>/dev/null || true
kubectl rollout restart statefulset argocd-application-controller -n argocd 2>/dev/null || true
sleep 10
kubectl wait --for=condition=ready pod --all -n argocd --timeout=180s 2>/dev/null || true

# Enable Helm trong Kustomize builds
log_info "Enabling Helm support for Kustomize in ArgoCD..."
kubectl patch configmap argocd-cm -n argocd --type merge \
  -p '{"data":{"kustomize.buildOptions":"--enable-helm"}}' 2>/dev/null || true

# Giảm repo cache để tránh lỗi "failed to untar" khi push code mới
log_info "Setting repo-server cache expiration to 1m..."
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge \
  -p '{"data":{"reposerver.repo.cache.expiration":"1m"}}' 2>/dev/null || true

# --- 3c. Lấy admin password ---
if [[ "$DRY_RUN" != "true" ]]; then
  ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "UNKNOWN")
  log_info "ArgoCD initial admin password: $ARGOCD_PASS"
  log_warn "Change this password after first login!"
else
  ARGOCD_PASS="DRY_RUN"
fi

# --- 3d. Tạo default AppProject ---
log_info "Waiting for ArgoCD CRDs to be ready..."
if [[ "$DRY_RUN" != "true" ]]; then
  for i in $(seq 1 30); do
    if kubectl get crd appprojects.argoproj.io &>/dev/null; then
      log_info "ArgoCD CRDs ready"
      break
    fi
    log_warn "Waiting for CRDs (attempt $i/30)..."
    sleep 5
  done
fi

log_info "Creating default AppProject..."
if [[ "$DRY_RUN" != "true" ]]; then
  kubectl apply -f - << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: default
  namespace: argocd
spec:
  description: Default project
  sourceRepos:
    - '*'
  destinations:
    - namespace: '*'
      server: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
EOF
fi

# --- 3e. Expose ArgoCD qua NodePort ---
log_info "Exposing ArgoCD via NodePort..."
apply kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "NodePort", "ports": [{"port": 443, "targetPort": 8080, "nodePort": 30443, "name": "https"}]}}'

# --- 3f. Đăng ký GitHub repo credentials ---
log_info "Registering GitHub repository credentials with ArgoCD..."
if [[ "$DRY_RUN" != "true" ]]; then
  # Credential cho platform-infra
  kubectl apply -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: github-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
stringData:
  type: git
  url: https://github.com/$GITHUB_USER
  username: $GITHUB_USER
  password: $GITHUB_PAT
EOF

  # Repository spec cho platform-infra
  kubectl apply -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: platform-infra-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/$GITHUB_USER/$GITHUB_REPO_INFRA
  username: $GITHUB_USER
  password: $GITHUB_PAT
EOF

  log_info "GitHub credentials registered with ArgoCD"
fi

# --- 3g. Deploy root app ---
log_info "Deploying root Application (App-of-Apps)..."
if [[ "$DRY_RUN" != "true" ]]; then
  kubectl apply -f - << EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/$GITHUB_USER/$GITHUB_REPO_INFRA
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
  log_info "Root app deployed. ArgoCD will now sync from GitHub."
else
  apply kubectl apply -f "$REPO_ROOT/apps/root-app.yaml"
fi

# =============================================================================
log_step 4 "Spark Operator CRDs (quá lớn cho ArgoCD apply, cài 1 lần ở đây)"
# =============================================================================

log_info "Installing Spark Operator CRDs..."
if [[ "$DRY_RUN" != "true" ]]; then
  helm repo add spark-operator https://kubeflow.github.io/spark-operator 2>/dev/null || true
  helm repo update spark-operator 2>/dev/null || true
  helm template spark-operator spark-operator/spark-operator \
    --version 2.1.0 --include-crds 2>/dev/null | \
    python3 -c "
import sys
docs = sys.stdin.read().split('---')
for doc in docs:
    if 'kind: CustomResourceDefinition' in doc:
        print('---')
        print(doc.strip())
" | kubectl apply --server-side -f - 2>&1 || log_warn "Some CRDs may have failed, continuing..."
  log_info "Spark CRDs installed"
fi

# =============================================================================
log_step 5 "ArgoCD Apps Sync — đợi platform-infra apps deploy xong"
# =============================================================================

log_info "Waiting for ArgoCD to sync all Applications..."
if [[ "$DRY_RUN" != "true" ]]; then
  for i in $(seq 1 60); do
    READY_COUNT=$(kubectl get applications -n argocd \
      -o jsonpath='{.items[?(@.status.health.status=="Healthy")].metadata.name}' \
      2>/dev/null | wc -w)
    TOTAL_COUNT=$(kubectl get applications -n argocd --no-headers 2>/dev/null | wc -l || echo 0)
    log_info "  ArgoCD sync: $READY_COUNT/$TOTAL_COUNT apps healthy (attempt $i/60)..."
    [[ "$READY_COUNT" -ge 1 ]] && break
    sleep 10
  done
fi

# =============================================================================
log_step 6 "Airflow DB Migration (ArgoCD không chạy Helm hooks)"
# =============================================================================

if [[ "$DRY_RUN" != "true" ]]; then
  log_info "Waiting for ArgoCD to deploy Airflow PostgreSQL..."
  for i in $(seq 1 60); do
    PG_READY=$(kubectl get pod airflow-postgresql-0 -n platform-data \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    if [[ "$PG_READY" == "True" ]]; then
      log_info "Airflow PostgreSQL is ready"
      break
    fi
    if [[ $i -eq 60 ]]; then
      log_warn "Airflow PostgreSQL not ready after 5 min, skipping DB migration"
      PG_READY="Timeout"
    fi
    sleep 5
  done

  if [[ "$PG_READY" == "True" ]]; then
    log_info "Running Airflow DB migration..."
    kubectl exec -n platform-data airflow-postgresql-0 -- \
      bash -c 'PGPASSWORD=postgres psql -U postgres -c "CREATE DATABASE airflow;" 2>/dev/null || true'

    DB_CONN=$(kubectl get secret airflow-metadata -n platform-data \
      -o jsonpath='{.data.connection}' 2>/dev/null | base64 -d || echo "")
    if [[ -z "$DB_CONN" ]]; then
      DB_CONN="postgresql+psycopg2://postgres:postgres@airflow-postgresql:5432/postgres"
    fi
    DB_CONN="${DB_CONN/postgresql:\/\//postgresql+psycopg2://}"
    DB_CONN="${DB_CONN%%\?*}"

    log_info "DB connection: ${DB_CONN%%@*}@***"

    kubectl delete pod airflow-db-init -n platform-data 2>/dev/null || true
    kubectl run airflow-db-init -n platform-data \
      --image=apache/airflow:2.8.1 \
      --restart=Never \
      --env="AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=${DB_CONN}" \
      -- airflow db migrate

    for i in $(seq 1 60); do
      POD_STATUS=$(kubectl get pod airflow-db-init -n platform-data \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
      if [[ "$POD_STATUS" == "Succeeded" ]]; then
        log_info "Airflow DB migration completed successfully"
        break
      elif [[ "$POD_STATUS" == "Failed" ]]; then
        log_warn "Airflow DB migration failed, check: kubectl logs airflow-db-init -n platform-data"
        break
      fi
      sleep 5
    done
    kubectl delete pod airflow-db-init -n platform-data 2>/dev/null || true

    log_info "Creating Airflow admin user..."
    kubectl delete pod airflow-create-user -n platform-data 2>/dev/null || true
    kubectl run airflow-create-user -n platform-data \
      --image=apache/airflow:2.8.1 \
      --restart=Never \
      --env="AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=${DB_CONN}" \
      -- airflow users create \
        --username admin --password admin \
        --firstname Admin --lastname User \
        --role Admin --email admin@example.com
    for i in $(seq 1 30); do
      POD_STATUS=$(kubectl get pod airflow-create-user -n platform-data \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
      [[ "$POD_STATUS" == "Succeeded" || "$POD_STATUS" == "Failed" ]] && break
      sleep 3
    done
    kubectl delete pod airflow-create-user -n platform-data 2>/dev/null || true
    log_info "Airflow admin user created (admin/admin)"

    log_info "Restarting Airflow pods..."
    kubectl delete pod -l component=webserver -n platform-data 2>/dev/null || true
    kubectl delete pod -l component=scheduler -n platform-data 2>/dev/null || true
    sleep 5
  fi
fi

log_warn "Active services: Airflow, Spark Operator, Iceberg REST + PostgreSQL, MinIO"
log_warn "Disabled services: Trino, Kafka, OpenMetadata, Flink, Rook-Ceph"

# =============================================================================
# SUMMARY
# =============================================================================
END_TIME=$(date)
echo ""
echo "================================================================"
echo -e "${GREEN}  BOOTSTRAP COMPLETE${NC}"
echo "================================================================"
echo ""
echo "  Started:  $START_TIME"
echo "  Ended:    $END_TIME"
echo "  Node IP:  $NODE_IP"
echo ""
echo "  Phase 1 — Storage:"
echo "    StorageClass:  local-path (default)"
echo "    MinIO S3:      ClusterIP only (minio.platform-storage:9000)"
echo "    MinIO Console: NodePort 30901  (minioadmin / MinIO@Admin2024!)"
echo ""
echo "  Phase 2 — ArgoCD:"
echo "    NodePort:      30443 (HTTPS)"
echo "    Admin:         admin / $ARGOCD_PASS"
echo "    GitOps:        https://github.com/$GITHUB_USER/$GITHUB_REPO_INFRA"
echo ""
echo "  Services deployed by ArgoCD (GitHub):"
echo "    [ACTIVE]   Airflow, Spark Operator, Iceberg REST + PostgreSQL, MinIO"
echo "    [DISABLED] Trino, Kafka, OpenMetadata, Flink, Rook-Ceph"
echo ""
echo "  NodePort mapping (access via $NODE_IP):"
echo "    30080 → Airflow WebUI"
echo "    30443 → ArgoCD"
echo "    30901 → MinIO Console"
echo ""
echo "  Next steps:"
echo "    1. Verify ArgoCD sync:  kubectl get applications -n argocd"
echo "    2. Check health:        bash scripts/health-check.sh --verbose"
echo "    3. Onboard teams:       bash scripts/onboard-team.sh <team-name>"
echo "    4. Change default passwords!"
echo ""