# GKE examples

Manifests and Helm values for EfficientAI on **GKE with GCS** and **GCE Ingress**.

Full guide: [`docs/gke-gcs-observability.md`](../../docs/gke-gcs-observability.md).

## Files

| File | Purpose |
|------|---------|
| `values-gcs.yaml` | Helm values: GCS, Workload Identity, observability config, app Ingress |
| `values-grafana-ingress.yaml` | Optional Helm overlay: Grafana host on same Ingress (instead of `ingress-grafana.yaml`) |
| `managed-cert-app.yaml` | Google-managed TLS cert for the app hostname |
| `grafana-proxy.yaml` | Nginx proxy + Grafana TLS cert + GCE health checks |
| `ingress-grafana.yaml` | Adds Grafana hostname to the existing app Ingress |

## Quick start

```bash
make observability-install
make observability-servicemonitor

cp examples/gke/values-gcs.yaml my-values.yaml   # customize domains, project, bucket
helm upgrade --install efficientai charts/efficientai -n efficientai -f my-values.yaml --wait

make observability-grafana-expose   # optional: public Grafana
```

Replace `gcp.example.com` and `grafana.gcp.example.com` in these files before applying.
