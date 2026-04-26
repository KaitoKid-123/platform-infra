#!/usr/bin/env bash
# =============================================================================
# teardown-cluster.sh
# Mục đích: Xóa toàn bộ Data Platform khỏi cluster (ngược lại bootstrap)
# Thứ tự: ArgoCD → Data/Compute → Storage → local-path-provisioner
#
# Usage:   bash teardown-cluster.sh [--yes]
# Flag:    --yes   Bỏ qua xác nhận (dùng cho CI)
# =============================================================================

# Không dùng set -e vì nhiều lệnh xóa sẽ fail khi resource không tồn tại
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ARGOCD_VERSION="v2.14.21"

# ---- Colors & logging ----
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO  $(date '+%H:%M:%S')]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN  $(date '+%H:%M:%S')]${NC} $1"; }
log_step()  { echo -e "\n${CYAN}══════════════════════════════════════════════════${NC}"; \
              echo -e "${CYAN}  $1${NC}"; \
              echo -e "${CYAN}══════════════════════════════════════════════════${NC}"; }

wait_ns_deleted() {
  local ns=$1
  local timeout=${2:-120}
  if kubectl get namespace "$ns" &>/dev/null; then
    log_info "Đợi namespace $ns xóa xong (timeout ${timeout}s)..."
    kubectl wait --for=delete namespace/"$ns" --timeout="${timeout}s" 2>/dev/null || {
      log_warn "Namespace $ns stuck Terminating, xóa finalizers..."
      kubectl get namespace "$ns" -o json | \
        python3 -c "import sys,json;ns=json.load(sys.stdin);ns['spec']['finalizers']=[];json.dump(ns,sys.stdout)" | \
        kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
      sleep 3
    }
  fi
}

# ---- Parse args ----
AUTO_YES=false
for arg in "$@"; do
  [[ "$arg" == "--yes" ]] && AUTO_YES=true
done

# ---- Xác nhận ----
if [[ "$AUTO_YES" != "true" ]]; then
  echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║  WARNING: Xóa TOÀN BỘ Data Platform khỏi cluster!  ║${NC}"
  echo -e "${RED}║  Dữ liệu PVC sẽ bị mất không thể khôi phục.       ║${NC}"
  echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  read -rp "Nhập 'DELETE' để xác nhận: " confirm
  if [[ "$confirm" != "DELETE" ]]; then
    echo "Hủy bỏ."
    exit 0
  fi
fi

log_info "Bắt đầu teardown..."

# ══════════════════════════════════════════════════
log_step "Phase 1: Xóa ArgoCD Applications & ArgoCD"
# ══════════════════════════════════════════════════

if kubectl get namespace argocd &>/dev/null; then
  # Xóa finalizers trên tất cả Applications trước (tránh stuck Terminating)
  log_info "Xóa finalizers trên ArgoCD Applications..."
  for app in $(kubectl get applications.argoproj.io -n argocd -o name 2>/dev/null); do
    kubectl patch "$app" -n argocd --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  done

  log_info "Xóa ArgoCD Applications..."
  kubectl delete application platform-streaming -n argocd --timeout=30s 2>/dev/null || true
  kubectl delete applications.argoproj.io --all -n argocd --timeout=30s 2>/dev/null || true

  log_info "Xóa ArgoCD..."
  kubectl delete -n argocd \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml" 2>/dev/null || true

  # Xóa ClusterRole/ClusterRoleBinding của ArgoCD
  log_info "Xóa ArgoCD ClusterRoles..."
  kubectl delete clusterrole -l app.kubernetes.io/part-of=argocd 2>/dev/null || true
  kubectl delete clusterrolebinding -l app.kubernetes.io/part-of=argocd 2>/dev/null || true

  log_info "Xóa namespace argocd..."
  kubectl delete namespace argocd --timeout=30s 2>/dev/null || true
  wait_ns_deleted "argocd" 60
else
  log_warn "Namespace argocd không tồn tại, bỏ qua"
fi

# ══════════════════════════════════════════════════
log_step "Phase 2: Xóa Streaming, Data & Compute services"
# ══════════════════════════════════════════════════

for ns in platform-streaming platform-data platform-compute; do
  if kubectl get namespace "$ns" &>/dev/null; then
    log_info "Xóa tất cả resources trong $ns..."
    kubectl delete all --all -n "$ns" --timeout=60s 2>/dev/null || true
    kubectl delete pvc --all -n "$ns" --timeout=60s 2>/dev/null || true
    kubectl delete secret --all -n "$ns" 2>/dev/null || true
    kubectl delete configmap --all -n "$ns" 2>/dev/null || true
    kubectl delete rolebinding --all -n "$ns" 2>/dev/null || true
    kubectl delete role --all -n "$ns" 2>/dev/null || true
    if [[ "$ns" == "platform-streaming" ]]; then
      log_info "Xóa riêng Redpanda StatefulSet/Service/PDB/SA/PVC cũ trong $ns..."
      kubectl delete statefulset redpanda -n "$ns" --timeout=60s 2>/dev/null || true
      kubectl delete service redpanda -n "$ns" 2>/dev/null || true
      kubectl delete poddisruptionbudget redpanda -n "$ns" 2>/dev/null || true
      kubectl delete serviceaccount redpanda -n "$ns" 2>/dev/null || true
      kubectl delete secret redpanda-configurator -n "$ns" 2>/dev/null || true
      kubectl delete secret redpanda-sts-lifecycle -n "$ns" 2>/dev/null || true
      kubectl delete configmap redpanda -n "$ns" 2>/dev/null || true
      kubectl delete pvc datadir-redpanda-0 -n "$ns" 2>/dev/null || true
      kubectl delete pvc redpanda-data -n "$ns" 2>/dev/null || true
    fi
  else
    log_warn "Namespace $ns không tồn tại, bỏ qua"
  fi
done

# ══════════════════════════════════════════════════
log_step "Phase 3: Xóa MinIO"
# ══════════════════════════════════════════════════

if kubectl get namespace platform-storage &>/dev/null; then
  log_info "Xóa MinIO resources..."
  kubectl delete -f "$REPO_ROOT/services/storage/minio.yaml" 2>/dev/null || true
  kubectl delete pvc --all -n platform-storage --timeout=60s 2>/dev/null || true
else
  log_warn "Namespace platform-storage không tồn tại, bỏ qua"
fi

# ══════════════════════════════════════════════════
log_step "Phase 4: Xóa local-path-provisioner"
# ══════════════════════════════════════════════════

log_info "Xóa PersistentVolumes..."
kubectl delete pv --all --timeout=60s 2>/dev/null || true

if kubectl get namespace local-path-storage &>/dev/null; then
  log_info "Xóa local-path-provisioner..."
  kubectl delete -f "$REPO_ROOT/services/storage/local-path-provisioner.yaml" 2>/dev/null || true
else
  log_warn "Namespace local-path-storage không tồn tại, bỏ qua"
fi

# ══════════════════════════════════════════════════
log_step "Phase 5: Xóa namespaces"
# ══════════════════════════════════════════════════

for ns in platform-streaming platform-ops platform-data platform-compute platform-storage monitoring team-finance local-path-storage; do
  if kubectl get namespace "$ns" &>/dev/null; then
    log_info "Xóa namespace $ns..."
    kubectl delete namespace "$ns" --timeout=60s 2>/dev/null || true
  fi
done

# Đợi tất cả namespaces xóa xong
for ns in argocd platform-streaming platform-ops platform-data platform-compute platform-storage monitoring team-finance local-path-storage; do
  wait_ns_deleted "$ns" 60
done

# ══════════════════════════════════════════════════
log_step "Phase 6: Cleanup Helm repos"
# ══════════════════════════════════════════════════

for repo in spark-operator spark-operator-charts; do
  if helm repo list 2>/dev/null | grep -q "^$repo"; then
    log_info "Xóa Helm repo $repo..."
    helm repo remove "$repo" 2>/dev/null || true
  fi
done

# ---- Done ----
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  TEARDOWN HOÀN TẤT${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
log_info "Cluster đã được dọn sạch."
log_info "Để deploy lại, chạy: bash bootstrap-cluster.sh"
