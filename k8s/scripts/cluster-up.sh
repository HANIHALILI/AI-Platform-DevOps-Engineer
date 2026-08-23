#!/usr/bin/env bash
# Create the kind cluster, wire the registry into it, and make the topology
# legible in `kubectl get nodes`.
#
# Idempotent: an existing cluster is re-wired and re-labelled, not recreated.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-agent-cluster}"
KIND_CONFIG="${KIND_CONFIG:-k8s/kind-config.yaml}"
REGISTRY_NAME="${REGISTRY_NAME:-kind-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
# Node images are built per kind release; the digest is mandatory to get the
# image that matches this kind version. From the kind v0.32.0 release notes.
NODE_IMAGE="${NODE_IMAGE:-kindest/node:v1.34.8@sha256:02722c2dedddcfc00febf5d27fbeb9b7b2c14294c82109ff4a85d89ac9ba3256}"
# kind always uses a docker network literally named "kind", regardless of the
# cluster name.
KIND_NETWORK="${KIND_NETWORK:-kind}"
NODE_READY_TIMEOUT_SECONDS="${NODE_READY_TIMEOUT_SECONDS:-180}"

log() { echo "cluster-up: $*"; }

[ -f "${KIND_CONFIG}" ] || { echo "cluster-up: FAIL — ${KIND_CONFIG} not found" >&2; exit 1; }

# --- 1. create the cluster (idempotent) -------------------------------------
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  log "cluster '${CLUSTER_NAME}' already exists — skipping create"
else
  log "creating cluster '${CLUSTER_NAME}' from ${KIND_CONFIG}"
  kind create cluster \
    --name "${CLUSTER_NAME}" \
    --config "${KIND_CONFIG}" \
    --image "${NODE_IMAGE}" \
    --wait "${NODE_READY_TIMEOUT_SECONDS}s"
fi

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
log "kubectl context: $(kubectl config current-context)"

# --- 2. point containerd at the registry on every node ----------------------
# kind-config.yaml set config_path=/etc/containerd/certs.d; this is the per-node
# hosts.toml it reads. Nodes reach the registry as ${REGISTRY_NAME}:5000 over
# the kind network, while the host reaches it as localhost:${REGISTRY_PORT} —
# both under the same image reference.
registry_dir="/etc/containerd/certs.d/localhost:${REGISTRY_PORT}"
for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  docker exec "${node}" mkdir -p "${registry_dir}"
  docker exec -i "${node}" cp /dev/stdin "${registry_dir}/hosts.toml" <<EOF
[host."http://${REGISTRY_NAME}:5000"]
EOF
done
log "containerd mirror written on $(kind get nodes --name "${CLUSTER_NAME}" | wc -l | tr -d ' ') node(s)"

# --- 3. attach the registry to the cluster network --------------------------
if [ "$(docker inspect -f "{{json .NetworkSettings.Networks.${KIND_NETWORK}}}" "${REGISTRY_NAME}" 2>/dev/null || echo null)" = "null" ]; then
  log "attaching '${REGISTRY_NAME}' to docker network '${KIND_NETWORK}'"
  docker network connect "${KIND_NETWORK}" "${REGISTRY_NAME}"
else
  log "'${REGISTRY_NAME}' already attached to '${KIND_NETWORK}'"
fi

# --- 4. wait for nodes, then label the workers ------------------------------
kubectl wait --for=condition=Ready nodes --all --timeout="${NODE_READY_TIMEOUT_SECONDS}s"

# NodeRestriction forbids kubelet from self-assigning node-role.kubernetes.io/*
# labels, so workers come up with ROLES=<none>. Applying the label from outside
# afterwards is the supported way to make the topology readable.
mapfile -t workers < <(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

[ "${#workers[@]}" -gt 0 ] || { echo "cluster-up: FAIL — no worker nodes found" >&2; kubectl get nodes -o wide >&2; exit 1; }

log "labelling ${#workers[@]} worker(s): ${workers[*]}"
kubectl label node "${workers[@]}" node-role.kubernetes.io/worker=true --overwrite >/dev/null
# workload=agent normally arrives from kind-config.yaml; assert it rather than
# assume it, since the Agent service's nodeSelector depends on it.
kubectl label node "${workers[@]}" workload=agent --overwrite >/dev/null

# --- 5. advertise the registry to tooling in the cluster --------------------
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

kubectl get nodes -o wide
log "cluster '${CLUSTER_NAME}' is ready"
