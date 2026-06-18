# efficientai-k8s

Helm chart for deploying [EfficientAI](https://github.com/EfficientAI-tech/efficientAI) — the Voice AI Evaluation Platform — on Kubernetes.

## Repository Structure

- `charts/efficientai` — the Helm chart (umbrella with Postgres + Redis as Bitnami subcharts).
- `examples/` — values overlays and manifests; see [`examples/README.md`](examples/README.md) for the index.
- `docs/` — deployment guides (GKE with GCS and Prometheus/Grafana).
- `.github/workflows/` — lint/test on PRs and chart-releaser publish to GitHub Pages on `main`.

## Important: Bitnami Registry Changes

**Effective August 28, 2025**, Bitnami restructured its container registry. Most images moved to a paid "Secure Images" tier; older/versioned images live in the "Bitnami Legacy" repository.

This chart's `global.security.allowInsecureImages` defaults to `true` so the Bitnami Postgres/Redis subcharts continue to pull from the legacy registry. To use the paid Secure Images instead, set `global.security.allowInsecureImages: false` and override `postgresql.image.registry` / `redis.image.registry` to `bitnami`.

See [Bitnami's announcement](https://github.com/bitnami/charts/issues/35164) for details.

## Helm Chart

### Installation

```bash
helm repo add efficientai https://efficientai-tech.github.io/efficientai-k8s
helm repo update
helm install efficientai efficientai/efficientai -f values.yaml
```

Or install directly from the source tree:

```bash
git clone https://github.com/EfficientAI-tech/efficientai-k8s.git
cd efficientai-k8s
helm dependency update charts/efficientai
helm install efficientai charts/efficientai -n efficientai --create-namespace -f my-values.yaml
```

### Upgrading

```bash
helm repo update
helm upgrade efficientai efficientai/efficientai -f values.yaml
```

Review the [Bitnami Postgres](https://github.com/bitnami/charts/tree/main/bitnami/postgresql) and [Bitnami Redis](https://github.com/bitnami/charts/tree/main/bitnami/redis) upgrade notes if the subchart versions in `Chart.yaml` change between releases.

### Required configuration

Provide a `SECRET_KEY` (generate via `openssl rand -hex 32`). All other secrets are optional but recommended for production. Each sensitive value accepts either an inline `value:` (rendered into a chart-managed Secret) or a `secretKeyRef:` (sourced from a user-managed Secret).

```yaml
efficientai:
  secretKey:
    value: "REDACTED-openssl-rand-hex-32"
    # or:
    # secretKeyRef: { name: efficientai-app, key: SECRET_KEY }

  encryptionKey:
    value: ""        # optional but recommended

postgresql:
  auth:
    username: efficientai
    password: "change-me"        # OR existingSecret: ...

redis:
  auth:
    enabled: false
```

### Configuration model

The chart produces **one `config.yml`** (rendered into a ConfigMap and mounted at `/app/config.yml`), plus **environment variables** for every secret and every connection string. Pydantic Settings (`app/config.py`) reads env vars first, then `config.yml` overlays whatever's left — so we deliberately keep secrets and connection URLs out of the ConfigMap and rely on env vars for them.

| App setting | Where you set it | How it reaches the pod |
|---|---|---|
| Plain config (`app.debug`, `cors.origins`, `auth.providers`, `judge_alignment.*`, `storage.*`, `diarization.num_speakers`, `observability.loki.*`, ...) | `efficientai.config.*` (same nested shape as `config.yml`) | Verbatim in the ConfigMap |
| `DATABASE_URL` | `postgresql.*` (in-cluster) or `postgresql.deploy: false` + `host` (external) | Env var: built from `POSTGRES_USER`/`PASSWORD`/`HOST`/`PORT`/`DB`. **Not** written to `config.yml`. |
| `REDIS_URL`, `CELERY_BROKER_URL`, `CELERY_RESULT_BACKEND` | `redis.*` (in-cluster) or `redis.deploy: false` + `host` / `cluster.nodes` | Env vars: built from `REDIS_HOST`/`PORT`/auth. **Not** written to `config.yml`. |
| `storage.blob_provider` | `s3.enabled` / `gcs.enabled` | Rendered into the ConfigMap (`s3` by default, `gcs` when GCS is enabled) |
| `s3.bucket_name` / `region` / `endpoint_url` / `prefix` | `s3.bucket` / `region` / `endpoint` / `prefix` | Rendered into the ConfigMap |
| `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` | `s3.accessKeyId` / `s3.secretAccessKey` (`value:` OR `secretKeyRef:`) | Env vars sourced from the chart-managed Secret (inline `value:`) or your Secret (`secretKeyRef:`). **Not** written to `config.yml`. |
| `gcs.bucket_name` / `project_id` / `prefix` | `gcs.bucket` / `gcs.projectId` / `gcs.prefix` | Rendered into the ConfigMap |
| `BLOB_STORAGE_PROVIDER` / `GCS_ENABLED` / `GCS_BUCKET_NAME` / `GCS_PROJECT_ID` / `GCS_PREFIX` | `gcs.*` | Env vars; use GKE Workload Identity / Application Default Credentials for auth. |
| `SECRET_KEY` | `efficientai.secretKey` | Env var (chart Secret or your Secret) |
| `ENCRYPTION_KEY` | `efficientai.encryptionKey` | Env var (chart Secret or your Secret) |
| `HUGGINGFACE_TOKEN` | `efficientai.huggingfaceToken` | Env var (chart Secret or your Secret) |
| `EFFICIENTAI_LICENSE` | `efficientai.license` | Env var (chart Secret or your Secret) |

**Why no `${VAR}` placeholders in `config.yml`?** The app's YAML loader (`app/config.py:load_config_from_file`) assigns values literally — it does not expand `${...}` syntax. Writing `database: { url: "${DATABASE_URL}" }` would clobber the env-derived URL with the literal placeholder string and crash SQLAlchemy. Keeping connection strings and secrets in env vars only is the safe pattern.

**Anything you set under `efficientai.config.{database,redis,celery,license,app.secret_key,diarization.huggingface_token}` is stripped** by the ConfigMap template, so you can't accidentally leak a secret into a ConfigMap.

**Extending it:** to add a new non-secret config field, just add it under `efficientai.config.*` — it flows through `toYaml` automatically, no template change required. For a new secret field, see the "Adding a new secret" recipe in [`charts/efficientai/README.md`](charts/efficientai/README.md#adding-a-new-secret).

### Sizing

Defaults are minimal for dev / smoke testing. For production, scale per-component:

```yaml
efficientai:
  web:
    replicaCount: 3
    resources:
      limits:   { cpu: "2", memory: "4Gi" }
      requests: { cpu: "1", memory: "2Gi" }
    autoscaling:
      enabled: true
      minReplicas: 3
      maxReplicas: 10
      targetCPUUtilizationPercentage: 70
    pdb:
      enabled: true
      minAvailable: 2

  worker:
    replicaCount: 2
    resources:
      limits:   { cpu: "2", memory: "8Gi" }
      requests: { cpu: "1", memory: "4Gi" }

  workerImports:
    replicaCount: 1
    concurrency: 4
    resources:
      limits:   { cpu: "2", memory: "4Gi" }
      requests: { cpu: "500m", memory: "2Gi" }

postgresql:
  primary:
    persistence:
      size: 50Gi
    resources:
      limits:   { cpu: "2", memory: "4Gi" }
      requests: { cpu: "1", memory: "2Gi" }

redis:
  primary:
    persistence:
      size: 8Gi
    resources:
      limits:   { cpu: "1", memory: "1.5Gi" }
      requests: { cpu: "500m", memory: "1Gi" }
```

### Examples

Every example in `examples/` is a values overlay or manifest. See [`examples/README.md`](examples/README.md) for the full index.

| File | What it demonstrates |
|---|---|
| `external-postgres.yaml` | `postgresql.deploy: false`, external host, existingSecret, plus optional TLS / client cert via `extraVolumes` + `additionalEnv` |
| `external-redis.yaml` | External standalone Redis and external Redis Cluster (e.g. AWS ElastiCache config endpoint) |
| `external-s3.yaml` | External S3 bucket with credentials sourced via `secretKeyRef` |
| `gke/values-gcs.yaml` | GKE + GCS via Workload Identity, observability config, GCE Ingress |
| `ingress-alb.yaml` | AWS Load Balancer Controller with redirect action and custom per-host backend |
| `sso-oidc.yaml` | External OIDC SSO (Okta-style) wired through `efficientai.web.additionalEnv` |
| `topology-spread.yaml` | Zone- and host-aware spread constraints for `web`, `worker`, and `workerImports` |

```bash
helm install efficientai charts/efficientai -f examples/external-postgres.yaml
```

### GKE with GCS and observability (Prometheus + Grafana)

See **[`docs/gke-gcs-observability.md`](docs/gke-gcs-observability.md)** for the full guide. Summary:

```bash
make observability-install
make observability-servicemonitor

cp examples/gke/values-gcs.yaml my-gke-values.yaml   # customize domains, project, bucket
helm upgrade --install efficientai charts/efficientai -n efficientai -f my-gke-values.yaml --wait

make observability-grafana-expose   # optional: public Grafana URL
helm upgrade kube-prometheus prometheus-community/kube-prometheus-stack \
  -n observability -f examples/observability/kube-prometheus-stack.yaml

# Import EfficientAI dashboards from the main app repo (observability/grafana/dashboards/)
```

### Custom Storage Class

```yaml
# Global default
global:
  defaultStorageClass: "my-storage-class"

# Or per-component
postgresql:
  primary:
    persistence:
      storageClass: "postgres-ssd"
redis:
  primary:
    persistence:
      storageClass: "redis-ssd"
```

### Custom deployment strategy

```yaml
efficientai:
  web:
    deployment:
      strategy:
        type: RollingUpdate
        rollingUpdate:
          maxSurge: 25%
          maxUnavailable: 25%
```

### Full chart reference

See [`charts/efficientai/README.md`](charts/efficientai/README.md) for the full list of configurable values.

## Testing

```bash
# Install the plugin once
helm plugin install https://github.com/helm-unittest/helm-unittest.git

# Run unit tests
helm unittest charts/efficientai --color
```

Lint and render the templates with the included `Makefile`:

```bash
make deps      # helm dependency update
make lint
make template
make unittest
make install   # to a real cluster (uses kubeconfig context)
```

## Local dev with kind

The repo ships two helper scripts under `scripts/` for end-to-end local testing on [kind](https://kind.sigs.k8s.io/) using a local Docker registry (so private GHCR / image-pull problems don't get in the way):

```bash
make kind-up       # one-time: create kind cluster + localhost:5001 registry
make kind-deploy   # push local efficientai-api/-worker:1.3.9 images + helm upgrade --install
make kind-down     # tear down cluster + registry
```

`make kind-deploy` will:

- Tag and push `ghcr.io/efficientai-tech/efficientai-{api,worker}:1.3.9` from your local Docker daemon into the kind registry at `localhost:5001`.
- Reuse existing in-cluster secrets on upgrade (so `SECRET_KEY`, `ENCRYPTION_KEY`, and the Postgres password don't rotate on every redeploy).
- Run `helm upgrade --install` pointing at `localhost:5001` for the app images, and wait for all five workloads (`postgresql`, `redis-master`, `web`, `worker`, `worker-imports`) to be Ready.

After it finishes:

```bash
kubectl -n efficientai port-forward svc/dev-efficientai-web 8000:8000
open http://localhost:8000/docs
```

Override the defaults via env vars: `TAG=1.4.0 NAMESPACE=staging RELEASE=stage make kind-deploy`.

## License

[MIT](./LICENSE)
