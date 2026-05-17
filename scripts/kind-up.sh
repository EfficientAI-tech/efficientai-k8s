#!/usr/bin/env bash
# kind-up.sh — Spin up a local Docker registry + kind cluster wired to use it.
# Based on the official kind docs: https://kind.sigs.k8s.io/docs/user/local-registry/
#
# This makes `localhost:5001/*` images pullable from inside the kind cluster,
# which avoids the multi-manifest issues of `kind load docker-image` and
# bypasses any auth-required upstream registries.
#
# Re-runs of this script are idempotent: existing registry container is reused,
# existing cluster is recreated.

set -euo pipefail

CLUSTER="${CLUSTER:-efficientai}"
REG_NAME="${REG_NAME:-kind-registry}"
REG_PORT="${REG_PORT:-5001}"

echo "==> 0. Tearing down any existing kind cluster '${CLUSTER}'..."
kind delete cluster --name "$CLUSTER" 2>/dev/null || true

echo "==> 1. Starting local Docker registry on localhost:${REG_PORT}..."
if [ "$(docker inspect -f '{{.State.Running}}' "$REG_NAME" 2>/dev/null || true)" != 'true' ]; then
  docker rm -f "$REG_NAME" 2>/dev/null || true
  docker run -d --restart=always \
    -p "127.0.0.1:${REG_PORT}:5000" \
    --name "$REG_NAME" \
    registry:2
fi

echo "==> 2. Creating kind cluster with containerd hosts.toml support..."
cat <<EOF | kind create cluster --name "$CLUSTER" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
EOF

echo "==> 3. Wiring hosts.toml inside each kind node..."
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REG_PORT}"
for node in $(kind get nodes --name "$CLUSTER"); do
  docker exec "$node" mkdir -p "${REGISTRY_DIR}"
  cat <<EOF | docker exec -i "$node" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."http://${REG_NAME}:5000"]
EOF
done

echo "==> 4. Connecting registry to kind's docker network..."
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "$REG_NAME")" = 'null' ]; then
  docker network connect "kind" "$REG_NAME"
fi

echo "==> 5. Publishing local-registry-hosting ConfigMap..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REG_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

echo
echo "==> Done. kind cluster '${CLUSTER}' is up, registry: localhost:${REG_PORT}"
echo "    Next: make kind-deploy   (push images + helm install)"
