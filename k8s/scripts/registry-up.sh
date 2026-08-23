#!/usr/bin/env bash
# Create and verify the local container registry.
#
# The registry lives outside the cluster on purpose: `kind delete cluster` then
# leaves it — and every cached image layer — untouched. It starts on the default
# bridge network; cluster-up.sh attaches it to kind's network once that exists.
#
# Idempotent: a second run is a no-op that still exits 0.
set -euo pipefail

REGISTRY_NAME="${REGISTRY_NAME:-kind-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
# Pinned by tag and digest — never `latest`.
REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:3@sha256:1be55279f18a2fe1a74edf2664cac61c1bea305b7b4642dab412e7affdcb3e33}"

log() { echo "registry-up: $*"; }

# --- create (idempotent) ----------------------------------------------------
if [ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || echo missing)" = "true" ]; then
  log "registry '${REGISTRY_NAME}' already running — skipping create"
elif docker inspect "${REGISTRY_NAME}" >/dev/null 2>&1; then
  log "registry '${REGISTRY_NAME}' exists but is stopped — starting it"
  docker start "${REGISTRY_NAME}" >/dev/null
else
  log "creating registry '${REGISTRY_NAME}' on 127.0.0.1:${REGISTRY_PORT}"
  # Bound to 127.0.0.1 only: an unauthenticated registry must not be reachable
  # from the network.
  docker run -d --restart=always \
    --name "${REGISTRY_NAME}" \
    --network bridge \
    -p "127.0.0.1:${REGISTRY_PORT}:5000" \
    "${REGISTRY_IMAGE}" >/dev/null
fi

# --- verify it answers ------------------------------------------------------
for attempt in $(seq 1 10); do
  if curl -fsS "http://localhost:${REGISTRY_PORT}/v2/_catalog" >/dev/null 2>&1; then
    log "registry API responds: $(curl -fsS "http://localhost:${REGISTRY_PORT}/v2/_catalog")"
    exit 0
  fi
  log "waiting for the registry API (attempt ${attempt}/10)"
  sleep 2
done

echo "registry-up: FAIL — http://localhost:${REGISTRY_PORT}/v2/_catalog did not respond" >&2
echo "  inspect with: docker logs ${REGISTRY_NAME}" >&2
exit 1
