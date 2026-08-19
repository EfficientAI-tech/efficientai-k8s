# Database sharding and worker concurrency

EfficientAI **>= 1.6** adds optional **data-plane sharding** (catalog + data shards) and Redis **fair-share limits** for import/eval workers. The upstream reference is [`config.yml.example`](https://github.com/EfficientAI-tech/efficientAI/blob/main/config.yml.example) in the main app repo.

This guide covers how those settings map to the Helm chart.

## Celery queue split

Docker Compose and the chart split Celery into dedicated pools:

| Pool | Queues / role | Pool type | Default concurrency | Replicas |
|------|---------------|-----------|---------------------|----------|
| **worker** | `celery`, `audio-metrics` | prefork (default) | 8 | scalable |
| **worker-imports** | `imports`, `diarization`, `eval-control`, `evaluations` | `threads` (recommended) | 8 (32 in high-concurrency overlay) | scalable |
| **beat** | Celery Beat + `platform` queue worker | `threads` (platform worker) | 2 | **1 only** |
| **worker-usage** | `usage` | `threads` | 4 | 1 default |

Celery drains queues **in list order**:

1. **`imports`** — recording fetch for call imports
2. **`diarization`** — manual diarise jobs
3. **`eval-control`** — cancel, retry, materialize eval jobs
4. **`evaluations`** — fair-dispatch eval rows, transcribe chains, post-eval LLM scoring

Chart defaults mirror [`docker-compose.yml`](https://github.com/EfficientAI-tech/efficientAI/blob/main/docker-compose.yml):

```yaml
efficientai:
  worker:
    queues: celery,audio-metrics
    concurrency: 8

  workerImports:
    enabled: true
    queues: imports,diarization,eval-control,evaluations
    pool: threads
    concurrency: 32   # high-concurrency overlay

  beat:
    enabled: true

  workerUsage:
    enabled: true
```

When using KEDA queue-depth autoscaling, include **`eval-control`** in the trigger list (it inherits from `workerImports.queues` by default). See [`docs/gke-gcs-observability.md`](gke-gcs-observability.md#step-9--queue-depth-autoscaling-with-keda-optional).

## Single-database mode (default)

The chart's default is **legacy single-DB mode**: one PostgreSQL database (`efficientai`) and `database.sharding.enabled: false`.

Connection strings are injected as **environment variables only** — the ConfigMap deliberately omits `database.url` so the YAML loader cannot overwrite `DATABASE_URL` with a literal placeholder. See the configuration model in [`README.md`](../README.md#configuration-model).

No extra values are required beyond the standard Postgres subchart or `examples/external-postgres.yaml`.

## Data-plane sharding (enterprise)

Sharding splits metadata from high-volume row data:

| Physical DB | Role |
|-------------|------|
| `efficientai_catalog` | Metadata, headers, registry, integrations |
| `efficientai_data_01`, `efficientai_data_02`, … | Sharded row data (call-import rows today) |

Logical shard IDs in config use labels like `data-shard-01`, `data-shard-02`.

### Prerequisites

- External managed PostgreSQL (or a self-managed cluster) with **one catalog database and one or more data shard databases** provisioned and migrated.
- Set `postgresql.deploy: false` and point at your external host, **or** use separate hosts per DB via env vars (below).
- Smaller per-process connection pools when many shards are active (`pool_size` / `max_overflow` in config, or `DB_POOL_SIZE` / `DB_MAX_OVERFLOW` env vars).

### What goes in the ConfigMap vs env vars

The chart **strips the entire `database` block** from the rendered `config.yml` (including `database.url`, `catalog_url`, and shard URLs) so connection strings never land in a ConfigMap.

Configure sharding as follows:

| Setting | Recommended source |
|---------|-------------------|
| `database.sharding.enabled`, `row_chunk_size`, `pool_size`, `max_overflow` | Env vars `DB_SHARDING_ENABLED`, `DB_SHARD_ROW_CHUNK_SIZE`, `DB_POOL_SIZE`, `DB_MAX_OVERFLOW` **or** mount a supplemental config fragment (advanced) |
| `database.catalog_url` | Secret → env `DB_CATALOG_URL` on **web**, **worker**, and **worker-imports** |
| `database.shards[].id` + `url` | Secret → env `DB_SHARD_ENTRIES` (JSON array) on all app pods |

Example values overlay: [`examples/database-sharding.yaml`](../examples/database-sharding.yaml).

### Sizing pools under sharding

Each worker-imports thread may hold **catalog + shard** connections for tens of seconds. When sharding is on, reduce per-process pools and scale horizontally instead:

```yaml
# Via additionalEnv on web, worker, and workerImports (see example overlay)
# DB_POOL_SIZE: "5"
# DB_MAX_OVERFLOW: "10"
```

Match `workers.eval_global_inflight_limit` (below) to `worker-imports replicas × concurrency`.

## Worker fair-share limits (`workers.*`)

Redis-backed fair-share caps live under `efficientai.config.workers` and are rendered verbatim into `config.yml` (non-secret). They gate parallel import fetches and eval/diarization dispatch.

Scale **`eval_global_inflight_limit`** with your worker-imports footprint:

```text
eval_global_inflight_limit ≈ worker-imports replicas × concurrency
```

Example for the GKE high-concurrency overlay (8–20 pods × 32 threads → 256–640 threads):

```yaml
efficientai:
  config:
    workers:
      eval_global_inflight_limit: 384      # 12 × 32 — mid-scale example
      eval_org_inflight_limit: 384
      eval_workspace_inflight_limit: 38      # global ÷ ~10 workspaces
      eval_job_inflight_limit: 75
      eval_fair_dispatch_batch_size: 75
      diarization_fair_dispatch_batch_size: 75
      import_fair_dispatch_batch_size: 75
      import_global_inflight_limit: 16
      import_org_inflight_limit: 16
      import_workspace_inflight_limit: 8
      telephony_import_credit_limit: 1000
      telephony_import_credit_window_seconds: 60
      telephony_import_backoff_base_seconds: 15
      telephony_import_backoff_max_seconds: 60
```

Layer [`examples/gke/values-gke-high-concurrency.yaml`](../examples/gke/values-gke-high-concurrency.yaml) and tune `eval_global_inflight_limit` to your actual replica count × threads.

Full field descriptions: [`config.yml.example` → `workers:`](https://github.com/EfficientAI-tech/efficientAI/blob/main/config.yml.example).

## Operational endpoints

Upstream also documents `operational.public` and `operational.trusted_ips` for locking down `/metrics` while keeping `/health` open for probes. Set under `efficientai.config.operational` — it passes through to the ConfigMap like other non-secret fields:

```yaml
efficientai:
  config:
    operational:
      public: false
      trusted_ips:
        - "10.0.0.0/8"   # VPC CIDR where Prometheus scrapes
```

## Related files

| File | Purpose |
|------|---------|
| [`examples/database-sharding.yaml`](../examples/database-sharding.yaml) | External Postgres + sharding env vars + worker limits |
| [`examples/gke/values-gke-high-concurrency.yaml`](../examples/gke/values-gke-high-concurrency.yaml) | 8–20 worker-imports pods, KEDA, thread pool |
| [`examples/external-postgres.yaml`](../examples/external-postgres.yaml) | External Postgres (single-DB mode) |
