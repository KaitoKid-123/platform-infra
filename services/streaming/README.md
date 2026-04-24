# Streaming Stack

Dedicated namespace for the Redpanda + Spark Structured Streaming + Iceberg pilot.

## Goals
- keep the current cluster unchanged
- isolate streaming resources from batch/data platform resources
- provide a safe foundation for replayable event processing

## Contents
- `namespace.yaml`: isolated namespace for the streaming pilot
- `redpanda.yaml`: single-broker Redpanda for dev/pilot usage
- `spark-streaming-role.yaml`: RBAC for Spark driver/executor pod interactions
- `spark-streaming-namespace-role-binding.yaml`: bind Spark SA to streaming namespace
- `streaming-checkpoint-pvc.yaml`: checkpoint storage for Structured Streaming

## Notes
- This stack is intentionally small and does not modify existing namespaces.
- Use `platform-dags/dags/streaming/` for Airflow orchestration.
- Use `team-finance/finance-app/src/jobs/streaming/` for job logic.
