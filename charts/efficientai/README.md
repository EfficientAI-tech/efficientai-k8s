# efficientai

A Helm chart for the [EfficientAI](https://github.com/EfficientAI-tech/efficientAI) Voice AI Evaluation Platform.

This chart deploys:

- **web** — the FastAPI API (also serves the built frontend) — `Deployment`, `Service`, optional `Ingress`, `HPA`, `PDB`.
- **worker** — a Celery worker for the default queue — `Deployment` (optional `HPA`, `PDB`).
- **worker-imports** — a dedicated Celery worker for the `imports` queue (concurrency 4 by default) — `Deployment`.
- **postgresql** (optional, Bitnami subchart) — toggleable via `postgresql.deploy`.
- **redis** (optional, Bitnami subchart) — toggleable via `redis.deploy`. Cluster mode supported via external endpoints.

## TL;DR

```bash
helm dependency update charts/efficientai
helm install dev charts/efficientai \
  --set efficientai.secretKey.value="$(openssl rand -hex 32)" \
  --set postgresql.auth.password="$(openssl rand -hex 16)" \
  -n efficientai --create-namespace
```

## Values

### Global

| Key | Type | Default | Description |
|---|---|---|---|
| `global.defaultStorageClass` | string | `""` | Default StorageClass for all PVCs unless overridden per component. |
| `global.imageRegistry` | string | `""` | Override the image registry used by Bitnami subcharts. |
| `global.imagePullSecrets` | list | `[]` | Image pull secrets passed to subcharts and app pods. |
| `global.security.allowInsecureImages` | bool | `true` | Allow Bitnami legacy (free) images. Set to `false` only if using Bitnami Secure Images. |

### Application secrets (`efficientai.*`)

Each accepts either an inline `value:` or a `secretKeyRef: { name, key }` pointing at a user-managed Secret.

| Key | Required? | Notes |
|---|---|---|
| `efficientai.secretKey` | yes | Generate via `openssl rand -hex 32`. |
| `efficientai.encryptionKey` | recommended | Field-level encryption key. |
| `efficientai.huggingfaceToken` | optional | For pyannote speaker-diarization model download. |
| `efficientai.license` | optional | EfficientAI enterprise license JWT. |

### Images (`efficientai.image.*`)

| Key | Default |
|---|---|
| `efficientai.image.registry` | `ghcr.io` |
| `efficientai.image.pullPolicy` | `IfNotPresent` |
| `efficientai.image.api.repository` | `efficientai-tech/efficientai-api` |
| `efficientai.image.api.tag` | `""` (defaults to `Chart.AppVersion`) |
| `efficientai.image.worker.repository` | `efficientai-tech/efficientai-worker` |
| `efficientai.image.worker.tag` | `""` (defaults to `Chart.AppVersion`) |

### App config (`efficientai.config.*`)

Rendered into a `ConfigMap` and mounted at `/app/config.yml` in every app pod. Mirrors `efficientAI/config.yml` for **non-secret fields only**.

**Why no secrets or connection URLs in `config.yml`?** The app's YAML loader (`app/config.py:load_config_from_file`) assigns values literally — it does **not** expand `${...}` placeholders. So writing `database: { url: "${DATABASE_URL}" }` would clobber the env-derived URL with the literal placeholder string and crash SQLAlchemy. Pydantic Settings already reads `DATABASE_URL`, `REDIS_URL`, `SECRET_KEY`, etc. from env vars during startup, so the chart sets them as env and deliberately keeps them out of the ConfigMap. Anything you put under `efficientai.config.{database,redis,celery,license,app.secret_key,diarization.huggingface_token}` is **stripped** by the template before it lands in the ConfigMap.

**Full field-by-field mapping:**

| App setting | Source (`values.yaml`) | How it reaches the pod |
|---|---|---|
| `app.name`, `app.debug` | `efficientai.config.app.*` | ConfigMap (verbatim) |
| `SECRET_KEY` | `efficientai.secretKey` (`value:` or `secretKeyRef:`) | Env var (chart Secret or your Secret) |
| `ENCRYPTION_KEY` | `efficientai.encryptionKey` (`value:` or `secretKeyRef:`) | Env var (chart Secret or your Secret) |
| `server.host` / `server.port` | `efficientai.config.server.*` | ConfigMap (verbatim) |
| `DATABASE_URL` | `postgresql.*` (in-cluster) or `postgresql.deploy: false` + external host | Env var (built from `POSTGRES_USER/PASSWORD/HOST/PORT/DB` env) |
| `REDIS_URL` | `redis.*` (in-cluster) or `redis.deploy: false` + external host/cluster | Env var (built from `REDIS_HOST/PORT[/auth]` env) |
| `CELERY_BROKER_URL` / `CELERY_RESULT_BACKEND` | `redis.*` (same source as `REDIS_URL`) | Env vars |
| `storage.blob_provider` | `s3.enabled` / `gcs.enabled` | ConfigMap (`s3` by default, `gcs` when `gcs.enabled=true`) |
| `storage.upload_dir` / `max_file_size_mb` / `allowed_audio_formats` | `efficientai.config.storage.*` | ConfigMap (verbatim) |
| `s3.enabled` / `bucket_name` / `region` / `endpoint_url` / `prefix` | `s3.enabled` / `bucket` / `region` / `endpoint` / `prefix` | ConfigMap (verbatim) |
| `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` | `s3.accessKeyId` / `secretAccessKey` (`value:` or `secretKeyRef:`) | Env vars (chart Secret or your Secret) |
| `gcs.enabled` / `bucket_name` / `project_id` / `prefix` | `gcs.enabled` / `bucket` / `projectId` / `prefix` | ConfigMap (verbatim) |
| `BLOB_STORAGE_PROVIDER` / `GCS_ENABLED` / `GCS_BUCKET_NAME` / `GCS_PROJECT_ID` / `GCS_PREFIX` | `gcs.*` | Env vars (use GKE Workload Identity / ADC for credentials) |
| `diarization.num_speakers` | `efficientai.config.diarization.num_speakers` | ConfigMap (verbatim) |
| `HUGGINGFACE_TOKEN` | `efficientai.huggingfaceToken` (`value:` or `secretKeyRef:`) | Env var (chart Secret or your Secret) |
| `cors.origins` | `efficientai.config.cors.origins` | ConfigMap (verbatim) |
| `api.prefix` / `key_header` / `rate_limit_per_minute` | `efficientai.config.api.*` | ConfigMap (verbatim) |
| `auth.providers` / `auth.local_password.*` | `efficientai.config.auth.*` | ConfigMap (verbatim) |
| `judge_alignment.enabled` / `csv_max_rows` | `efficientai.config.judge_alignment.*` | ConfigMap (verbatim) |
| `observability.loki.*` | `efficientai.config.observability.loki.*` | ConfigMap (verbatim — point `url` at an external Loki) |
| `EFFICIENTAI_LICENSE` | `efficientai.license` (`value:` or `secretKeyRef:`) | Env var (chart Secret or your Secret) |

### Adding a new secret

1. Add a value/secretKeyRef block under `efficientai.<yourName>` in `values.yaml`.
2. Add one line to `efficientai.appEnvBlock` in `templates/_helpers.tpl`:
   ```
   {{- include "efficientai.secretValueEnv" (dict "root" . "cfg" .Values.efficientai.yourName "envName" "YOUR_ENV") }}
   ```
3. Add a key in `templates/secret.yaml`'s `stringData` block guarded by the same `$hasYourName` check pattern as the existing fields (it'll only render when the user gives an inline `value:`).
4. The app should read `YOUR_ENV` from the environment (Pydantic Settings or `os.environ`). **Do not** render `${YOUR_ENV}` into `config.yml` — the YAML loader treats it as a literal string.

### Adding a new non-secret config field

Just add it under `efficientai.config.*` — no template change needed. It flows through `toYaml` into the rendered `config.yml`.

### Components (`efficientai.web`, `efficientai.worker`, `efficientai.workerImports`)

Every component exposes the same surface:

| Key | Default | Notes |
|---|---|---|
| `replicaCount` | `1` | Ignored when `autoscaling.enabled: true`. |
| `command` | sensible default per component | Overridable container `command`. |
| `resources` | `{}` | Standard `requests`/`limits`. |
| `autoscaling.enabled` | `false` | When true, creates an `HPA` v2. |
| `autoscaling.minReplicas` / `maxReplicas` / `targetCPUUtilizationPercentage` | — | HPA params. |
| `pdb.enabled` | `false` | When true, creates a `PodDisruptionBudget`. |
| `pdb.minAvailable` / `pdb.maxUnavailable` (web only) | `1` / `null` | — |
| `deployment.strategy` | `{}` | E.g. `{ type: RollingUpdate, rollingUpdate: { maxSurge: 25%, maxUnavailable: 25% } }`. |
| `pod.annotations` / `pod.labels` | `{}` | Added to the pod template. |
| `pod.nodeSelector` / `pod.tolerations` / `pod.affinity` | `{}` | Standard scheduling. |
| `pod.topologySpreadConstraints` | `[]` | Pass-through. |
| `pod.securityContext` / `containerSecurityContext` | `{}` | Pod / container security context. |
| `hostAliases` | `[]` | Added to pod spec. |
| `additionalEnv` | `[]` | Raw env list appended after the chart's env block (last write wins). |
| `extraVolumes` / `extraVolumeMounts` | `[]` | For custom mounts (e.g. TLS certs). |

#### Web-only

| Key | Default |
|---|---|
| `efficientai.web.service.type` | `ClusterIP` |
| `efficientai.web.service.port` | `8000` |
| `efficientai.web.ingress.enabled` | `false` |
| `efficientai.web.ingress.className` | `""` |
| `efficientai.web.ingress.annotations` | `{}` |
| `efficientai.web.ingress.hosts` | one default host |
| `efficientai.web.ingress.tls` | `[]` |
| `efficientai.web.probes.liveness` / `probes.readiness` | HTTP `/api/v1/health` on port `8000` |

#### Worker-imports-only

| Key | Default |
|---|---|
| `efficientai.workerImports.enabled` | `true` |
| `efficientai.workerImports.queues` | `imports` |
| `efficientai.workerImports.concurrency` | `4` |

If `efficientai.workerImports.command` is left empty, the chart builds `celery -A app.workers.celery_app worker --loglevel=info --queues=<queues> --concurrency=<concurrency>` automatically. (We invoke `celery` directly rather than `eai worker --queues ... --concurrency ...` so the queue / concurrency flags work across all `efficientai-worker` image versions — older images' `eai worker` CLI doesn't expose those flags. Celery picks up the broker URL from the `CELERY_BROKER_URL` env the pod already exports.)

### Postgres (`postgresql.*`)

| Key | Default | Notes |
|---|---|---|
| `postgresql.deploy` | `true` | Set `false` to skip the Bitnami subchart and use an external Postgres. |
| `postgresql.host` | `""` | Required when `deploy: false`. |
| `postgresql.port` | `5432` | — |
| `postgresql.auth.username` | `efficientai` | — |
| `postgresql.auth.database` | `efficientai` | — |
| `postgresql.auth.password` | `""` | Inline password (rendered into the chart secret). |
| `postgresql.auth.existingSecret` | `""` | Name of a user-managed secret holding the password. |
| `postgresql.auth.secretKeys.userPasswordKey` | `password` | Key inside `existingSecret`. |
| `postgresql.primary.persistence.enabled` | `true` | — |
| `postgresql.primary.persistence.size` | `8Gi` | — |
| `postgresql.primary.persistence.storageClass` | `""` | — |

### Redis (`redis.*`)

| Key | Default | Notes |
|---|---|---|
| `redis.deploy` | `true` | Set `false` to use external Redis (standalone or cluster). |
| `redis.host` | `""` | Required when `deploy: false` and `cluster.enabled: false`. |
| `redis.port` | `6379` | — |
| `redis.architecture` | `standalone` | — |
| `redis.auth.enabled` | `false` | — |
| `redis.auth.password` | `""` | Inline password. |
| `redis.auth.existingSecret` | `""` | User-managed secret. |
| `redis.auth.existingSecretPasswordKey` | `password` | — |
| `redis.cluster.enabled` | `false` | Cluster mode requires `deploy: false`. |
| `redis.cluster.nodes` | `[]` | List of `host:port`. |
| `redis.tls.enabled` | `false` | — |

### External S3 (`s3.*`)

| Key | Default |
|---|---|
| `s3.enabled` | `true` |
| `s3.bucket` | `voiceai-evals-test` |
| `s3.region` | `us-east-1` |
| `s3.endpoint` | `""` (AWS S3) |
| `s3.forcePathStyle` | `false` |
| `s3.prefix` | `audio/` |
| `s3.accessKeyId` | `value: ""` / `secretKeyRef:` |
| `s3.secretAccessKey` | `value: ""` / `secretKeyRef:` |

### External GCS (`gcs.*`)

Enable this for native Google Cloud Storage. On GKE, use Workload Identity so the pod receives Application Default Credentials from its annotated Kubernetes ServiceAccount. Do not enable S3 and GCS at the same time.

| Key | Default |
|---|---|
| `gcs.enabled` | `false` |
| `gcs.bucket` | `""` |
| `gcs.projectId` | `""` |
| `gcs.prefix` | `audio/` |

## Examples

See [../../examples/](../../examples/) for ready-to-use overlays. GKE + GCS: [examples/gke/values-gcs.yaml](../../examples/gke/values-gcs.yaml).

For GCS + Loki + Prometheus + Grafana on GKE, follow [../../docs/gke-gcs-observability.md](../../docs/gke-gcs-observability.md).
