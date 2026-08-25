#!/usr/bin/env bash
# Checks the deployed stack against a live cluster. Run after `make deploy`.
set -euo pipefail

NS=${NAMESPACE:-ai-platform}

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

kubectl -n "$NS" rollout status deploy/ollama --timeout=600s \
  || fail "the ollama rollout did not complete"

# What the chart asked for: the tag it pulls, and the name it builds from it.
BASE=$(kubectl -n "$NS" get deploy ollama \
  -o jsonpath='{.spec.template.spec.initContainers[0].env[?(@.name=="BASE_MODEL")].value}')
SERVED=$(kubectl -n "$NS" get deploy ollama \
  -o jsonpath='{.spec.template.spec.initContainers[0].env[?(@.name=="SERVED")].value}')

# An empty BASE would leave the quantization pattern below matching any line that
# says "quantization", so the assertion has to fail here instead of passing.
test -n "$BASE" || fail "the ollama Deployment has no BASE_MODEL environment variable"

# `ollama show` proves agent-llm was built, and reports the quantization the
# weights carry, which has to be the one the tag asked for.
SHOW=$(kubectl -n "$NS" exec deploy/ollama -- ollama show "$SERVED") \
  || fail "$SERVED was not built from the Modelfile"
grep -qi "quantization.*${BASE##*-}" <<<"$SHOW" \
  || fail "$SERVED does not report the quantization $BASE asked for"

kubectl -n "$NS" exec deploy/agent -- printenv AGENT_LLM_MODEL | grep -qx "$SERVED" \
  || fail "the agent asks for a model ollama does not serve"

kubectl -n "$NS" exec deploy/agent -- printenv AGENT_QDRANT_URL >/dev/null \
  || fail "the ConfigMap did not reach the container"

kubectl -n "$NS" exec deploy/agent -- printenv AGENT_LLM_KEY >/dev/null \
  || fail "the Secret did not reach the container"

curl -fsS http://localhost:8080/healthz >/dev/null \
  || fail "/healthz did not answer on host :8080, the port kind maps to the NodePort"

echo "SMOKE OK"
