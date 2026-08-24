#!/usr/bin/env bash
# Checks the deployed stack against a live cluster. Run after `make deploy`.
set -euo pipefail

NS=${NAMESPACE:-default}

fail() { echo "FAILED: $1" >&2; exit 1; }

test "$(kubectl get nodes --no-headers | grep -cw Ready)" = 3 \
  || fail "expected 3 Ready nodes"

# The registry and the containerd mirror need no check of their own: if either
# were broken the Pods could not pull the image and this would hang.
kubectl -n "$NS" rollout status deploy/agent --timeout=180s \
  || fail "the agent rollout did not complete"

test "$(kubectl -n "$NS" get pods -l app=agent \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l)" = 2 \
  || fail "agent Pods are not spread across both workers"

kubectl -n "$NS" exec deploy/agent -- id | grep -q uid=10001 \
  || fail "the container is not running as uid 10001"

! kubectl -n "$NS" exec deploy/agent -- touch /x 2>/dev/null \
  || fail "the root filesystem is writable"

kubectl -n "$NS" exec deploy/agent -- printenv AGENT_QDRANT_URL >/dev/null \
  || fail "the ConfigMap did not reach the container"

kubectl -n "$NS" exec deploy/agent -- printenv AGENT_LLM_KEY >/dev/null \
  || fail "the Secret did not reach the container"

curl -fsS http://localhost:8080/healthz >/dev/null \
  || fail "/healthz did not answer on host :8080, the port kind maps to the NodePort"

echo "SMOKE OK"
