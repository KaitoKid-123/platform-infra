# Platform Infrastructure

Hạ tầng Data Platform chạy trên **CFKE (CloudFleet Kubernetes Engine)** với NAT VPS, triển khai theo mô hình **GitOps** với ArgoCD.

> **Cloud Provider**: CloudFleet — NAT VPS (mỗi VPS 2vCPU, 4GB RAM, 5 port forwarding).
> **Git**: GitHub (KaitoKid-123) — migrated từ Gitea.

## Kiến trúc tổng quan

```
┌──────────────────────────────────────────────────────────────────────┐
│                          Developer (local)                            │
│  platform-infra/   platform-dags/   team-finance/                    │
│         │                 │                │                         │
└─────────┼─────────────────┼────────────────┼─────────────────────────┘
          │                 │                │
          ▼                 │                │
  ┌───────────────┐         │                │
  │   GitHub       │         │                │
  │  KaitoKid-123  │◄────────┴────────────────┘
  └───────┬───────┘         (git push)
          │ sync
          ▼
  ┌──────────────────────────────────────────────────────────────┐
  │                    ArgoCD v2.14.21                            │
  │                  (App-of-Apps root)                          │
  └───┬──────┬──────────┬──────────┬──────────┬───────────────┘
      │      │          │          │          │
  ┌───▼──┐ ┌▼─────┐ ┌──▼───┐ ┌──▼─────┐ ┌──▼──────┐
  │ argocd│ │compute│ │ data │ │storage │ │ teams   │
  │      │ │      │ │      │ │        │ │finance  │
  │      │ │Spark │ │Airflow│ │MinIO   │ │HR       │
  │      │ │Op.   │ │LocalEx│ │Iceberg │ │Mkt      │
  │      │ │2.1.0 │ │2.8.1  │ │REST    │ │Sale     │
  └──────┘ └──────┘ └───────┘ └────────┘ └─────────┘
```

## Trạng thái hiện tại

| Service | Status | Namespace | Quản lý |
|---------|--------|-----------|----------|
| ArgoCD v2.14.21 | Active | argocd | Bootstrap script |
| Spark Operator v2.1.0 | Active | platform-compute | ArgoCD (helmCharts) |
| Airflow 2.8.1 (LocalExecutor) | Active | platform-data | ArgoCD (helmCharts) |
| MinIO 2024-01 | Active | platform-storage | ArgoCD (plain YAML) |
| Iceberg REST Catalog 0.10.0 | Active | platform-storage | ArgoCD (plain YAML) |
| PostgreSQL 15.5 (Iceberg metadata) | Active | platform-storage | ArgoCD (plain YAML) |
| local-path-provisioner | Active | local-path-storage | Bootstrap script |
| **Disabled** (chưa đủ resource) | — | — | Prometheus/Grafana, Trino, Kafka, Harbor, OpenMetadata, Flink |

## Cluster

- **4 nodes** (NAT VPS, 2vCPU / 4GB RAM mỗi node = **16GB RAM, 8 cores**)
- **CNI**: Cilium (CFKE managed)
- **Storage**: local-path-provisioner (chỉ hỗ trợ RWO)
- **Ingress**: Không có — truy cập qua NodePort + NAT Port Forwarding

## NodePort Mapping

Truy cập từ bên ngoài qua `IP_NODE_1:PORT` (cấu hình trên NAT VPS panel):

| Service | NodePort | Ghi chú |
|---------|----------|---------|
| ArgoCD server | 30443 | HTTPS |
| Airflow webserver | 30080 | HTTP |
| MinIO Console | 30901 | HTTP |

Các service nội bộ (ClusterIP):

| Service | Internal Endpoint |
|---------|-------------------|
| MinIO S3 API | `http://minio.platform-storage:9000` |
| Iceberg REST Catalog | `http://iceberg-rest.platform-storage:8181` |
| Iceberg PostgreSQL | `postgresql://iceberg-postgres.platform-storage:5432` |

## Cấu trúc thư mục

```
platform-infra/
│   ├── apps/                              # ArgoCD Application manifests (App-of-Apps)
│   │   ├── platform-root-app.yaml         #  -> apps/              (root App-of-Apps)
│   │   ├── platform-compute-app.yaml      #  -> services/compute    (Spark Operator)
│   │   ├── platform-data-app.yaml         #  -> services/data      (Airflow)
│   │   ├── platform-storage-app.yaml      #  -> services/storage    (MinIO, Iceberg)
│   │   ├── platform-ops-app.yaml          #  -> services/ops        (placeholder)
│   │   ├── platform-monitoring-app.yaml  #  -> monitoring/        (disabled)
│   │   ├── team-finance-infra-app.yaml   #  -> teams/finance
│   │   ├── team-hr-infra-app.yaml
│   │   ├── team-mkt-infra-app.yaml
│   │   └── team-sale-infra-app.yaml
├── base/                              # Shared K8s manifests (kustomize components)
│   ├── namespace/
│   │   ├── namespace.yaml             # Namespace template
│   │   ├── network-policy.yaml        # Cilium-compatible NP
│   │   └── resource-quota.yaml        # Cluster-wide quota defaults
│   └── rbac/
│       ├── role-binding.yaml
│       └── service-account.yaml
├── services/                          # Platform-level services
│   ├── compute/                       # Namespace: platform-compute
│   │   ├── spark-operator/            #  Spark Operator v2.1.0 (Helm via Kustomize)
│   │   └── kustomization.yaml
│   ├── data/                          # Namespace: platform-data
│   │   ├── airflow/                   #  Airflow 2.8.1 (Helm via Kustomize)
│   │   ├── airflow-nodeport.yaml      #  NodePort 30080
│   │   ├── github-dags-token.yaml     #  GitHub PAT secret cho git-sync
│   │   └── kustomization.yaml
│   ├── storage/                       # Namespace: platform-storage
│   │   ├── minio.yaml                 #  MinIO (NodePort Console 30901)
│   │   ├── iceberg-rest.yaml           #  Iceberg REST Catalog
│   │   ├── iceberg-postgres.yaml       #  PostgreSQL cho metadata
│   │   ├── iceberg-s3-secret.yaml     #  S3 credentials cho Iceberg REST
│   │   ├── local-path-provisioner.yaml
│   │   └── kustomization.yaml
│   └── ops/                           # Namespace: platform-ops (placeholder)
│       ├── kustomization.yaml          #  Disabled (resources: [])
│       └── placeholder-configmap.yaml
│
├── teams/                             # Per-team manifests (generated by onboard-team.sh)
│   ├── _template/                     #  Template dùng chung
│   ├── finance/                       #  Team Finance
│   ├── hr/, mkt/, sale/               #  Teams khác
│   └── monitoring/                    #  Monitoring stack (disabled)
│
├── secrets/                            # Secrets (gitignored — KHÔNG commit credential thật)
│   ├── services/argocd-github-token.yaml
│   └── teams/finance/sealed-s3-creds.yaml
│
└── scripts/
    ├── bootstrap-cluster.sh           #  Bootstrap toàn bộ cluster
    ├── teardown-cluster.sh            #  Xóa toàn bộ services
    ├── health-check.sh                #  Kiểm tra sức khỏe
    ├── onboard-team.sh                #  Onboard team mới
    └── migrate-to-github.sh            #  Migrate Gitea repos -> GitHub
```

## Quick Start

### Bootstrap cluster mới

```bash
# Dry run — xem plan trước
bash scripts/bootstrap-cluster.sh --dry-run

# Chạy thật
bash scripts/bootstrap-cluster.sh
```

Script tự động thực hiện:
1. **Phase 1**: local-path-provisioner (StorageClass)
2. **Phase 2**: MinIO (S3 object storage)
3. **Phase 3**: ArgoCD v2.14.21 + root-app (App-of-Apps pattern)
4. **Phase 4**: Spark Operator CRDs (>262KB — dùng `--server-side` apply)
5. **Phase 5**: Airflow DB migration + admin user

> **Lưu ý**: Không còn Gitea bootstrap — GitHub đã có sẵn.

### Teardown

```bash
bash scripts/teardown-cluster.sh
```

### Onboard team mới

```bash
bash scripts/onboard-team.sh <team-name>
# Ví dụ:
bash scripts/onboard-team.sh analytics
```

### Cổng truy cập (sau bootstrap)

| Service | URL |
|---------|-----|
| ArgoCD | `https://103.249.117.229:30443` |
| Airflow | `http://103.249.117.229:30080` |
| MinIO Console | `http://103.249.117.229:30901` |

## GitOps Flow

```
platform-infra/            platform-dags/             team-finance/
       │                          │                         │
       │ push                      │ push                    │ push
       ▼                          ▼                         ▼
  GitHub repo                  GitHub repo              GitHub repo
  (ArgoCD watches)             (Airflow git-sync)       (GitHub Actions CI)
       │                          │
       ▼                          ▼
  ArgoCD sync                  Airflow DAGs
  (namespaces, RBAC,           (SparkApplication YAMLs,
   Spark Operator,              dag files)
   Airflow, MinIO, ...)
```

- `platform-infra`: Infrastructure config → ArgoCD sync → K8s resources
- `platform-dags`: DAGs + SparkApp YAMLs → Airflow git-sync (60s poll)
- `team-finance`: PySpark code → GitHub Actions → Docker image GHCR

## Lưu ý quan trọng

### CFKE + Cilium
- ArgoCD tạo NetworkPolicies không tương thích với Cilium — bootstrap script tự động xóa
- Sau mỗi lần upgrade ArgoCD, có thể cần xóa lại NP

### Spark Operator CRDs
- CRDs > 262KB — vượt giới hạn `kubectl apply` (client-side)
- CRDs được apply riêng trong bootstrap bằng `--server-side`
- Kustomize helmCharts dùng `includeCRDs: false`
- ArgoCD app dùng `serverSideApply: true`

### Airflow
- Dùng **LocalExecutor** (không cần Redis/workers)
- DB migration chạy thủ công trong Phase 5 (ArgoCD không chạy Helm hooks)
- Git-sync DAGs từ GitHub repo `https://github.com/KaitoKid-123/platform-dags`

### Storage
- local-path-provisioner chỉ hỗ trợ RWO (ReadWriteOnce)
- MinIO dùng `emptyDir` (mất data khi pod restart — **chỉ OK cho dev**)
- Production: cần PersistentVolume thật hoặc hostPath

## Tech Stack

| Component | Version | Vai trò |
|-----------|---------|---------|
| ArgoCD | v2.14.21 | GitOps deployment engine |
| GitHub | — | Source of truth (replaced Gitea) |
| Spark Operator | v2.1.0 | PySpark job management trên K8s |
| Apache Spark | 3.5.0 | Distributed compute engine |
| Airflow | 2.8.1 | Workflow orchestration |
| MinIO | 2024-01 | S3-compatible object storage |
| Iceberg REST Catalog | 0.10.0 | Table format + REST metadata API |
| PostgreSQL | 15.5 | Iceberg REST backend (metadata) |
| local-path | latest | StorageClass (RWO) |
| GitHub Container Registry (GHCR) | — | Docker image registry |

## Credentials mặc định

| Service | Username | Password |
|---------|----------|----------|
| ArgoCD | admin | (tự sinh, xem output bootstrap) |
| Airflow | admin | admin |
| MinIO | minioadmin | MinIO@Admin2024! |

> **Bảo mật**: Thay đổi tất cả password sau khi deploy. Không commit secrets thật vào git.
