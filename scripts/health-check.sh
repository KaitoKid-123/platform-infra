#!/usr/bin/env bash
# =============================================================================
# health-check.sh
# Mục đích: Kiểm tra sức khỏe toàn bộ platform
# Usage:   bash health-check.sh [--verbose] [--json]
# Output:  Table + optional JSON report
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

VERBOSE=false
JSON_OUTPUT=false
for arg in "$@"; do
  [[ "$arg" == "--verbose" ]] && VERBOSE=true
  [[ "$arg" == "--json" ]] && JSON_OUTPUT=true
done

pass() { echo -e "${GREEN}PASS${NC}"; }
warn() { echo -e "${YELLOW}WARN${NC}"; }
fail() { echo -e "${RED}FAIL${NC}"; }

CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0
REPORT=()

check() {
  local name="$1"
  local cmd="$2"
  local expected="${3:-}"

  printf "%-50s " "$name"

  OUTPUT=$(eval "$cmd" 2>&1 || echo "CMD_FAILED")

  if [[ "$OUTPUT" == "CMD_FAILED" ]] || [[ -z "$OUTPUT" ]]; then
    fail
    ((CHECKS_FAILED++))
    if command -v jq &>/dev/null; then
      REPORT+=("$(jq -n --arg name "$name" --arg status "FAIL" --arg output "$OUTPUT" \
        '{name: $name, status: $status, output: $output}')")
    fi
  elif [[ -n "$expected" ]] && [[ "$OUTPUT" != *"$expected"* ]]; then
    warn
    ((CHECKS_WARNED++))
    if command -v jq &>/dev/null; then
      REPORT+=("$(jq -n --arg name "$name" --arg status "WARN" --arg output "$OUTPUT" \
        '{name: $name, status: $status, output: $output}')")
    fi
    [[ "$VERBOSE" == "true" ]] && echo "  Expected: $expected, Got: $OUTPUT"
  else
    pass
    ((CHECKS_PASSED++))
    if command -v jq &>/dev/null; then
      REPORT+=("$(jq -n --arg name "$name" --arg status "PASS" --arg output "$OUTPUT" \
        '{name: $name, status: $status, output: $output}')")
    fi
    [[ "$VERBOSE" == "true" ]] && echo "  Output: $OUTPUT"
  fi
}

echo ""
echo -e "${BOLD}Data Platform Health Check — $(date)${NC}"
echo "================================================================"

# Node IP cho NodePort checks — ưu tiên env, fallback public IP
NODE_IP="${NODE_IP:-103.249.117.202}"

# ---- K8s Cluster ----
echo -e "\n${BOLD}K8s Cluster${NC}"
check "API server reachable" \
  "kubectl cluster-info 2>&1 | grep 'is running'" \
  "is running"
check "All nodes Ready" \
  "kubectl get nodes --no-headers | awk '{print \$2}' | sort -u" \
  "Ready"
check "StorageClass local-path exists" \
  "kubectl get storageclass local-path --no-headers 2>/dev/null | awk '{print \$1}'" \
  "local-path"

# ---- Storage (MinIO) ----
echo -e "\n${BOLD}Storage Layer (MinIO)${NC}"
check "MinIO pod running" \
  "kubectl get pods -n platform-storage -l app=minio --no-headers | grep -c Running"
check "MinIO S3 health" \
  "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 http://${NODE_IP}:30900/minio/health/ready 2>/dev/null" \
  "200"
check "MinIO Console reachable" \
  "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 http://${NODE_IP}:30901 2>/dev/null" \
  "200"

# ---- Platform Ops ----
echo -e "\n${BOLD}Platform Ops${NC}"
check "Gitea pod running" \
  "kubectl get pods -n platform-ops -l 'app.kubernetes.io/name=gitea' --no-headers | grep -c Running"
check "Gitea web reachable" \
  "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 http://${NODE_IP}:30300 2>/dev/null" \
  "200"
check "ArgoCD server running" \
  "kubectl get pods -n argocd -l 'app.kubernetes.io/name=argocd-server' --no-headers 2>/dev/null | grep -c Running"

# ---- Compute ----
echo -e "\n${BOLD}Compute Layer${NC}"
check "Spark Operator running" \
  "kubectl get pods -n platform-compute -l app.kubernetes.io/name=spark-operator --no-headers 2>/dev/null | grep -c Running"

# ---- Data Layer ----
echo -e "\n${BOLD}Data Layer${NC}"
check "Airflow webserver running" \
  "kubectl get pods -n platform-data -l component=webserver --no-headers 2>/dev/null | grep -c Running"
check "Airflow scheduler running" \
  "kubectl get pods -n platform-data -l component=scheduler --no-headers 2>/dev/null | grep -c Running"

# ---- PVC Status ----
echo -e "\n${BOLD}PVC Status${NC}"
check "All PVCs Bound" \
  "kubectl get pvc -A --no-headers 2>/dev/null | awk '{print \$3}' | sort -u" \
  "Bound"

# ---- Summary ----
echo ""
echo "================================================================"
echo -e "${BOLD}Summary${NC}"
echo -e "  ${GREEN}Passed: $CHECKS_PASSED${NC}  |  ${YELLOW}Warned: $CHECKS_WARNED${NC}  |  ${RED}Failed: $CHECKS_FAILED${NC}"
echo ""
echo "  NodePort endpoints (access via $NODE_IP):"
echo "    :30300 Gitea  |  :30443 ArgoCD  |  :30808 Airflow"
echo "    :30900 MinIO S3  |  :30901 MinIO Console"

# JSON output
if [[ "$JSON_OUTPUT" == "true" ]] && command -v jq &>/dev/null; then
  echo ""
  echo -e "${BOLD}JSON Report:${NC}"
  printf '%s\n' "${REPORT[@]}" | jq -s '.'
fi

if [[ "$CHECKS_FAILED" -gt 0 ]]; then
  echo -e "\n${RED}Platform has $CHECKS_FAILED critical issues!${NC}"
  exit 1
elif [[ "$CHECKS_WARNED" -gt 0 ]]; then
  echo -e "\n${YELLOW}Platform has warnings, review above.${NC}"
  exit 0
else
  echo -e "\n${GREEN}Platform is healthy!${NC}"
  exit 0
fi
