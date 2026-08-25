# Benchmark results

The selected CPU-only inference profile is `qwen3:4b-q8_0` with an 8192-token
context, 4 CPU threads, 4 parallel requests, and a 20 GiB request / 24 GiB
limit. Complete, unedited command output is retained in [`raw/`](raw/).

## Selected quantization comparison

Both profiles use the same model, prompt, CPU limit, context length and four
parallel requests. `q8_0` is selected because it produced the highest measured
aggregate throughput while remaining well inside the memory limit.

| Profile | Warm tok/s | Aggregate tok/s | Container memory | Cold TTFT | Decision |
| --- | ---: | ---: | ---: | ---: | --- |
| Qwen3 4B `q4_K_M`, 4 parallel | 8.26 | 20.98 | 7560Mi | 6.24 s | Lower-memory baseline |
| Qwen3 4B `q8_0`, 4 parallel | **11.25** | **26.81** | 9772Mi | 7.89 s | **Selected** |

## Runtime profile

| Setting | Value | Why it matters |
| --- | --- | --- |
| Quantization | `q8_0` | Higher precision than `q4_K_M`; selected for measured throughput and expected text-quality retention. |
| Context window | 8192 | Holds the system prompt and retrieved context without truncation. |
| CPU threads | 4 | Matches the Pod CPU limit and prevents oversubscription. |
| Parallel requests | 4 | Raised aggregate throughput from 5.98 to 20.98 tok/s during tuning. |
| Memory request / limit | 20Gi / 24Gi | Supports four context windows while leaving node headroom. |

## Trade-off

Compared with `q4_K_M`, `q8_0` adds 2212Mi of resident memory and 1.65s to
cold TTFT, but improves aggregate throughput by 27.8%. It also keeps more
weight precision, which is the expected direction for text-generation quality.
Use `q4_K_M` instead when RAM density or cold-start latency matters more than
throughput and precision.
