# agent-service

A FastAPI service with a streaming `/chat` endpoint. A LangGraph agent decides when to call its two
tools — a Qdrant document search and a clock. It runs on a local kind cluster with Ollama as the
inference server and Qdrant as the vector store, one Helm chart each under `k8s/`.

`app/SPEC.md` describes the service; `app/app/config.py` lists every setting it reads.
`k8s/ollama/README.md` covers the inference tier — the quantized model it serves, what is tunable,
and how to measure it. `k8s/argocd/README.md` covers the GitOps flow.

## Without a cluster

Runs the service against a mock LLM, with Qdrant pointed at a closed port so the search tool takes
its failure path. Needs uv and Python 3.12.

```sh
cd app
./scripts/validate.sh
```

Five requests through `/chat` — plain answer, search with Qdrant down, clock, tool error, iteration
limit — then health, readiness and metrics. `uv run pytest` runs the unit tests.

## On kind

The Makefile needs Linux. Docker, kind, kubectl and helm
have to be on your PATH — `make deps` checks for all four and names whatever is missing.

```sh
make up      # local registry, 3-node cluster, metrics-server
make all     # the same, plus the image release and Argo CD
```

`make deploy` installs Qdrant, Ollama, the agent and monitoring with Helm, bypassing Argo CD. The
application order matters. The agent's `/readyz` returns 503 while the LLM is unreachable, so its
rollout will not finish until Ollama is Ready — and Ollama's first start downloads ~2GB of models in
an init container, then builds the model the agent calls from a Modelfile, before it serves anything
(`kubectl logs -f -l app=ollama -c pull-models`). The models sit on a PVC, so later restarts skip
the download.

`make gitops` installs Argo CD and gives each of the four charts an Application that watches `main`,
syncs, prunes and self-heals — so a chart edited by hand, or a `make deploy-agent` from the inner
loop, is pulled back on the next sync. A new image is not a chart change and needs a commit of its
own: that is `make release`.

For the inner loop, each piece has its own target:

```sh
make build push deploy-agent     # rebuild the image and roll just the agent
make deploy-qdrant               # or deploy-ollama
```

To check the result, or to tear it down:

```sh
make smoke     # deployment, security and monitoring checks
make bench     # startup, memory, tokens/sec against the deployed Ollama
make down      # delete the cluster; make clean also drops the registry
```

## Calling it

Open <http://localhost:8080/> for the browser UI. Drop a `.md` or `.txt` file on the left panel and
it is chunked, embedded and stored in Qdrant, which is what `search_docs` reads — no indexing script
and no port-forward. Every SSE frame the answer arrives in is rendered as it lands: tool calls with
their arguments, tool results with success or failure, tokens as they stream, and the terminal
`done` or `error`. Each turn also keeps the raw `data:` lines, timestamped, behind a toggle.

The page is served by the service itself at `GET /`, so it needs no Deployment, Service or Ingress
of its own and calls `/chat` same-origin.

The agent's Service is a NodePort on 30080, which `k8s/kind-config.yaml` maps to host port 8080 — so
it answers directly, with no port-forward:

```sh
curl -N -X POST http://localhost:8080/chat \
  -H 'Content-Type: application/json' \
  -d '{"message": "what time is it in Asia/Jerusalem?"}'
```

`-N` matters — without it curl buffers and the stream looks broken. The response is SSE: one JSON
object per `data:` line, typed `token`, `tool_call`, `tool_result`, `done` or `error`. There is also
`POST /documents` (multipart, one file per request, 2 MB), `GET /healthz`, `GET /readyz` and
`GET /metrics`.

Ollama and Qdrant stay ClusterIP; they are only ever called from inside the cluster. Reach them with
`kubectl port-forward` when you need to. `--set service.type=ClusterIP` puts the agent behind one
too.

## Configuration

Every setting comes from the environment with an `AGENT_` prefix and has a default. In the cluster,
non-secret values go under `config:` in `k8s/agent/values.yaml` and are rendered into a ConfigMap;
sensitive ones go under `secrets:` and are rendered into a Secret. Both reach the container through
`envFrom`, and a change to either rolls the Pods through a checksum annotation.

The two connection strings live in the ConfigMap — `AGENT_LLM_URL` and `AGENT_EMBED_URL` pointing at
the Ollama Service, `AGENT_QDRANT_URL` at the Qdrant one — alongside the model names.
`AGENT_LLM_MODEL` is `model.servedAs` from `k8s/ollama/values.yaml` and not a base model: Ollama
builds that model from a Modelfile, so the weights and the quantization behind it change there
without this value moving. `AGENT_EMBED_MODEL` is `embedModel` in the same file, pulled as-is and so
spelled the same in both. The two credentials, `AGENT_LLM_KEY` and
`AGENT_QDRANT_KEY`, live in the Secret. Their committed values are placeholders for a local cluster
that authenticates neither service; pass real ones at install time:

```sh
helm upgrade --install agent k8s/agent --set-string secrets.AGENT_QDRANT_KEY="$QDRANT_KEY"
```

`search_docs` returns nothing until the collection has content:

```sh
cd app
kubectl port-forward svc/qdrant 6333:6333 &
kubectl port-forward svc/ollama 11434:11434 &
AGENT_QDRANT_URL=http://localhost:6333 AGENT_EMBED_URL=http://localhost:11434 \
  uv run python scripts/index.py --path ../docs
```

## Monitoring and logs

Use `make deploy-monitoring` to install or update only the monitoring stack.

```sh
make deploy-monitoring
kubectl -n ai-platform port-forward svc/monitoring-grafana 3000:80
```

Open <http://localhost:3000> with `admin` / `admin` and select **Agent observability**.
Promtail sends stdout/stderr from all pods to Loki. In Grafana Explore:

```logql
{namespace="ai-platform", app="agent"} | json | request_id != "-"
```
