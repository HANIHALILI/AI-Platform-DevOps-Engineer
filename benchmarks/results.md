# Benchmark results

All entries are CPU-only unless noted otherwise. Empty cells are intentionally
left empty until a real measurement is available. Raw command output belongs in
[`raw/`](raw/). The Ollama startup log verifies `no usable GPU found` and
`library=cpu`; its `ollama ps` CPU/GPU split is a misleading display in this
environment and does not represent GPU offload.

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
| `qwen3:14b` | `q4_K_M` |  |  |  |  |
| `qwen3:27b` | `q4_K_M` |  |  |  |  |
| `qwen3:30b` | `q4_K_M` |  |  |  |  |

## Quantization comparison

| Model | Quantization | Container RSS | Cold TTFT | Warm mean tok/s | Aggregate tok/s |
| --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |

## Runtime optimization

| Change | Model | Before warm mean tok/s | After warm mean tok/s | Before aggregate tok/s | After aggregate tok/s | Notes |
| --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |  |

## Final conclusion

| Decision | Evidence | Result |
| --- | --- | --- |
| CPU-only baseline | `llama3.2:3b-instruct-q4_K_M` on GCP `n4-standard-8` | Baseline measurements above; CPU-only verified in the Ollama runner log. |
