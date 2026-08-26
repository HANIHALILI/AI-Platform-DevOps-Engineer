# Benchmarks

This directory records measurements of the deployed Ollama inference tier. The
benchmark exercises the served `agent-llm` model through the same Ollama API
used by the platform.

## Target environment

A GCP `n4-standard-8` VM: 8 vCPU and 32 GB RAM, no attached GPU, running a three-node
kind cluster. Ollama runs at a 4 CPU / 24 GiB container limit; `results.md` states the
full profile every number was measured against.

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

## Quality checks

```sh
make quality
```

The deterministic cases in `quality/cases.psv` cover Kubernetes probes, RAG
grounding, context limits, quantization and concurrency. Each case declares its
required concepts; the script stores full answers under `quality/raw/` for human
review and fails when a required concept is absent. Run the same suite after
every quantization change and record the score beside the performance result.
For a quantization already present on the Ollama PVC, compare without changing
the deployment with `MODEL_OVERRIDE=qwen3:4b-q4_K_M make quality`.

## Organization

- `raw/` contains unedited stdout from individual benchmark runs.
- `results.md` is the comparison summary and the selected profile.
- `quality/` holds the rubric cases and the graded answers behind each run.
