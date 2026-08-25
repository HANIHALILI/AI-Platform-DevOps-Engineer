# Observability

This chart uses the official `kube-prometheus-stack`, `loki`, and `promtail`
charts as dependencies.

```sh
make deploy-monitoring
kubectl -n ai-platform port-forward svc/monitoring-grafana 3000:80
```

Grafana is available at <http://localhost:3000> with `admin` / `admin`. The
**Agent observability** dashboard shows pod CPU and memory, request rate, p95
TTFT, streaming latency, and Qdrant search latency.

Promtail sends stdout/stderr from all pods to Loki. In Grafana Explore, use:

```logql
{namespace="ai-platform", app="agent"} | json | request_id != "-"
```
