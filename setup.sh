#!/usr/bin/env bash
set -Eeuo pipefail

readonly CLUSTER_NAME="demo"
readonly RELEASE_NAME="demo"
readonly NAMESPACE="demo"
readonly IMAGE_REPOSITORY="demo-service"
readonly IMAGE_TAG="1.0.0"
readonly INGRESS_NGINX_VERSION="controller-v1.15.1"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command '$1' was not found in PATH" >&2
    exit 1
  fi
}

for command_name in docker kind kubectl helm; do
  require_command "$command_name"
done

if ! docker info >/dev/null 2>&1; then
  echo "error: Docker is installed but its daemon is not running" >&2
  exit 1
fi

if kind get clusters 2>/dev/null | grep -Fxq "$CLUSTER_NAME"; then
  echo "==> Reusing kind cluster '$CLUSTER_NAME'"
else
  echo "==> Creating kind cluster '$CLUSTER_NAME'"
  kind create cluster --name "$CLUSTER_NAME" --config=- <<'KIND_CONFIG'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
KIND_CONFIG
fi

kind export kubeconfig --name "$CLUSTER_NAME"
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

echo "==> Installing ingress-nginx ${INGRESS_NGINX_VERSION}"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"
kubectl --namespace ingress-nginx rollout status \
  deployment/ingress-nginx-controller --timeout=300s

echo "==> Building ${IMAGE_REPOSITORY}:${IMAGE_TAG}"
docker build --tag "${IMAGE_REPOSITORY}:${IMAGE_TAG}" "${SCRIPT_DIR}/service"

echo "==> Loading image into kind"
kind load docker-image "${IMAGE_REPOSITORY}:${IMAGE_TAG}" --name "$CLUSTER_NAME"

echo "==> Installing Helm release '${RELEASE_NAME}'"
helm_upgrade_extra_args=()
if helm upgrade --help 2>&1 | grep -q -- '--force-conflicts'; then
  helm_upgrade_extra_args+=(--force-conflicts)
fi

for attempt in 1 2 3; do
  if helm upgrade --install "$RELEASE_NAME" "${SCRIPT_DIR}/chart" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --set-string "image.repository=${IMAGE_REPOSITORY}" \
    --set-string "image.tag=${IMAGE_TAG}" \
    --wait \
    --timeout 3m \
    "${helm_upgrade_extra_args[@]}"; then
    break
  fi

  if [[ "$attempt" == "3" ]]; then
    echo "error: Helm installation failed after ${attempt} attempts" >&2
    exit 1
  fi

  echo "Helm attempt ${attempt} failed; waiting for admission webhook readiness"
  sleep 5
done

kubectl --namespace "$NAMESPACE" rollout status \
  "deployment/${RELEASE_NAME}-demo-service" --timeout=120s

echo
echo "Setup complete. Verify with:"
echo "  curl --resolve demo.local:80:127.0.0.1 http://demo.local/"
echo "  curl --resolve demo.local:80:127.0.0.1 http://demo.local/healthz"
