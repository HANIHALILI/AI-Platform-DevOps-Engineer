#!/usr/bin/env bash
# End-to-end acceptance checks for the cluster, registry, image and rollout.
# Prints the real output of every check and exits non-zero on the first failure.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-agent-cluster}"
REGISTRY_NAME="${REGISTRY_NAME:-kind-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
KIND_NETWORK="${KIND_NETWORK:-kind}"
IMAGE="${IMAGE:-localhost:${REGISTRY_PORT}/agent}"
IMAGE_TAG="${IMAGE_TAG:-dev}"
MAX_IMAGE_MB="${MAX_IMAGE_MB:-250}"
NAMESPACE="${NAMESPACE:-default}"

step() { echo; echo "=== $* ==="; }
fail() { echo "SMOKE FAIL — $*" >&2; exit 1; }

# 1 -------------------------------------------------------------------------
step "1. Topology: 1 control-plane + 2 workers, all Ready"
kubectl get nodes -o wide
ready_count="$(kubectl get nodes --no-headers | awk '$2 ~ /(^|,)Ready($|,)/' | wc -l | tr -d ' ')"
[ "${ready_count}" -eq 3 ] || fail "expected 3 Ready nodes, found ${ready_count}"

# 2 -------------------------------------------------------------------------
step "2. Registry alive and reachable from the host"
curl -fsS "http://localhost:${REGISTRY_PORT}/v2/_catalog" || fail "registry catalog unreachable"
echo

# 3 -------------------------------------------------------------------------
step "3. Registry is attached to the cluster network"
containers="$(docker network inspect "${KIND_NETWORK}" -f '{{range .Containers}}{{.Name}} {{end}}')"
echo "${containers}"
echo "${containers}" | grep -q "${REGISTRY_NAME}" \
  || fail "${REGISTRY_NAME} is not on docker network ${KIND_NETWORK}"

# 4 -------------------------------------------------------------------------
step "4. containerd mirror is configured on a worker node"
docker exec "${CLUSTER_NAME}-worker" cat "/etc/containerd/certs.d/localhost:${REGISTRY_PORT}/hosts.toml" \
  || fail "hosts.toml missing on ${CLUSTER_NAME}-worker"

# 5 -------------------------------------------------------------------------
step "5. Image is non-root, small, and free of build toolchain"
image_user="$(docker image inspect "${IMAGE}:${IMAGE_TAG}" --format '{{.Config.User}}')"
echo "USER = ${image_user}"
[ "${image_user}" = "10001:10001" ] || fail "image USER is '${image_user}', expected '10001:10001'"

docker image ls "${IMAGE}:${IMAGE_TAG}"
size_bytes="$(docker image inspect "${IMAGE}:${IMAGE_TAG}" --format '{{.Size}}')"
size_mb=$(( size_bytes / 1000 / 1000 ))
echo "size = ${size_mb} MB (limit ${MAX_IMAGE_MB} MB)"
[ "${size_mb}" -lt "${MAX_IMAGE_MB}" ] || fail "image is ${size_mb} MB, over the ${MAX_IMAGE_MB} MB budget"

echo "--- docker history ---"
docker history "${IMAGE}:${IMAGE_TAG}" | head -20

# uv must not have leaked into the runtime stage.
if docker run --rm --entrypoint sh "${IMAGE}:${IMAGE_TAG}" -c 'command -v uv' >/dev/null 2>&1; then
  fail "uv is present in the runtime image"
fi
echo "uv absent from runtime image — ok"

# 6 -------------------------------------------------------------------------
step "6. Cluster pulls from the registry and spreads across workers"
kubectl -n "${NAMESPACE}" rollout status deploy/agent --timeout=180s
kubectl -n "${NAMESPACE}" get pods -l app=agent -o wide
distinct_nodes="$(kubectl -n "${NAMESPACE}" get pods -l app=agent \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l | tr -d ' ')"
echo "distinct nodes hosting Agent service pods: ${distinct_nodes}"
[ "${distinct_nodes}" -eq 2 ] || fail "expected 2 distinct nodes, found ${distinct_nodes}"
kubectl -n "${NAMESPACE}" describe pod -l app=agent | grep -iE "pulled|image:" || true

# 7 -------------------------------------------------------------------------
step "7. Hardening actually holds"
id_out="$(kubectl -n "${NAMESPACE}" exec deploy/agent -- id)"
echo "${id_out}"
echo "${id_out}" | grep -q "uid=10001" || fail "container is not running as uid 10001"

echo "--- touch /x must FAIL (read-only root filesystem) ---"
if kubectl -n "${NAMESPACE}" exec deploy/agent -- touch /x 2>&1; then
  fail "touch /x succeeded — the root filesystem is writable"
fi
echo "touch /x was rejected — ok"

echo "--- /tmp must be writable (emptyDir) ---"
kubectl -n "${NAMESPACE}" exec deploy/agent -- touch /tmp/probe \
  || fail "/tmp is not writable — the app cannot use scratch space"
echo "/tmp is writable — ok"

# 8 -------------------------------------------------------------------------
step "8. App responds in-cluster"
kubectl -n "${NAMESPACE}" run curl-smoke --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 -- \
  curl -fsS "http://agent.${NAMESPACE}.svc.cluster.local/healthz" \
  || fail "in-cluster GET /healthz failed"
echo

echo
echo "=== SMOKE TEST PASSED ==="
