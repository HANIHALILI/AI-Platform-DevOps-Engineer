# Benchmarks

This directory records measurements of the deployed Ollama inference tier. The
benchmark exercises the served `agent-llm` model through the same Ollama API
used by the platform.

## Target environment

A GCP `n4-standard-8` VM: 8 vCPU and 32 GB RAM, no attached GPU, running a three-node
kind cluster. Ollama's container limit moved during the experiments and is recorded
per row in `results.md`; it is 4 CPU / 24 GiB now.

Verify CPU-only execution from the Ollama startup log: it must report `no usable GPU
found` and `library=cpu`. The `PROCESSOR` split shown by `ollama ps` is not reliable
here, since it shows a CPU/GPU ratio on a node that exposes no GPU.

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

`RUNS`, `PARALLEL`, and `NAMESPACE` override the defaults. Save the complete stdout
verbatim in `raw/` under a model-and-quantization filename, then enter the summary
values in `results.md`.

## Organization

- `raw/` contains unedited stdout from individual benchmark runs.
- `results.md` is the experiment log and comparison summary.
