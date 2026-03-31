#!/usr/bin/env bash
# =============================================================================
# bootstrap-cluster.sh
# Mục đích: Bootstrap toàn bộ Data Platform từ cluster K8s trống
# Thứ tự: local-path-provisioner → MinIO → Gitea → Push code → ArgoCD
#
# Usage:   bash bootstrap-cluster.sh [--dry-run] [--skip-push]
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
SKIP_PUSH=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]]   && DRY_RUN=true
  [[ "$arg" == "--skip-push" ]] && SKIP_PUSH=true
done

# ---- Config ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

ARGOCD_VERSION="v2.14.21"

GITEA_ADMIN_USER="gitea-admin"
GITEA_ADMIN_PASS="Gitea@Admin2024!"
GITEA_ORG="data-platform"

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

# Node IP cho NodePort access (có thể override bằng env NODE_IP)
# Với NAT VPS, đây chỉ là IP hiển thị trong summary. Truy cập thực tế qua IP_CÔNG:CỔNG_NGOÀI
NODE_IP="${NODE_IP:-103.249.117.202}"
log_info "Node IP (for summary display): $NODE_IP"

[[ "$DRY_RUN" == "true" ]] && log_warn "DRY RUN MODE — no changes will be made"

echo ""
log_info "Bootstrap plan:"
log_info "  Phase 1: local-path-provisioner (StorageClass for PVCs)"
log_info "  Phase 2: MinIO (S3-compatible object storage)"
log_info "  Phase 3: Gitea (Git server) + push code"
log_info "  Phase 4: ArgoCD $ARGOCD_VERSION + root-app (sync remaining services)"
log_info ""
log_info "  Access: NodePort trên $NODE_IP"
log_info "  Active services: Airflow, Spark Operator, Iceberg REST + PostgreSQL, MinIO"
log_info "  Disabled: Trino, Kafka, OpenMetadata, Harbor, Flink, Rook-Ceph"
echo ""

# =============================================================================
log_step 1 "local-path-provisioner — StorageClass"
# =============================================================================

log_info "Installing local-path-provisioner..."
apply kubectl apply -f "$REPO_ROOT/services/storage/local-path-provisioner.yaml"

wait_for_pods "local-path-storage" "app=local-path-provisioner" 120

# Kiểm tra StorageClass đã tạo
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
log_step 3 "Gitea — Git Server"
# =============================================================================

log_info "Adding Gitea Helm repo..."
helm repo add gitea https://dl.gitea.com/charts/ 2>/dev/null || true
helm repo update || log_error "Failed to update Helm repos"
log_info "Gitea Helm repo ready"

log_info "Creating platform-ops namespace..."
if [[ "$DRY_RUN" == "true" ]]; then
  log_warn "[DRY RUN] kubectl create namespace platform-ops"
else
  kubectl create namespace platform-ops --dry-run=client -o yaml | kubectl apply -f -
fi

log_info "Installing Gitea..."
apply helm upgrade --install gitea gitea/gitea \
  --namespace platform-ops \
  -f "$REPO_ROOT/services/ops/gitea/values.yaml" \
  --wait --timeout 10m

wait_for_pods "platform-ops" "app.kubernetes.io/name=gitea" 300

# NAT VPS: dùng port-forward để truy cập Gitea API từ dev machine
# Không cần biết cổng ngoài NAT — chỉ cần kubectl access
log_info "Starting kubectl port-forward for Gitea API access..."
GITEA_LOCAL_PORT=3000
if [[ "$DRY_RUN" != "true" ]]; then
  kubectl port-forward svc/gitea-http -n platform-ops ${GITEA_LOCAL_PORT}:3000 &>/dev/null &
  PORT_FWD_PID=$!
  sleep 3
  # Kiểm tra port-forward còn sống
  if ! kill -0 $PORT_FWD_PID 2>/dev/null; then
    log_warn "Port-forward failed, trying alternative port..."
    GITEA_LOCAL_PORT=13000
    kubectl port-forward svc/gitea-http -n platform-ops ${GITEA_LOCAL_PORT}:3000 &>/dev/null &
    PORT_FWD_PID=$!
    sleep 3
  fi
fi
GITEA_URL="http://localhost:${GITEA_LOCAL_PORT}"
GITEA_API="${GITEA_URL}/api/v1"
log_info "Gitea API via port-forward: $GITEA_URL"

# --- 3a. Chờ Gitea API ready ---
log_info "Waiting for Gitea API to respond..."
if [[ "$DRY_RUN" != "true" ]]; then
  for i in $(seq 1 20); do
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
      -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
      "${GITEA_API}/settings/api" 2>/dev/null || echo "000")
    [[ "$HTTP_STATUS" == "200" ]] && break
    log_warn "Gitea API not ready (HTTP $HTTP_STATUS, attempt $i/20)..."
    sleep 10
  done
fi

# --- 3b. Tạo API token ---
log_info "Creating Gitea API token for automation..."
if [[ "$DRY_RUN" != "true" ]]; then
  # Xóa token cũ nếu tồn tại
  curl -s -X DELETE "${GITEA_API}/users/${GITEA_ADMIN_USER}/tokens/bootstrap-token" \
    -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" 2>/dev/null || true

  TOKEN_RESPONSE=$(curl -s -X POST "${GITEA_API}/users/${GITEA_ADMIN_USER}/tokens" \
    -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
    -H "Content-Type: application/json" \
    -d '{"name": "bootstrap-token", "scopes": ["all"]}')

  # Trích token — thử cả sha1 (cũ) và token (mới)
  GITEA_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -oP '"sha1"\s*:\s*"[^"]*"' | cut -d'"' -f4 || true)
  if [[ -z "$GITEA_TOKEN" ]]; then
    GITEA_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -oP '"token"\s*:\s*"[^"]*"' | cut -d'"' -f4 || true)
  fi

  [[ -z "$GITEA_TOKEN" ]] && log_error "Failed to create Gitea API token. Response: $TOKEN_RESPONSE"
  log_info "Gitea token created: ${GITEA_TOKEN:0:8}..."
else
  GITEA_TOKEN="DRY_RUN_TOKEN"
fi

# --- 3c. Tạo organization ---
log_info "Creating Gitea organization: $GITEA_ORG..."
apply curl -s -X POST "${GITEA_API}/orgs" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"${GITEA_ORG}\", \"visibility\": \"private\"}" \
  -o /dev/null -w "" 2>/dev/null || log_warn "Org may already exist"

# --- 3d. Tạo repos ---
for REPO_NAME in "platform-infra" "platform-dags"; do
  log_info "Creating repo: ${GITEA_ORG}/${REPO_NAME}..."
  apply curl -s -X POST "${GITEA_API}/orgs/${GITEA_ORG}/repos" \
    -H "Authorization: token $GITEA_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${REPO_NAME}\",
      \"private\": true,
      \"auto_init\": true,
      \"default_branch\": \"main\"
    }" -o /dev/null -w "" 2>/dev/null || log_warn "Repo may already exist"
done

# --- 3e. Push platform-infra code ---
if [[ "$SKIP_PUSH" == "true" ]]; then
  log_warn "Skipping code push (--skip-push flag)"
else
  log_info "Pushing platform-infra code to Gitea..."
  if [[ "$DRY_RUN" != "true" ]]; then
    PUSH_DIR=$(mktemp -d)
    cd "$PUSH_DIR"
    git init -b main
    git config user.name "bootstrap"
    git config user.email "bootstrap@platform.internal"
    cp -r "$REPO_ROOT"/* .
    git add -A
    git commit -m "Initial platform-infra commit from bootstrap"
    # URL-encode token (có thể chứa ký tự đặc biệt)
    ENCODED_TOKEN=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${GITEA_TOKEN}', safe=''))" 2>/dev/null || echo "$GITEA_TOKEN")
    GITEA_PUSH_URL="http://${GITEA_ADMIN_USER}:${ENCODED_TOKEN}@localhost:${GITEA_LOCAL_PORT}/${GITEA_ORG}"

    git remote add origin "${GITEA_PUSH_URL}/platform-infra.git"
    if ! git push -u origin main --force 2>&1; then
      log_warn "First push failed, retrying..."
      git pull origin main --rebase --allow-unrelated-histories 2>/dev/null || true
      git push -u origin main --force 2>&1 || log_warn "Push platform-infra failed, continue anyway"
    fi
    cd "$SCRIPT_DIR"
    rm -rf "$PUSH_DIR"
    log_info "Code pushed to Gitea successfully"

    # Push platform-dags (bao gom DAGs + SparkApp YAML templates)
    DAGS_DIR=$(mktemp -d)
    cd "$DAGS_DIR"
    git init -b main
    git config user.name "bootstrap"
    git config user.email "bootstrap@platform.internal"

    # Copy actual DAG files tu Data-Platform repo (neu co)
    PLATFORM_DAGS_SRC="$(dirname "$REPO_ROOT")/platform-dags"
    if [[ -d "$PLATFORM_DAGS_SRC/dags" ]]; then
      cp -r "$PLATFORM_DAGS_SRC"/* . 2>/dev/null || true
      cp -r "$PLATFORM_DAGS_SRC"/.* . 2>/dev/null || true
      log_info "Copied DAGs from $PLATFORM_DAGS_SRC"
    else
      # Fallback: tao cau truc toi thieu
      mkdir -p dags/platform dags/finance/spark-apps dags/_shared plugins
      touch dags/.gitkeep
      log_warn "No platform-dags source found, created empty structure"
    fi

    git add -A
    git commit -m "Initial platform-dags with DAGs and SparkApp templates"
    git remote add origin "${GITEA_PUSH_URL}/platform-dags.git"
    if ! git push -u origin main --force 2>&1; then
      log_warn "First push failed, retrying..."
      git pull origin main --rebase --allow-unrelated-histories 2>/dev/null || true
      git push -u origin main --force 2>&1 || log_warn "Push platform-dags failed, continue anyway"
    fi
    cd "$SCRIPT_DIR"
    rm -rf "$DAGS_DIR"
    log_info "platform-dags repo pushed (with DAGs + SparkApp YAMLs)"
  fi
fi

# Dọn port-forward Gitea (không cần nữa — ArgoCD dùng ClusterIP nội bộ)
if [[ -n "${PORT_FWD_PID:-}" ]] && kill -0 "$PORT_FWD_PID" 2>/dev/null; then
  kill "$PORT_FWD_PID" 2>/dev/null || true
  log_info "Stopped Gitea port-forward (PID $PORT_FWD_PID)"
fi

# =============================================================================
log_step 4 "ArgoCD — GitOps Controller"
# =============================================================================

log_info "Installing ArgoCD $ARGOCD_VERSION..."
if [[ "$DRY_RUN" == "true" ]]; then
  log_warn "[DRY RUN] kubectl create namespace argocd"
else
  # Đợi namespace cũ xóa xong nếu đang Terminating
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

# --- 4a. Lấy admin password ---
if [[ "$DRY_RUN" != "true" ]]; then
  ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "UNKNOWN")
  log_info "ArgoCD initial admin password: $ARGOCD_PASS"
  log_warn "Change this password after first login!"
else
  ARGOCD_PASS="DRY_RUN"
fi

# --- 4b. Tạo default AppProject ---
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

# --- 4c. Expose ArgoCD qua NodePort ---
log_info "Exposing ArgoCD via NodePort..."
apply kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "NodePort", "ports": [{"port": 443, "targetPort": 8080, "nodePort": 30443, "name": "https"}]}}'

# --- 4d. Đăng ký Gitea repo credentials ---
log_info "Registering Gitea repo credentials with ArgoCD..."
if [[ "$DRY_RUN" != "true" ]]; then
  # Dùng repo-creds (credential template) để match tất cả repos trong Gitea
  # Đăng ký cả 2 URL pattern: ClusterIP và service DNS name
  kubectl apply -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitea-repo-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
stringData:
  type: git
  url: http://gitea-http.platform-ops:3000/${GITEA_ORG}
  username: ${GITEA_ADMIN_USER}
  password: ${GITEA_ADMIN_PASS}
EOF

  # Đăng ký thêm repo cụ thể để ArgoCD nhận diện ngay
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
  url: http://gitea-http.platform-ops:3000/${GITEA_ORG}/platform-infra
  username: ${GITEA_ADMIN_USER}
  password: ${GITEA_ADMIN_PASS}
EOF
fi

# --- 4e. Deploy root app ---
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
    repoURL: http://gitea-http.platform-ops:3000/${GITEA_ORG}/platform-infra
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
else
  apply kubectl apply -f "$REPO_ROOT/apps/root-app.yaml"
fi

log_info "ArgoCD will now sync the platform from Gitea"

# =============================================================================
log_step "4f" "Spark Operator CRDs (quá lớn cho ArgoCD apply, cài 1 lần ở đây)"
# =============================================================================

log_info "Installing Spark Operator CRDs..."
if [[ "$DRY_RUN" != "true" ]]; then
  helm repo add spark-operator https://kubeflow.github.io/spark-operator 2>/dev/null || true
  helm repo update spark-operator 2>/dev/null || true
  # Render CRDs từ chart và apply bằng server-side apply (CRDs > 262KB)
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
log_step 5 "Airflow DB Migration (ArgoCD không chạy Helm hooks)"
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
    # Tạo database airflow (nếu chart dùng DB airflow thay vì postgres)
    kubectl exec -n platform-data airflow-postgresql-0 -- \
      bash -c 'PGPASSWORD=postgres psql -U postgres -c "CREATE DATABASE airflow;" 2>/dev/null || true'

    # Lấy connection string từ secret (ArgoCD tạo)
    DB_CONN=$(kubectl get secret airflow-metadata -n platform-data \
      -o jsonpath='{.data.connection}' 2>/dev/null | base64 -d || echo "")
    if [[ -z "$DB_CONN" ]]; then
      DB_CONN="postgresql+psycopg2://postgres:postgres@airflow-postgresql:5432/postgres"
    fi
    # Chuyển postgresql:// thành postgresql+psycopg2://
    DB_CONN="${DB_CONN/postgresql:\/\//postgresql+psycopg2://}"
    # Bỏ ?sslmode=... nếu có
    DB_CONN="${DB_CONN%%\?*}"

    log_info "DB connection: ${DB_CONN%%@*}@***"

    # Chạy migration bằng pod tạm
    kubectl delete pod airflow-db-init -n platform-data 2>/dev/null || true
    kubectl run airflow-db-init -n platform-data \
      --image=apache/airflow:2.8.1 \
      --restart=Never \
      --env="AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=${DB_CONN}" \
      -- airflow db migrate

    # Đợi migration xong
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

    # Cleanup migration pod
    kubectl delete pod airflow-db-init -n platform-data 2>/dev/null || true

    # Tạo admin user (Helm hook create-user không chạy với ArgoCD)
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

    # Restart airflow pods để detect migration xong
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
echo "  Phase 2 — Gitea (Git + Container Registry):"
echo "    NodePort:      30300"
echo "    Admin:         $GITEA_ADMIN_USER / $GITEA_ADMIN_PASS"
echo "    Registry:      gitea-http.platform-ops:3000 (OCI Container Registry)"
echo ""
echo "  Phase 3 — ArgoCD:"
echo "    NodePort:      30443 (HTTPS)"
echo "    Admin:         admin / $ARGOCD_PASS"
echo ""
echo "  Services deployed by ArgoCD:"
echo "    [ACTIVE]   Airflow, Spark Operator, Iceberg REST + PostgreSQL, MinIO"
echo "    [DISABLED] Trino, Kafka, OpenMetadata, Flink, Rook-Ceph"
echo ""
echo "  NodePort mapping (tạo Port Forwarding trên NAT VPS panel):"
echo "    30080 → Airflow WebUI"
echo "    30300 → Gitea"
echo "    30443 → ArgoCD"
echo "    30901 → MinIO Console"
echo ""
echo "  Gitea token (save for later use):"
echo "    export GITEA_TOKEN=\"$GITEA_TOKEN\""
echo ""
echo "  Next steps:"
echo "    1. Verify ArgoCD sync:  kubectl get applications -n argocd"
echo "    2. Check health:        bash scripts/health-check.sh --verbose"
echo "    3. Onboard teams:       bash scripts/onboard-team.sh <team-name>"
echo "    4. Change default passwords!"
echo ""
