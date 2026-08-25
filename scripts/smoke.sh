#!/usr/bin/env bash
# Checks the deployed stack against a live cluster. Run after `make deploy`.
set -euo pipefail

NS=${NAMESPACE:-ai-platform}

fail() { echo "FAILED: $1" >&2; exit 1; }
value() { kubectl -n "$NS" get "$1" "$2" -o "jsonpath=$3"; }

test "$(kubectl get nodes --no-headers | grep -cw Ready)" = 3 \
  || fail "expected 3 Ready nodes"

test "$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers | grep -cw Ready)" = 1 \
  || fail "expected 1 Ready control-plane node"

test "$(kubectl get nodes -l workload=agent --no-headers | grep -cw Ready)" = 2 \
  || fail "expected 2 Ready worker nodes"

kubectl -n "$NS" rollout status deploy/agent --timeout=180s \
  || fail "the agent rollout did not complete"
kubectl -n "$NS" rollout status deploy/ollama --timeout=600s \
  || fail "the Ollama rollout did not complete"
kubectl -n "$NS" rollout status statefulset/qdrant --timeout=180s \
  || fail "the Qdrant rollout did not complete"

test "$(kubectl -n "$NS" get pods -l app=agent \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l)" = 2 \
  || fail "agent Pods are not spread across both workers"

value deploy agent '{.spec.template.spec.containers[0].image}' | grep -q '^localhost:5001/agent:' \
  || fail "the agent image is not from the local registry"

kubectl -n "$NS" exec deploy/agent -- id | grep -q uid=10001 \
  || fail "the container is not running as uid 10001"

! kubectl -n "$NS" exec deploy/agent -- touch /x 2>/dev/null \
  || fail "the root filesystem is writable"

kubectl -n "$NS" exec deploy/agent -- printenv AGENT_QDRANT_URL >/dev/null \
  || fail "the ConfigMap did not reach the container"

kubectl -n "$NS" exec deploy/agent -- printenv AGENT_LLM_KEY >/dev/null \
  || fail "the Secret did not reach the container"

test "$(value hpa agent '{.spec.metrics[0].resource.target.averageUtilization}')" = 70 \
  || fail "the agent HPA is not targeting 70% CPU"

test "$(value svc agent '{.spec.type}')" = NodePort \
  || fail "the agent Service is not NodePort"
test "$(value svc ollama '{.spec.type}')" = ClusterIP \
  || fail "the Ollama Service is not ClusterIP"
test "$(value svc qdrant '{.spec.type}')" = ClusterIP \
  || fail "the Qdrant Service is not ClusterIP"

test "$(value deploy ollama '{.spec.template.spec.containers[0].livenessProbe.httpGet.path}')" = /api/tags \
  || fail "the Ollama liveness probe is missing"
test "$(value deploy ollama '{.spec.template.spec.containers[0].readinessProbe.httpGet.path}')" = /api/tags \
  || fail "the Ollama readiness probe is missing"
value deploy ollama '{.spec.template.spec.containers[0].resources.limits.cpu}' | grep -q . \
  || fail "the Ollama CPU limit is missing"

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

curl -fsS http://localhost:8080/healthz >/dev/null \
  || fail "/healthz did not answer on host :8080, the port kind maps to the NodePort"
curl -fsS http://localhost:8080/metrics | grep -q chat_requests_total \
  || fail "/metrics did not expose the agent metrics"

kubectl -n "$NS" rollout status deploy/monitoring-grafana --timeout=180s \
  || fail "the Grafana rollout did not complete"
kubectl -n "$NS" rollout status statefulset/prometheus-monitoring-kube-prometheus-prometheus --timeout=180s \
  || fail "the Prometheus rollout did not complete"
kubectl -n "$NS" rollout status statefulset/monitoring-loki --timeout=180s \
  || fail "the Loki rollout did not complete"
kubectl -n "$NS" rollout status daemonset/monitoring-promtail --timeout=180s \
  || fail "the Promtail rollout did not complete"
test "$(value daemonset monitoring-promtail '{.status.numberReady}')" = 3 \
  || fail "Promtail is not running on every node"
kubectl -n "$NS" get servicemonitor/agent configmap/agent-observability-dashboard >/dev/null \
  || fail "the agent ServiceMonitor or the dashboard is missing"

echo "SMOKE OK"
