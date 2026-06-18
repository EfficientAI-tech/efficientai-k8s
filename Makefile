CHART_DIR := charts/efficientai
RELEASE   ?= dev
NAMESPACE ?= efficientai

OBS_NAMESPACE ?= observability

.PHONY: help deps lint template unittest install upgrade uninstall clean kind-up kind-deploy kind-down \
	observability-repos observability-install observability-uninstall observability-servicemonitor \
	observability-grafana-expose

help:
	@echo "Chart targets:"
	@echo "  deps         - helm dependency update for $(CHART_DIR)"
	@echo "  lint         - helm lint $(CHART_DIR)"
	@echo "  template     - helm template $(RELEASE) $(CHART_DIR)"
	@echo "  unittest     - helm unittest $(CHART_DIR) (requires helm-unittest plugin)"
	@echo "  install      - helm install $(RELEASE) $(CHART_DIR) -n $(NAMESPACE) --create-namespace"
	@echo "  upgrade      - helm upgrade --install $(RELEASE) $(CHART_DIR) -n $(NAMESPACE)"
	@echo "  uninstall    - helm uninstall $(RELEASE) -n $(NAMESPACE)"
	@echo "  clean        - remove downloaded subchart archives + Chart.lock"
	@echo ""
	@echo "Observability (GKE):"
	@echo "  observability-repos          - add prometheus-community + grafana helm repos"
	@echo "  observability-install        - install Loki + kube-prometheus-stack in $(OBS_NAMESPACE)"
	@echo "  observability-servicemonitor   - apply EfficientAI /metrics ServiceMonitor"
	@echo "  observability-grafana-expose - nginx proxy + Ingress patch for public Grafana"
	@echo "  observability-uninstall      - remove observability helm releases"
	@echo ""
	@echo "GKE guide: docs/gke-gcs-observability.md"
	@echo ""
	@echo "Local kind dev workflow (uses scripts/):"
	@echo "  kind-up      - create kind cluster + local registry on localhost:5001"
	@echo "  kind-deploy  - push local images + helm upgrade --install"
	@echo "  kind-down    - tear down kind cluster + local registry"

deps:
	helm dependency update $(CHART_DIR)

lint: deps
	helm lint $(CHART_DIR)

template: deps
	helm template $(RELEASE) $(CHART_DIR)

unittest:
	helm unittest $(CHART_DIR) --color

install: deps
	helm install $(RELEASE) $(CHART_DIR) -n $(NAMESPACE) --create-namespace

upgrade: deps
	helm upgrade --install $(RELEASE) $(CHART_DIR) -n $(NAMESPACE) --create-namespace

uninstall:
	helm uninstall $(RELEASE) -n $(NAMESPACE)

clean:
	rm -rf $(CHART_DIR)/charts/*.tgz $(CHART_DIR)/Chart.lock

kind-up:
	bash scripts/kind-up.sh

kind-deploy:
	bash scripts/kind-deploy.sh

kind-down:
	kind delete cluster --name $${CLUSTER:-efficientai} 2>/dev/null || true
	docker rm -f $${REG_NAME:-kind-registry} 2>/dev/null || true

observability-repos:
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo add grafana https://grafana.github.io/helm-charts
	helm repo update

observability-install: observability-repos
	kubectl create namespace $(OBS_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install loki grafana/loki-stack \
		-n $(OBS_NAMESPACE) \
		-f examples/observability/loki.yaml \
		--wait --timeout 15m
	helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
		-n $(OBS_NAMESPACE) \
		-f examples/observability/kube-prometheus-stack.yaml \
		--wait --timeout 15m

observability-servicemonitor:
	kubectl apply -f examples/observability/servicemonitor.yaml

observability-grafana-expose:
	kubectl apply -f examples/gke/grafana-proxy.yaml
	kubectl apply -f examples/gke/ingress-grafana.yaml

observability-uninstall:
	helm uninstall kube-prometheus -n $(OBS_NAMESPACE) 2>/dev/null || true
	helm uninstall loki -n $(OBS_NAMESPACE) 2>/dev/null || true
