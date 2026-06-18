# Deploy EfficientAI on GKE with GCS and Observability

This guide covers a production-style deployment on **Google Kubernetes Engine (GKE)** with:

- **GCS** blob storage via Workload Identity (no JSON key files)
- **In-cluster** Postgres and Redis (Bitnami subcharts)
- **Loki + Prometheus + Grafana** for logs and metrics
- **GCE Ingress** with Google-managed TLS certificates

The Helm chart deploys the app only. The observability stack is a **separate Helm release** in the `observability` namespace.

## Prerequisites

| Tool | Purpose |
|------|---------|
| [gcloud CLI](https://cloud.google.com/sdk/docs/install) | GKE, GCS, IAM |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Cluster access |
| [Helm 3](https://helm.sh/docs/intro/install/) | Chart installs |
| DNS control | A records for app + Grafana hostnames |

Set shell variables (adjust for your environment):

```bash
export PROJECT_ID=your-gcp-project
export REGION=asia-south1          # or your region
export CLUSTER=efficientai-gke
export APP_DOMAIN=gcp.example.com
export GRAFANA_DOMAIN=grafana.gcp.example.com
export GCS_BUCKET=your-audio-bucket
export STATIC_IP_NAME=efficientai-ip
export NAMESPACE=efficientai
export RELEASE=efficientai
```

## Overview

```text
Internet
   │
   ▼
GCE Load Balancer (one static IP, two hostnames)
   ├── APP_DOMAIN          → efficientai-web (NodePort)
   └── GRAFANA_DOMAIN      → grafana-proxy (NodePort) → Grafana in observability

EfficientAI pods ──metrics──► Prometheus (scrapes /metrics via ServiceMonitor)
EfficientAI pods ──logs────► Loki (app SDK push; Promtail not required)
Grafana ◄── datasources ──── Prometheus + Loki
```

## Step 1 — Create the GKE cluster

Enable Workload Identity at cluster creation:

```bash
gcloud config set project "$PROJECT_ID"

gcloud container clusters create "$CLUSTER" \
  --region="$REGION" \
  --num-nodes=1 \
  --workload-pool="${PROJECT_ID}.svc.id.goog" \
  --disk-size=50 \
  --machine-type=e2-standard-4

gcloud container clusters get-credentials "$CLUSTER" --region="$REGION"
```

Install the GKE auth plugin if `kubectl` prompts for it:

```bash
# Debian/Ubuntu
sudo apt-get install google-cloud-cli-gke-gcloud-auth-plugin
```

Reserve a global static IP for Ingress:

```bash
gcloud compute addresses create "$STATIC_IP_NAME" --global
gcloud compute addresses describe "$STATIC_IP_NAME" --global --format='get(address)'
```

Point DNS **A records** for `APP_DOMAIN` and `GRAFANA_DOMAIN` at that IP.

## Step 2 — GCS bucket and Workload Identity

```bash
gcloud storage buckets create "gs://${GCS_BUCKET}" --location="$REGION"

export GSA=efficientai-gcs@${PROJECT_ID}.iam.gserviceaccount.com

gcloud iam service-accounts create efficientai-gcs \
  --display-name="EfficientAI GCS access"

gcloud storage buckets add-iam-policy-binding "gs://${GCS_BUCKET}" \
  --member="serviceAccount:${GSA}" \
  --role="roles/storage.objectAdmin"
```

After the app namespace and Kubernetes service account exist (Step 4), bind Workload Identity:

```bash
# KSA name = Helm release name when release matches chart name (efficientai/efficientai).
gcloud iam service-accounts add-iam-policy-binding "$GSA" \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${NAMESPACE}/${RELEASE}]"
```

## Step 3 — Kubernetes secrets

```bash
kubectl create namespace "$NAMESPACE"

kubectl -n "$NAMESPACE" create secret generic efficientai-app-secrets \
  --from-literal=SECRET_KEY="$(openssl rand -hex 32)" \
  --from-literal=ENCRYPTION_KEY="$(openssl rand -hex 32)"

# Bitnami Postgres subchart expects both keys:
kubectl -n "$NAMESPACE" create secret generic efficientai-postgres \
  --from-literal=password="$(openssl rand -base64 24)" \
  --from-literal=postgres-password="$(openssl rand -base64 24)"

kubectl -n "$NAMESPACE" create secret generic efficientai-redis \
  --from-literal=password="$(openssl rand -base64 24)"

# Enterprise license (optional):
kubectl -n "$NAMESPACE" create secret generic efficientai-license \
  --from-literal=jwt="YOUR_LICENSE_JWT"
```

## Step 4 — TLS certificates (ManagedCertificate)

Create one certificate **per hostname** (do not add both domains to a single cert and then edit it later — GKE can fail with `resourceInUseByAnotherResource`).

```bash
kubectl apply -f examples/gke/managed-cert-app.yaml
# Edit domains first, or:
kubectl -n "$NAMESPACE" apply -f - <<EOF
apiVersion: networking.gke.io/v1
kind: ManagedCertificate
metadata:
  name: efficientai-gcp-cert
  namespace: ${NAMESPACE}
spec:
  domains:
    - ${APP_DOMAIN}
EOF
```

The Grafana certificate is applied later with the Grafana proxy (Step 7).

## Step 5 — Install observability stack

Install **before** the app (or restart app pods after Loki is up):

```bash
make observability-install
make observability-servicemonitor
```

This installs:

| Component | Helm release | Namespace |
|-----------|--------------|-----------|
| Loki | `loki` | `observability` |
| Prometheus + Grafana | `kube-prometheus` | `observability` |

Values overlays: [`examples/observability/loki.yaml`](../examples/observability/loki.yaml), [`examples/observability/kube-prometheus-stack.yaml`](../examples/observability/kube-prometheus-stack.yaml).

**ServiceMonitor** ([`examples/observability/servicemonitor.yaml`](../examples/observability/servicemonitor.yaml)) tells Prometheus to scrape `http://efficientai-web:8000/metrics`. If your Helm release name is not `efficientai`, edit `app.kubernetes.io/instance` in that file.

## Step 6 — Deploy EfficientAI with GCS

Copy and customize the values overlay:

```bash
cp examples/gke/values-gcs.yaml my-gke-values.yaml
# Edit: image tags, APP_DOMAIN, GCS bucket, project ID, Workload Identity GSA annotation, CORS origins
```

Install:

```bash
helm dependency update charts/efficientai

helm upgrade --install "$RELEASE" charts/efficientai \
  -n "$NAMESPACE" \
  -f my-gke-values.yaml \
  --wait --timeout 15m
```

Key values in [`examples/gke/values-gcs.yaml`](../examples/gke/values-gcs.yaml):

```yaml
s3:
  enabled: false
gcs:
  enabled: true
  bucket: your-bucket
  projectId: your-gcp-project
efficientai:
  serviceAccount:
    annotations:
      iam.gke.io/gcp-service-account: efficientai-gcs@YOUR_PROJECT.iam.gserviceaccount.com
  config:
    observability:
      enabled: true
      loki:
        enabled: true
        url: "http://loki.observability.svc.cluster.local:3100"
  web:
    service:
      type: NodePort   # required for GCE Ingress
```

Complete Workload Identity binding (Step 2) if you skipped it until the KSA existed.

Wait for the app ingress to get an address:

```bash
kubectl -n "$NAMESPACE" get ingress
kubectl -n "$NAMESPACE" get managedcertificate efficientai-gcp-cert
```

## Step 7 — Expose Grafana on a subdomain

GCE Ingress **cannot**:

- Attach two separate Ingress resources to the same static IP when each has its own ManagedCertificate (IP conflict).
- Route to Services in another namespace.

Use the **grafana-proxy** pattern: nginx in the app namespace forwards to Grafana in `observability`, and add a second host rule on the **existing** app Ingress.

1. Set `GRAFANA_DOMAIN` in the proxy and ingress manifests (replace `grafana.gcp.example.com`).

2. Set Grafana `root_url` in [`examples/observability/kube-prometheus-stack.yaml`](../examples/observability/kube-prometheus-stack.yaml) to `https://${GRAFANA_DOMAIN}/`.

3. Apply:

```bash
make observability-grafana-expose

helm upgrade kube-prometheus prometheus-community/kube-prometheus-stack \
  -n observability \
  -f examples/observability/kube-prometheus-stack.yaml
```

4. Wait for the Grafana certificate (check every 10–15 min):

```bash
kubectl -n efficientai get managedcertificate grafana-gcp-cert
```

5. Get the Grafana admin password:

```bash
kubectl -n observability get secret kube-prometheus-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

If login fails, reset:

```bash
kubectl -n observability exec deployment/kube-prometheus-grafana -c grafana -- \
  grafana cli admin reset-admin-password 'your-new-password'
```

**Helm-managed ingress alternative:** use [`examples/gke/values-grafana-ingress.yaml`](../examples/gke/values-grafana-ingress.yaml) instead of `ingress-grafana.yaml`.

## Step 8 — Import EfficientAI dashboards

kube-prometheus-stack ships **generic Kubernetes dashboards** only. EfficientAI-specific dashboards live in the main app repo:

```text
efficientAI/observability/grafana/dashboards/
```

Import in Grafana: **Dashboards → New → Import** (upload JSON files).

## Verification

```bash
# App health
curl -sf "https://${APP_DOMAIN}/api/v1/health"

# Metrics endpoint
kubectl -n efficientai port-forward svc/efficientai-web 8000:8000 &
curl -sf localhost:8000/metrics | head

# Prometheus target (port-forward Prometheus UI on 9090)
kubectl -n observability port-forward svc/kube-prometheus-kube-prome-prometheus 9090:9090
# Open http://localhost:9090/targets — efficientai-web should be UP

# Loki labels
kubectl -n observability port-forward svc/loki 3100:3100 &
curl -s http://localhost:3100/loki/api/v1/labels

# Grafana Explore → Loki → {service="api"}  (label names may vary by app version)
```

## Makefile reference

```bash
make observability-repos              # add Helm repos
make observability-install            # Loki + kube-prometheus-stack
make observability-servicemonitor     # EfficientAI /metrics scrape
make observability-grafana-expose     # proxy + ingress patch for Grafana
make observability-uninstall          # remove observability releases
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Ingress has no ADDRESS | Service not NodePort | Set `efficientai.web.service.type: NodePort` |
| ManagedCertificate `FailedNotVisible` | DNS not pointing at LB IP | Fix A record; recreate cert after DNS propagates |
| Cert `resourceInUseByAnotherResource` | Added domain to existing cert | Use separate ManagedCertificate per hostname |
| Grafana IP conflict on second Ingress | Two Ingress + two certs on same IP | Use grafana-proxy + single Ingress (Step 7) |
| Grafana 502 Server Error | grafana-proxy backend unhealthy | Re-apply `examples/gke/grafana-proxy.yaml` |
| Empty EfficientAI dashboards | Dashboards not bundled in k8s repo | Import JSON from app repo (Step 8) |
| No metrics in Grafana | ServiceMonitor missing | `make observability-servicemonitor` |
| No logs in Loki | App deployed before Loki | Restart web/worker pods after Loki is up |
| GCS 403 | Workload Identity binding wrong | KSA must be `[namespace/release]` matching Helm release |

## File reference

| File | Purpose |
|------|---------|
| [`examples/gke/values-gcs.yaml`](../examples/gke/values-gcs.yaml) | App values: GCS, observability config, GCE ingress |
| [`examples/gke/values-grafana-ingress.yaml`](../examples/gke/values-grafana-ingress.yaml) | Optional Helm overlay: Grafana hostname on app Ingress |
| [`examples/gke/managed-cert-app.yaml`](../examples/gke/managed-cert-app.yaml) | ManagedCertificate for app domain |
| [`examples/gke/grafana-proxy.yaml`](../examples/gke/grafana-proxy.yaml) | Nginx proxy + Grafana TLS cert |
| [`examples/gke/ingress-grafana.yaml`](../examples/gke/ingress-grafana.yaml) | Add Grafana host to app Ingress |
| [`examples/observability/loki.yaml`](../examples/observability/loki.yaml) | Loki Helm values |
| [`examples/observability/kube-prometheus-stack.yaml`](../examples/observability/kube-prometheus-stack.yaml) | Prometheus + Grafana Helm values |
| [`examples/observability/servicemonitor.yaml`](../examples/observability/servicemonitor.yaml) | Prometheus scrape config |
