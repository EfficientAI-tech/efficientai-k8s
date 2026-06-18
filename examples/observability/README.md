# Observability

Helm values and manifests for **Loki**, **Prometheus**, and **Grafana** alongside EfficientAI.

Used by the GKE guide: [`docs/gke-gcs-observability.md`](../../docs/gke-gcs-observability.md).

## Files

| File | Installed by |
|------|----------------|
| `loki.yaml` | `make observability-install` |
| `kube-prometheus-stack.yaml` | `make observability-install` |
| `servicemonitor.yaml` | `make observability-servicemonitor` |

GKE Ingress manifests for public Grafana live in [`../gke/`](../gke/) (`grafana-proxy.yaml`, `ingress-grafana.yaml`).

## Quick start

```bash
make observability-install
make observability-servicemonitor

helm upgrade --install efficientai charts/efficientai -n efficientai \
  -f examples/gke/values-gcs.yaml --wait
```

## Dashboards

kube-prometheus-stack includes generic Kubernetes dashboards. Import EfficientAI dashboards from the main app repo: `observability/grafana/dashboards/`.

## Grafana login

```bash
kubectl -n observability get secret kube-prometheus-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

Default in values is `changeme`; Helm may have generated a random password on first install.
