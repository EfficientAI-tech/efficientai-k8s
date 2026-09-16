# Self-host security (platform PR #124)

EfficientAI [PR #124](https://github.com/EfficientAI-tech/efficientAI/pull/124) adds cookie-based browser sessions, CSRF, TrustedHost/HSTS, SSRF checks on recording URLs, and stricter production validation (`SECRET_KEY` when `debug: false`).

The Helm chart maps these settings under **`efficientai.config.*`** in [`charts/efficientai/values.yaml`](../charts/efficientai/values.yaml). Secrets stay in env vars (`SECRET_KEY`, `ENCRYPTION_KEY`, blob credentials) — not in the ConfigMap.

## Production checklist

Before exposing a self-hosted deployment on HTTPS:

| Item | Where |
|------|--------|
| Strong `SECRET_KEY` (32+ bytes) | `efficientai.secretKey` or `secretKeyRef` |
| `app.debug: false` | `efficientai.config.app.debug` |
| Public app URL | `efficientai.config.app.frontend_base_url` (must match ingress hostname) |
| CORS | `efficientai.config.cors.origins` — include the frontend origin |
| Cookie sessions | `auth.local_password.cookie_session.enabled: true`, **`secure: true`** behind TLS |
| HSTS | `security.hsts_enabled: true` |
| Trusted hosts | Do **not** list `localhost` in production; optional `security.trusted_hosts` for legacy hostnames |
| Separate API host | `security.public_base_url` if API hostname ≠ SPA |
| Ingress hostname | `efficientai.web.ingress.hosts` aligned with `frontend_base_url` |
| Image tag | Pin `efficientai.image.api.tag` / `worker.tag` to a release that includes PR #124 |
| Readiness `/health/ready` | PR #124+ API only; chart default — use [`examples/chart-without-pr124-app.yaml`](../examples/chart-without-pr124-app.yaml) if image is older |
| `operational.trusted_ips` | Only if kubelet/Prometheus IPs are **outside** app defaults — org-specific CIDRs (see below) |
| DB migrations | Run once per upgrade (see below) |

**Self-host:** leave `rate_limits.enforce` unset (HTTP abuse limits off). **SaaS only:** set `rate_limits.enforce: true` in config.

**OIDC:** continue using [`examples/sso-oidc.yaml`](../examples/sso-oidc.yaml); cookie sessions apply to `local_password` browser login.

## Values overlay

Use [`examples/self-host-production-security.yaml`](../examples/self-host-production-security.yaml) as a starting point for any cluster with TLS ingress.

**Helm `--wait` and migrations:** Readiness uses `/health/ready`, which returns **503 until Alembic migrations finish**. If an upgrade needs a new migration, `helm upgrade --wait` can **time out** before migrations run. Use one of these patterns:

1. **Recommended — chart migrate Job** (same **`DATABASE_URL` / Postgres / Redis / app env** as web — not just `efficientai-app-secrets`). After `helm upgrade --wait=false`, render and apply:
   ```bash
   helm template efficientai charts/efficientai -n efficientai \
     -f examples/self-host-production-security.yaml \
     -f my-secrets.yaml \
     --set efficientai.migrateJob.enabled=true \
     --set efficientai.migrateJob.includeInRelease=true \
     --set efficientai.migrateJob.suffix="$(date +%s)" \
     -s templates/migrate/job.yaml | kubectl apply -f -

   kubectl -n efficientai wait --for=condition=complete \
     job/$(kubectl get jobs -n efficientai -l app.kubernetes.io/component=migrate \
       --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}') \
     --timeout=15m
   kubectl -n efficientai rollout status deploy/efficientai-web --timeout=10m
   ```
   See [Job pattern](#database-migrations) for details.
2. **Upgrade without waiting**, migrate via **exec on a pod that matches the Deployment’s current template** (not `deploy/...`, not “newest pod by time”):
   ```bash
   helm upgrade --install efficientai charts/efficientai -n efficientai \
     -f examples/self-host-production-security.yaml \
     -f my-secrets.yaml --wait=false

   NAMESPACE=efficientai
   RELEASE=efficientai
   DEPLOY=efficientai-web
   TEMPLATE_HASH=$(kubectl get deploy "$DEPLOY" -n "$NAMESPACE" \
     -o jsonpath='{.spec.template.metadata.labels.pod-template-hash}')
   DESIRED_IMAGE=$(kubectl get deploy "$DEPLOY" -n "$NAMESPACE" \
     -o jsonpath='{.spec.template.spec.containers[0].image}')

   WEB_POD=$(kubectl get pods -n "$NAMESPACE" \
     -l "app.kubernetes.io/name=efficientai,app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=web,pod-template-hash=${TEMPLATE_HASH}" \
     -o jsonpath='{.items[0].metadata.name}')
   ACTUAL_IMAGE=$(kubectl get pod -n "$NAMESPACE" "$WEB_POD" -o jsonpath='{.spec.containers[0].image}')
   test "$ACTUAL_IMAGE" = "$DESIRED_IMAGE"

   kubectl exec -n "$NAMESPACE" "$WEB_POD" -- eai migrate
   kubectl -n efficientai rollout status deploy/efficientai-web --timeout=10m
   ```
   If no pod matches `pod-template-hash` yet, wait until the rollout creates one (`kubectl get pods -w …`). Adjust `DEPLOY` / `app.kubernetes.io/instance` when the release name is not `efficientai`.
3. **Migrate before rolling web** — apply the chart migrate Job (same values as the upcoming upgrade) against the shared DB, then `helm upgrade ... --wait` when no pending migrations remain.

Greenfield installs with pending migrations: use (1) or (2) — avoid `--wait` until after `eai migrate` succeeds once.

```bash
# After migrations are applied (or on upgrades that need no new migration), --wait is fine:
helm upgrade --install efficientai charts/efficientai -n efficientai \
  -f examples/self-host-production-security.yaml \
  -f my-secrets.yaml --wait
```

GKE: merge the same fields into [`examples/gke/values-gcs.yaml`](../examples/gke/values-gcs.yaml) (already includes `frontend_base_url`, HSTS, secure cookies).

## Chart defaults vs production

| Setting | Chart default (`values.yaml`) | Production self-host |
|---------|--------------------------------|----------------------|
| `auth.local_password.cookie_session.secure` | `false` (HTTP dev / kind without TLS) | **`true`** in [`examples/self-host-production-security.yaml`](../examples/self-host-production-security.yaml) |
| Readiness probe | `/health/ready` | Same when API includes PR #124; otherwise override probe path |
| `operational.trusted_ips` | Omitted (app defaults apply) | Add only CIDRs your network team confirms |

Do not set `secure: true` until browsers reach the app over **HTTPS** (ingress TLS or terminating proxy). With `secure: true` on plain HTTP, login cookies are not sent and sessions break.

## Operational trusted IPs {#operational-trusted-ips}

On PR #124+ images, **`GET /health/ready`** (Kubernetes readiness) only succeeds when the caller’s IP is in `operational.trusted_ips`. The same list gates **`/metrics`**.

**Do not paste random CIDRs.** Wrong ranges cause readiness **404** and pods stay **NotReady**. The **`10.0.0.0/8`-style ranges in docs are intentional mirrors of platform defaults** (nodes, internal LBs, probes) — use them when you **override** the list, not as a substitute for confirming odd/outlier nets with your network team.

1. **Try omitting `trusted_ips` in Helm values first.** The application ships intentional defaults — typically **`10.0.0.0/8`**, **`172.16.0.0/12`**, and **`127.0.0.0/8`** (exact list is in upstream `config.yml.example` / PR #124). Those wide private ranges are **by design**, not placeholders: they cover common self-host paths without listing every subnet — **kubelet** readiness checks (often from node or pod CIDRs), **node InternalIPs**, in-VPC **internal load balancers** and health-check sources, and dev clusters on RFC1918. Most installs need **no** Helm `trusted_ips` key.
2. **If probes still fail**, add CIDRs your organization actually uses:
   - **Kubernetes node** (or pod network) CIDR from your cloud VPC docs or platform team.
   - **Prometheus / monitoring** scraper subnets if they must reach `/metrics`.
3. **Discover hints** (verify with network team before adding to config):
   ```bash
   kubectl get nodes -o wide
   # InternalIP values must fall inside a listed CIDR (or app defaults).
   ```
4. Set under `efficientai.config.operational.trusted_ips` in your values overlay — see placeholder comments in [`examples/self-host-production-security.yaml`](../examples/self-host-production-security.yaml).

Replacing the entire list in config **replaces** app defaults (does not merge). If you override, include every CIDR you still need (nodes, scrapers, break-glass admin VPN, etc.). When you must override, it is common to **re-list the same broad private ranges the app already uses** (e.g. `10.0.0.0/8`, `172.16.0.0/12`) **plus** any extra nets your platform team confirms (non-RFC1918 node CIDRs, dedicated Prometheus VPC, etc.) — not because those strings are magic, but because they mirror intentional platform defaults for LB/probe traffic.

Related: [`docs/database-sharding-and-workers.md`](database-sharding-and-workers.md#operational-endpoints) (metrics scraping on sharded deployments).

## Probes

| Probe | Path | Notes |
|-------|------|--------|
| Liveness | `/health` | Cheap; always 200 when process is up |
| Readiness | `/health/ready` | 503 while migrations are pending; **404** if caller IP ∉ `trusted_ips` |

Ensure kubelet source IPs are covered by **app defaults** or your **`operational.trusted_ips`** override. See [Operational trusted IPs](#operational-trusted-ips).

**Older API images** (no `/health/ready`): layer [`examples/chart-without-pr124-app.yaml`](../examples/chart-without-pr124-app.yaml) so readiness uses `/health` until you upgrade the image.

## Database migrations

Upgrades that include session-epoch / cookie auth need Alembic migrations (e.g. `086_user_session_epoch`).

Run migrations **before** expecting web pods to pass `/health/ready`, or use `--wait=false` then migrate (see [Values overlay](#values-overlay)). Migrations are **global to the database** — run **`eai migrate` once**, not on every replica.

### Chart migrate Job (recommended)

The chart can render a Job with the **same env blocks as web** (`POSTGRES_*`, `DATABASE_URL`, Redis, `SECRET_KEY`, etc.) — including bundled Bitnami Postgres and production `existingSecret` overlays.

After upgrading the release (same `-f` values and image tag as web):

```bash
helm template efficientai charts/efficientai -n efficientai \
  -f examples/self-host-production-security.yaml \
  -f my-secrets.yaml \
  --set efficientai.migrateJob.enabled=true \
  --set efficientai.migrateJob.suffix="$(date +%s)" \
  -s templates/migrate/job.yaml | kubectl apply -f -

JOB=$(kubectl get jobs -n efficientai -l app.kubernetes.io/component=migrate \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
kubectl -n efficientai wait --for=condition=complete "job/${JOB}" --timeout=15m
kubectl -n efficientai rollout status deploy/efficientai-web --timeout=10m
```

`efficientai.migrateJob.suffix` must be **unique per run** (Job names are immutable). Set **`includeInRelease: true` only on the one-shot `helm template … -s templates/migrate/job.yaml` command** — keep both flags `false` in committed values used with `helm upgrade`, so no migrate Job is ever part of the regular release.

Do **not** hand-write a Job that only `envFrom`s `efficientai-app-secrets`; that secret holds app keys, not chart-generated `DATABASE_URL` / Postgres host wiring.

### One-off exec (dev / fallback)

**Avoid `kubectl exec deploy/...`** and **avoid picking the newest pod by creation time** — scale-ups or rollbacks can make that an old revision. Select a pod whose **`pod-template-hash`** matches the Deployment’s **current** template, and confirm **`spec.containers[0].image`** equals the Deployment’s desired image before running migrate.

```bash
NAMESPACE=efficientai
RELEASE=efficientai
DEPLOY=efficientai-web
TEMPLATE_HASH=$(kubectl get deploy "$DEPLOY" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.metadata.labels.pod-template-hash}')
DESIRED_IMAGE=$(kubectl get deploy "$DEPLOY" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
WEB_POD=$(kubectl get pods -n "$NAMESPACE" \
  -l "app.kubernetes.io/name=efficientai,app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=web,pod-template-hash=${TEMPLATE_HASH}" \
  -o jsonpath='{.items[0].metadata.name}')
ACTUAL_IMAGE=$(kubectl get pod -n "$NAMESPACE" "$WEB_POD" -o jsonpath='{.spec.containers[0].image}')
test "$ACTUAL_IMAGE" = "$DESIRED_IMAGE"
kubectl exec -n "$NAMESPACE" "$WEB_POD" -- eai migrate
```

Prefer the [chart migrate Job](#chart-migrate-job-recommended) for production upgrades.

## Verify after deploy

1. Sign in — browser cookies include `eai_access`, `eai_refresh`, `eai_csrf`.
2. Refresh the page — session persists.
3. Agent Playground test call — no CSRF 403.
4. `curl -sf https://YOUR_DOMAIN/health` → `{"status":"ok"}`.
