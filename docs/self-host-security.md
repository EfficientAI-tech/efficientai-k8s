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

1. **Recommended — one-off Job with the new API image** (same tag as `efficientai.image.api.tag` in your upgrade). Runs migration code once, independent of which web pods are Ready. See [Job pattern](#database-migrations) below; apply the Job, wait for `Complete`, then `kubectl rollout status deploy/efficientai-web`.
2. **Upgrade without waiting**, migrate on a **new-revision web pod**, then wait for rollout:
   ```bash
   helm upgrade --install efficientai charts/efficientai -n efficientai \
     -f examples/self-host-production-security.yaml \
     -f my-secrets.yaml --wait=false

   # Do not use kubectl exec deploy/... — Kubernetes may pick an old Ready pod during rollouts.
   WEB_POD=$(kubectl get pods -n efficientai \
     -l app.kubernetes.io/name=efficientai,app.kubernetes.io/instance=efficientai,app.kubernetes.io/component=web \
     --sort-by=.metadata.creationTimestamp \
     -o jsonpath='{.items[-1].metadata.name}')
   kubectl exec -n efficientai "$WEB_POD" -- eai migrate

   kubectl -n efficientai rollout status deploy/efficientai-web --timeout=10m
   ```
   Adjust `app.kubernetes.io/instance` if your Helm release name is not `efficientai`. Confirm the pod image matches the new tag: `kubectl get pod -n efficientai "$WEB_POD" -o jsonpath='{.spec.containers[0].image}{"\n"}'`.
3. **Migrate before rolling web** — run the Job (or a one-off pod) with the **new** image against the shared DB, then `helm upgrade ... --wait` when no pending migrations remain.

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

### Job pattern (recommended for upgrades)

Pin **`image:`** to the same API tag you set in Helm (`efficientai.image.api.tag`). Wire env/config like the web Deployment (chart Secret + ConfigMap).

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: efficientai-migrate
  namespace: efficientai
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: efficientai
      containers:
        - name: migrate
          image: ghcr.io/efficientai-tech/efficientai-api:TAG
          command: ["eai", "migrate", "--config", "/app/config.yml"]
          envFrom:
            - secretRef:
                name: efficientai-app-secrets
          volumeMounts:
            - name: config
              mountPath: /app/config.yml
              subPath: config.yml
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: efficientai-config
```

```bash
kubectl apply -f migrate-job.yaml
kubectl -n efficientai wait --for=condition=complete job/efficientai-migrate --timeout=15m
kubectl -n efficientai rollout status deploy/efficientai-web --timeout=10m
```

Adjust image tag, secret names, and ConfigMap name to match your release. The Job must see the same **`DATABASE_URL` / Redis env** as web pods — copy the `env` / `envFrom` block from `kubectl get deploy efficientai-web -o yaml` if the snippet above is not enough.

### One-off exec (dev / single-replica only)

**Avoid `kubectl exec deploy/...` during rollouts** — the Deployment may route exec to an **old Ready pod** with outdated migration code. Target a **specific pod** on the **new revision** (newest by creation time), or use the Job above.

```bash
NAMESPACE=efficientai
RELEASE=efficientai
WEB_POD=$(kubectl get pods -n "$NAMESPACE" \
  -l "app.kubernetes.io/name=efficientai,app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=web" \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')
kubectl exec -n "$NAMESPACE" "$WEB_POD" -- eai migrate
```

## Verify after deploy

1. Sign in — browser cookies include `eai_access`, `eai_refresh`, `eai_csrf`.
2. Refresh the page — session persists.
3. Agent Playground test call — no CSRF 403.
4. `curl -sf https://YOUR_DOMAIN/health` → `{"status":"ok"}`.
