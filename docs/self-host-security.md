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
| DB migrations | Run once per upgrade (see below) |

**Self-host:** leave `rate_limits.enforce` unset (HTTP abuse limits off). **SaaS only:** set `rate_limits.enforce: true` in config.

**OIDC:** continue using [`examples/sso-oidc.yaml`](../examples/sso-oidc.yaml); cookie sessions apply to `local_password` browser login.

## Values overlay

Use [`examples/self-host-production-security.yaml`](../examples/self-host-production-security.yaml) as a starting point for any cluster with TLS ingress.

```bash
helm upgrade --install efficientai charts/efficientai -n efficientai \
  -f examples/self-host-production-security.yaml \
  -f my-secrets.yaml --wait
```

GKE: merge the same fields into [`examples/gke/values-gcs.yaml`](../examples/gke/values-gcs.yaml) (already includes `frontend_base_url`, HSTS, secure cookies).

## Probes

| Probe | Path | Notes |
|-------|------|--------|
| Liveness | `/health` | Cheap; always 200 when process is up |
| Readiness | `/health/ready` | 503 while migrations are pending; restricted to trusted IPs |

Ensure `operational.trusted_ips` includes your **VPC / node CIDRs** so the kubelet can call `/health/ready`. App defaults often include `10.0.0.0/8` and `172.16.0.0/12`; override if your nodes use other ranges.

## Database migrations

Upgrades that include session-epoch / cookie auth need Alembic migrations (e.g. `086_user_session_epoch`).

**One-off exec** (simplest):

```bash
kubectl -n efficientai exec deploy/RELEASE-efficientai-web -- eai migrate
```

Replace `RELEASE` with your Helm release name (default chart fullname prefix).

**Job pattern** (optional, for GitOps):

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: efficientai-migrate
  namespace: efficientai
spec:
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
            name: efficientai-efficientai-config
```

Adjust image tag, secret names, and ConfigMap name to match your release.

## Verify after deploy

1. Sign in — browser cookies include `eai_access`, `eai_refresh`, `eai_csrf`.
2. Refresh the page — session persists.
3. Agent Playground test call — no CSRF 403.
4. `curl -sf https://YOUR_DOMAIN/health` → `{"status":"ok"}`.
