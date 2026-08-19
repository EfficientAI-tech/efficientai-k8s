#!/usr/bin/env bash
# kind-deploy.sh — Push local efficientai images to the kind local registry
# and helm install/upgrade the chart.
#
# Reuses existing in-cluster secrets on upgrade so they aren't rotated.
#
# Requires:
#   - kind cluster already up (run scripts/kind-up.sh first)
#   - local Docker images ghcr.io/efficientai-tech/efficientai-{api,worker}:$TAG
#
# Environment overrides:
#   NAMESPACE       (default: efficientai)
#   RELEASE         (default: dev)
#   TAG             (default: 1.3.9)
#   REG_PORT        (default: 5001)

set -euo pipefail

NAMESPACE="${NAMESPACE:-efficientai}"
RELEASE="${RELEASE:-dev}"
TAG="${TAG:-1.3.9}"
REG_PORT="${REG_PORT:-5001}"

echo "==> Tagging and pushing app images to localhost:${REG_PORT}..."
for img in efficientai-api efficientai-worker; do
  if ! docker image inspect "ghcr.io/efficientai-tech/$img:$TAG" >/dev/null 2>&1; then
    echo "!! Missing local image: ghcr.io/efficientai-tech/$img:$TAG"
    echo "   Either pull it from GHCR or build it locally first."
    exit 1
  fi
  docker tag  "ghcr.io/efficientai-tech/$img:$TAG" "localhost:${REG_PORT}/$img:$TAG"
  docker push "localhost:${REG_PORT}/$img:$TAG"
done

echo
echo "==> Resolving secrets (reuse existing, generate fresh on first install)..."
existing_secret() {
  kubectl -n "$NAMESPACE" get secret "${RELEASE}-efficientai-secrets" \
    -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d 2>/dev/null || true
}
existing_pg() {
  kubectl -n "$NAMESPACE" get secret "${RELEASE}-postgresql" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true
}

SECRET_KEY=$(existing_secret SECRET_KEY)
ENCRYPTION_KEY=$(existing_secret ENCRYPTION_KEY)
POSTGRES_PASSWORD=$(existing_pg)

[ -z "$SECRET_KEY" ]        && SECRET_KEY=$(openssl rand -hex 32)
[ -z "$ENCRYPTION_KEY" ]    && ENCRYPTION_KEY=$(openssl rand -hex 32)
[ -z "$POSTGRES_PASSWORD" ] && POSTGRES_PASSWORD=$(openssl rand -hex 16)

echo "    SECRET_KEY        length: ${#SECRET_KEY}"
echo "    ENCRYPTION_KEY    length: ${#ENCRYPTION_KEY}"
echo "    POSTGRES_PASSWORD length: ${#POSTGRES_PASSWORD}"

echo
echo "==> helm dependency update + upgrade --install..."
helm dependency update charts/efficientai
helm upgrade --install "$RELEASE" charts/efficientai \
  -n "$NAMESPACE" --create-namespace \
  --set efficientai.image.registry="localhost:${REG_PORT}" \
  --set efficientai.image.api.repository="efficientai-api" \
  --set efficientai.image.api.tag="$TAG" \
  --set efficientai.image.worker.repository="efficientai-worker" \
  --set efficientai.image.worker.tag="$TAG" \
  --set efficientai.secretKey.value="$SECRET_KEY" \
  --set efficientai.encryptionKey.value="$ENCRYPTION_KEY" \
  --set postgresql.auth.password="$POSTGRES_PASSWORD" \
  --set s3.enabled=false

echo
echo "==> Waiting for rollouts (up to 5 minutes each)..."
kubectl -n "$NAMESPACE" rollout status statefulset/${RELEASE}-postgresql            --timeout=300s || true
kubectl -n "$NAMESPACE" rollout status statefulset/${RELEASE}-redis-master          --timeout=300s || true
kubectl -n "$NAMESPACE" rollout status deployment/${RELEASE}-efficientai-web        --timeout=300s || true
kubectl -n "$NAMESPACE" rollout status deployment/${RELEASE}-efficientai-worker     --timeout=300s || true
kubectl -n "$NAMESPACE" rollout status deployment/${RELEASE}-efficientai-worker-imports --timeout=300s || true
kubectl -n "$NAMESPACE" rollout status deployment/${RELEASE}-efficientai-beat          --timeout=300s || true
kubectl -n "$NAMESPACE" rollout status deployment/${RELEASE}-efficientai-worker-usage   --timeout=300s || true

echo
echo "==> Final state:"
kubectl -n "$NAMESPACE" get pods,svc

echo
echo "==> Open the API in your browser:"
echo "    kubectl -n $NAMESPACE port-forward svc/${RELEASE}-efficientai-web 8000:8000"
echo "    open http://localhost:8000/docs"
