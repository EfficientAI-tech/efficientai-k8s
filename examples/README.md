# Examples

Helm values overlays and Kubernetes manifests for common deployment patterns.

**GKE + GCS + observability:** see [`docs/gke-gcs-observability.md`](../docs/gke-gcs-observability.md).

**Database sharding + worker fair-share limits:** see [`docs/database-sharding-and-workers.md`](../docs/database-sharding-and-workers.md).

## Layout

| Path | Use when |
|------|----------|
| [`gke/`](gke/) | Deploying on GKE with GCS, GCE Ingress, and optional public Grafana |
| [`observability/`](observability/) | Loki + Prometheus + Grafana (any cluster; used by GKE guide) |
| Root `*.yaml` files | Other clouds or external dependencies |

## Generic values overlays (pick what you need)

| File | Purpose |
|------|---------|
| `external-postgres.yaml` | External PostgreSQL instead of in-cluster |
| `database-sharding.yaml` | External Postgres with catalog + data shards and `workers.*` limits |
| `external-redis.yaml` | External Redis or Redis Cluster |
| `external-s3.yaml` | AWS S3 blob storage |
| `ingress-alb.yaml` | AWS Application Load Balancer ingress |
| `sso-oidc.yaml` | OIDC / Okta SSO |
| `topology-spread.yaml` | Zone and host pod spread constraints |

```bash
helm install efficientai charts/efficientai -f examples/external-postgres.yaml
```

## GKE deployment (required files)

| File | Required |
|------|----------|
| `gke/values-gcs.yaml` | Yes — app + GCS + Loki config |
| `gke/values-gke-high-concurrency.yaml` | Optional — 8–20 worker-imports pods × 32 threads (KEDA) |
| `gke/managed-cert-app.yaml` | Yes — TLS for app hostname |
| `observability/loki.yaml` | Yes — via `make observability-install` |
| `observability/kube-prometheus-stack.yaml` | Yes — via `make observability-install` |
| `observability/servicemonitor.yaml` | Yes — via `make observability-servicemonitor` |
| `gke/grafana-proxy.yaml` | Only for public Grafana URL |
| `gke/ingress-grafana.yaml` | Only for public Grafana URL |
| `gke/values-grafana-ingress.yaml` | Optional Helm alternative to `ingress-grafana.yaml` |
