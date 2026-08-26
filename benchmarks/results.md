# Benchmark results

All entries are CPU-only. Raw command output belongs in [`raw/`](raw/). The Ollama
startup log verifies `no usable GPU found` and `library=cpu`; the `ollama ps` CPU/GPU
split is a misleading display here and does not represent GPU offload.

## Baseline

| Model | Quantization | Environment | Init container | Scheduled to Ready | Cold TTFT | Model load | Prompt eval | Resident RSS | Warm TTFT (runs 1 / 2 / 3) | Warm generation (runs 1 / 2 / 3) | Warm mean | Aggregate |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `llama3.2:3b-instruct-q4_K_M` | `q4_K_M` | GCP `n4-standard-8`; CPU-only; 4 CPU / 8 GiB Ollama limit | 12 s | 106 s | 3.62 s | 3.07 s | 0.54 s | 3317 MiB | 0.10 s / 0.10 s / 0.10 s | 11.36 tok/s / 11.45 tok/s / 11.34 tok/s | 11.38 tok/s | 4 requests; 796 tok; 70.52 s wall; 11.29 tok/s |
| `qwen3:4b-q4_K_M` | `q4_K_M` | GCP `n4-standard-8`; CPU-only; 4 CPU / 8 GiB Ollama limit | 11 s | 21 s | invalid (TTFT parser missed `thinking`) | 3.32 s | 0.62 s | 4116 MiB | invalid (TTFT parser missed `thinking`) | 9.09 tok/s / 9.09 tok/s / 9.12 tok/s | 9.10 tok/s | 4 requests; 1024 tok; 171.35 s wall; 5.98 tok/s |

## Model comparison

| Model | Quantization | Cold TTFT | Warm mean tok/s | Aggregate tok/s | Notes |
| --- | --- | --- | --- | --- | --- |
| `llama3.2:3b-instruct` | `q4_K_M` | 3.62 s | 11.38 | 11.29 | Baseline model; CPU-only verified from runner logs |
| `qwen3:4b` | `q4_K_M` | invalid | 9.10 | 5.98 | TTFT parser did not recognize `thinking`; CPU-only verified from runner logs |

Both rows are at `numParallel=1`; the parallelism work below is what moves the
aggregate column.

## Runtime optimization

| Change | Model | Before warm mean tok/s | After warm mean tok/s | Before aggregate tok/s | After aggregate tok/s | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `OLLAMA_NUM_PARALLEL`: 1 → 2 | `qwen3:4b-q4_K_M` | 9.10 | 9.31 | 5.98 | 12.59 | RSS rose 4116Mi → 5272Mi; aggregate throughput rose 110%, still below the 8Gi limit. |
| memory request/limit: 4Gi/8Gi → 20Gi/24Gi | `qwen3:4b-q4_K_M`; `numParallel=2` | 9.31 | 9.21 | 12.59 | 12.49 | No material throughput benefit: higher limit creates safe headroom for additional slots rather than accelerating two slots. |
| `OLLAMA_NUM_PARALLEL`: 2 → 3 | `qwen3:4b-q4_K_M`; 20Gi/24Gi memory | 9.21 | 9.26 | 12.49 | 14.34 | RSS rose 5267Mi → 6415Mi; third slot improved aggregate throughput 14.8%. |
| `OLLAMA_NUM_PARALLEL`: 3 → 4 | `qwen3:4b-q4_K_M`; 20Gi/24Gi memory | 8.61 | 8.26 | 12.83 | 20.98 | RSS rose 6423Mi → 7560Mi; aggregate throughput rose 63%, so four slots is the selected configuration. |

## Final conclusion

| Decision | Evidence | Result |
| --- | --- | --- |
| CPU-only baseline | `llama3.2:3b-instruct-q4_K_M` on GCP `n4-standard-8` | Baseline measurements above; CPU-only verified in the Ollama runner log. |
| Serve `qwen3:4b-q4_K_M` | Model comparison above | Slower on one request than the 3B baseline, and the model the platform keeps. |
| `numParallel: 4`, memory 20Gi/24Gi | Runtime optimization above | 20.98 tok/s aggregate against 5.98 at one slot, at 7560Mi resident. |
