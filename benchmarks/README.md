# Benchmarks

This directory records measurements of the deployed Ollama inference tier. The
benchmark exercises the served `agent-llm` model through the same Ollama API
used by the platform.

## Target environment

The baseline target is a GCP `n4-standard-8` VM: 8 vCPU and 32 GB RAM, with no
attached GPU. The Kubernetes cluster is a three-node kind cluster; Ollama runs
with a 4 CPU / 8 GiB container limit. Verify CPU-only execution from the Ollama
startup log: it must report `no usable GPU found` and `library=cpu`. In this
environment, the `PROCESSOR` split shown by `ollama ps` is not reliable: it
shows a CPU/GPU ratio even though the node exposes no GPU and the runner logs
that GPU layers are ignored.

## Metrics

`make bench` reports init and ready time, cold-start TTFT (including the first
non-empty `thinking` or `response` stream chunk), model-load and
prompt-evaluation time, resident container RSS, sequential warm-request
throughput, and aggregate throughput at the configured parallelism. TTFT is
measured client-side; model load and prompt evaluation are reported by Ollama.

## Run a benchmark

Deploy the platform, then run from the repository root:

```sh
make bench
```

Optional `RUNS`, `PARALLEL`, and `NAMESPACE` environment variables control the
existing benchmark script. Save the command's complete stdout verbatim in
`raw/` using a descriptive model-and-quantization filename, then enter only
the measured summary values in `results.md`.

## Organization

- `raw/` contains unedited stdout from individual benchmark runs.
- `results.md` is the experiment log and comparison summary. Empty cells mean
  that measurement has not yet been captured.
