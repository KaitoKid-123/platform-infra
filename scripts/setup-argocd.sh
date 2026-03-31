#!/usr/bin/env bash
# =============================================================================
# setup-argocd.sh
# Khởi tạo ArgoCD lần đầu trên K8s cluster mới
# Chạy 1 lần duy nhất trước khi bootstrap platform
#
# LƯU Ý: Script này CHỈ cài ArgoCD + kết nối Gitea + deploy root app.
#         Yêu cầu MetalLB, Rook-Ceph, Gitea đã cài sẵn.
#         Nếu cluster hoàn toàn mới, dùng bootstrap-cluster.sh thay thế.
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }

ARGOCD_VERSION="v2.9.0"
GITEA_URL="${GITEA_URL:-http://gitea.internal}"
GITEA_TOKEN="${GITEA_TOKEN:-}"

[[ -z "$GITEA_TOKEN" ]] && echo "ERROR: Set GITEA_TOKEN env variable" && exit 1

# 1. Install ArgoCD
log "Installing ArgoCD $ARGOCD_VERSION..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"

# 2. Wait for ArgoCD
log "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=300s

# 3. Get initial admin password
INITIAL_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
log "ArgoCD initial admin password: $INITIAL_PASS"
log "Change this password after first login!"

# 4. Expose ArgoCD server
kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "LoadBalancer"}}'

# 5. Wait for LoadBalancer IP
log "Waiting for ArgoCD LoadBalancer IP..."
sleep 15
ARGOCD_IP=$(kubectl get svc argocd-server -n argocd \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
log "ArgoCD available at: http://$ARGOCD_IP"

# 6. Register Gitea repo
log "Registering Gitea repo..."
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
  url: $GITEA_URL/data-platform/platform-infra
  username: argocd
  password: $GITEA_TOKEN
EOF

# 7. Deploy root app
log "Deploying root application..."
kubectl apply -f apps/root-app.yaml -n argocd

log "Bootstrap complete! ArgoCD will now sync the entire platform."
log "Monitor at: http://$ARGOCD_IP"