# Platform Infrastructure

Ha tang Data Platform chay tren **CFKE (CloudFleet Kubernetes Engine)** voi NAT VPS, trien khai theo mo hinh **GitOps** voi ArgoCD.

> **Cloud Provider**: CloudFleet — NAT VPS (moi VPS 2vCPU, 2GB RAM, 5 port forwarding).

## Kien truc tong quan

```
                         +--------------+
                         |   ArgoCD     |
                         |  v2.14.21    |
                         +------+-------+
                                | sync tu Gitea
                +---------------+---------------+
                v               v               v
         +-------------+ +----------+  +--------------+
         |   Compute   | |   Data   |  |   Storage    |
         |-------------| |----------|  |--------------|
         | Spark Op.   | | Airflow  |  | MinIO (S3)   |
         | (v2.1.0)    | | (2.8.1)  |  | Iceberg REST |
         +-------------+ +----------+  | PostgreSQL   |
                |               |      +--------------+
                +---------------+---------------+
                                v
                     +--------------------+
                     |  Team Namespaces   |
                     |  (finance, ...)    |
                     +--------------------+
```

## Trang thai hien tai

| Service | Status | Namespace | Quan ly boi |
|---------|--------|-----------|-------------|
| ArgoCD v2.14.21 | Active | argocd | Bootstrap script |
| Gitea | Active | platform-ops | Bootstrap script (Helm) |
| Airflow 2.8.1 (LocalExecutor) | Active | platform-data | ArgoCD (helmCharts) |
| Spark Operator v2.1.0 | Active | platform-compute | ArgoCD (helmCharts) |
| MinIO | Active | platform-storage | ArgoCD (plain YAML) |
| Iceberg REST + PostgreSQL | Active | platform-storage | ArgoCD (plain YAML) |
| local-path-provisioner | Active | local-path-storage | Bootstrap script |
| Monitoring (Prometheus/Grafana) | Disabled | - | Chua du resource |
| Trino, Kafka, Harbor, OpenMetadata | Disabled | - | Chua du resource |

## Cluster

- **3-4 nodes** (NAT VPS, 2vCPU / 2GB RAM moi node)
- **CNI**: Cilium (CFKE managed) — can xoa ArgoCD NetworkPolicies sau khi cai
- **Storage**: local-path-provisioner (chi ho tro RWO)
- **Ingress**: Khong co — truy cap qua NodePort + NAT Port Forwarding

## NodePort Mapping

Truy cap tu ben ngoai qua `IP_CHINH:CONG_NGOAI` (cau hinh tren NAT VPS panel).

| Service | NodePort (cong trong) | Ghi chu |
|---------|----------------------|---------|
| ArgoCD | 30443 | HTTPS |
| Gitea | 30300 | HTTP |
| Airflow | 30080 | HTTP |
| MinIO Console | 30901 | HTTP |

Cac service chi dung noi bo (ClusterIP):
- MinIO S3 API: `minio.platform-storage:9000`
- Iceberg REST: `iceberg-rest.platform-storage:8181`
- Iceberg PostgreSQL: `iceberg-postgres.platform-storage:5432`

## Cau truc thu muc

```
platform-infra/
+-- apps/                          # ArgoCD Applications (App-of-Apps)
|   +-- platform-compute-app.yaml  #   -> services/compute (Spark Operator)
|   +-- platform-data-app.yaml     #   -> services/data (Airflow)
|   +-- platform-storage-app.yaml  #   -> services/storage (MinIO, Iceberg)
|   +-- platform-ops-app.yaml      #   -> services/ops (Harbor - disabled)
|   +-- platform-monitoring-app.yaml #  -> monitoring/ (disabled)
|   +-- team-finance-infra-app.yaml  #  -> teams/finance
|
+-- services/
|   +-- compute/                   # Namespace: platform-compute
|   |   +-- spark-operator/        #   Spark Operator v2.1.0 (Helm via Kustomize)
|   |   +-- kustomization.yaml     #   helmCharts (includeCRDs: false)
|   |   +-- trino/, kafka/         #   Disabled
|   +-- data/                      # Namespace: platform-data
|   |   +-- airflow/               #   Airflow 2.8.1 (Helm via Kustomize)
|   |   +-- airflow-nodeport.yaml  #   NodePort 30080
|   |   +-- gitea-dags-secret.yaml #   Git-sync credentials
|   |   +-- kustomization.yaml
|   +-- storage/                   # Namespace: platform-storage
|   |   +-- minio.yaml             #   MinIO (emptyDir, Console NodePort 30901)
|   |   +-- iceberg-rest.yaml      #   Iceberg REST Catalog (ClusterIP)
|   |   +-- iceberg-postgres.yaml  #   PostgreSQL cho Iceberg metadata
|   |   +-- local-path-provisioner.yaml
|   |   +-- kustomization.yaml
|   +-- ops/                       # Namespace: platform-ops
|       +-- gitea/                 #   Gitea (Helm, cai trong bootstrap)
|       +-- harbor/                #   Disabled
|       +-- kustomization.yaml     #   resources: []
|
+-- monitoring/                    # Disabled (chua du resource)
|   +-- kustomization.yaml         #   resources: []
|   +-- prometheus-rules/          #   Alert rules (san sang khi bat)
|   +-- grafana-dashboards/        #   Dashboard JSON (san sang khi bat)
|
+-- teams/
|   +-- _template/                 # Template cho team moi
|   +-- finance/                   # Team finance
|
+-- scripts/
    +-- bootstrap-cluster.sh       # Bootstrap tu cluster trong
    +-- teardown-cluster.sh        # Xoa toan bo services
    +-- health-check.sh            # Kiem tra suc khoe
    +-- onboard-team.sh            # Onboard team moi
    +-- dr-recovery.sh             # Disaster recovery
```

## Quick Start

### Bootstrap tu cluster CFKE trong

```bash
# Dry run
bash scripts/bootstrap-cluster.sh --dry-run

# Chay that
bash scripts/bootstrap-cluster.sh
```

Script tu dong thuc hien:
1. **Phase 1**: local-path-provisioner (StorageClass)
2. **Phase 2**: MinIO (S3 object storage)
3. **Phase 3**: Gitea (Git server) + push code qua port-forward
4. **Phase 4**: ArgoCD v2.14.21 + root-app (App-of-Apps)
5. **Phase 4f**: Spark Operator CRDs (server-side apply, > 262KB)
6. **Phase 5**: Airflow DB migration + admin user (ArgoCD khong chay Helm hooks)

### Teardown

```bash
bash scripts/teardown-cluster.sh
```

### Tao Port Forwarding tren NAT VPS panel

Sau khi bootstrap, tao port forwarding tren panel cua tung VPS:

| Cong trong (NodePort) | Service |
|----------------------|---------|
| 30443 | ArgoCD |
| 30300 | Gitea |
| 30080 | Airflow |
| 30901 | MinIO Console |

Truy cap: `http(s)://IP_CHINH:CONG_NGOAI`

## Luu y quan trong

### CFKE + Cilium
- ArgoCD tao NetworkPolicies khong tuong thich voi Cilium — bootstrap script tu dong xoa
- Sau moi lan upgrade ArgoCD, can xoa lai NetworkPolicies

### Spark Operator CRDs
- CRDs > 262KB — vuot gioi han `kubectl apply` (client-side)
- CRDs duoc cai rieng trong bootstrap bang `--server-side` apply
- Kustomize helmCharts dung `includeCRDs: false`
- ArgoCD app dung `ServerSideApply=true`

### Airflow
- Dung LocalExecutor (khong can Redis/workers)
- DB migration chay thu cong trong Phase 5 (ArgoCD khong chay Helm hooks)
- Git-sync DAGs tu Gitea repo `platform-dags`

### Storage
- local-path-provisioner chi ho tro RWO (khong RWX)
- MinIO dung emptyDir (mat data khi pod restart — OK cho dev)

## Tech Stack

| Component | Version | Vai tro |
|-----------|---------|---------|
| ArgoCD | v2.14.21 | GitOps deployment |
| Spark Operator | v2.1.0 | Spark job management tren K8s |
| Airflow | 2.8.1 | Workflow orchestration |
| Gitea | latest | Git server (noi bo) |
| MinIO | 2024-01 | S3-compatible object storage |
| Iceberg REST | 0.10.0 | Table format catalog |
| local-path | latest | StorageClass (RWO) |

## Credentials mac dinh (thay doi sau khi deploy!)

| Service | Username | Password |
|---------|----------|----------|
| ArgoCD | admin | (tu sinh, xem output bootstrap) |
| Airflow | admin | admin |
| Gitea | gitea-admin | Gitea@Admin2024! |
| MinIO | minioadmin | MinIO@Admin2024! |
