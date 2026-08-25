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
kubectl -n "$NS" rollout status deploy/ollama --timeout=180s \
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

kubectl -n "$NS" get configmap/agent-config secret/agent-secrets >/dev/null \
  || fail "the agent ConfigMap or Secret is missing"
value deploy agent '{.spec.template.spec.containers[0].envFrom[*].configMapRef.name}' | grep -qw agent-config \
  || fail "the ConfigMap is not referenced by the agent"
value deploy agent '{.spec.template.spec.containers[0].envFrom[*].secretRef.name}' | grep -qw agent-secrets \
  || fail "the Secret is not referenced by the agent"

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
value deploy ollama '{.spec.template.spec.initContainers[0].env[0].value}' | grep -q '^llama3.2:3b-instruct-q4_K_M$' \
  || fail "the configured Ollama model is missing"

curl -fsS http://localhost:8080/healthz >/dev/null \
  || fail "/healthz did not answer on host :8080, the port kind maps to the NodePort"
curl -fsS http://localhost:8080/metrics | grep -q chat_requests_total \
  || fail "/metrics did not expose the agent metrics"

kubectl -n "$NS" rollout status deploy/monitoring-grafana --timeout=180s \
  || fail "the Grafana rollout did not complete"
kubectl -n "$NS" rollout status statefulset/monitoring-kube-prometheus-prometheus --timeout=180s \
  || fail "the Prometheus rollout did not complete"
kubectl -n "$NS" rollout status statefulset/monitoring-loki --timeout=180s \
  || fail "the Loki rollout did not complete"
kubectl -n "$NS" rollout status daemonset/monitoring-promtail --timeout=180s \
  || fail "the Promtail rollout did not complete"
test "$(value daemonset monitoring-promtail '{.status.numberReady}')" = 3 \
  || fail "Promtail is not running on every node"
kubectl -n "$NS" get servicemonitor/agent servicemonitor/ollama \
  configmap/agent-observability-dashboard >/dev/null \
  || fail "the monitoring ServiceMonitors or dashboard are missing"

echo "SMOKE OK"
