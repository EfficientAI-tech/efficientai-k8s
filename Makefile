CHART_DIR := charts/efficientai
RELEASE   ?= dev
NAMESPACE ?= efficientai

.PHONY: help deps lint template unittest install upgrade uninstall clean kind-up kind-deploy kind-down

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
