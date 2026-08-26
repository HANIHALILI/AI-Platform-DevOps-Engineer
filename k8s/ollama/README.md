# Inference tier

```
agent  --HTTP-->  ollama  -->  agent-llm  -->  qwen3:4b-q4_K_M  -->  CPU
                              (Modelfile)      (quantized GGUF weights)
```

The agent never names a base model. It asks for `agent-llm`, which the init container builds from a
Modelfile rendered out of `values.yaml`. The weights and the quantization behind that name change
here without the agent chart moving, which is what makes a switch a one-file edit.

## Configuration

| What | Where |
|---|---|
| Base weights and quantization | `model.repository`, `model.variant`, `model.quantization` |
| Name the agent calls | `model.servedAs` |
| Embeddings | `embedModel` |
| Sampling and context | `inference.*`, rendered as `PARAMETER` lines in the Modelfile |
| Concurrency and residency | `server.*`, rendered as `OLLAMA_*` environment variables |
| CPU and memory | `resources` |

`inference` and `server` are two different mechanisms, not two spellings of one. A Modelfile
`PARAMETER` is a default of the model, so any caller that sends nothing gets it; `OLLAMA_*` bounds
the process across every model and request. `contextLength` feeds both, so the server default and
the model's own `num_ctx` cannot drift apart.

`inference.numThread` is worth knowing about: left to itself Ollama sizes its thread pool from the
cores it can see on the node rather than from the Pod's cgroup, so a container limited to 4 CPUs on
a bigger node oversubscribes and gets throttled. Keep it equal to `resources.limits.cpu`.

## Switching model or quantization

Model and quantization selection live entirely in `values.yaml`, and `helm upgrade` applies them.
The agent goes on asking for `agent-llm` either way, so the agent chart, the templates and the
application do not move. What can need adjusting alongside a switch is resource and thread tuning:
a larger model wants more memory, and `inference.numThread` is tied to `resources.limits.cpu`.

```yaml
model:
  repository: qwen2.5
  variant: 7b-instruct
  quantization: q4_K_M
```

The three fields compose into the tag Ollama pulls, `qwen2.5:7b-instruct-q4_K_M`. Any tag that
exists on ollama.com works; check `ollama.com/library/<repository>/tags` first, because a variant
and a quantization that do not pair leave the init container retrying a pull that cannot succeed.
Raise `resources` to match, since a 7B at q4_K_M is roughly 4.4GB of weights against 2.5GB for the
4B served here, and move `inference.numThread` with `resources.limits.cpu` if you change it.

Retuning is the same edit against `inference`, and costs no download: the checksum annotation rolls
the Pod, and the init container rebuilds `agent-llm` from weights already on the volume.

## Quantization

`Q4_K_M` is a llama.cpp K-quant. Weights are stored in blocks with their own scale at roughly four
bits each, and the tensors that suffer most under compression, attention `wv` and the `w2`
projections, are kept at six. The `M` is that medium mix.

Read from the Ollama registry manifests for `llama3.2` 3B on 2026-08-25, against a parameter count
of 3.21B. That was the chart's first base model and the benchmark baseline; the ratios are what
matter here, and they hold for the 4B served now:

| Tag | Weights on disk | Bits/parameter | Relative |
|---|---|---|---|
| `q4_K_M` | 1.88 GiB | 5.03 | 1.00x |
| `q5_K_M` | 2.16 GiB | 5.79 | 1.15x |
| `q6_K` | 2.46 GiB | 6.59 | 1.31x |
| `q8_0` | 3.19 GiB | 8.53 | 1.69x |
| `fp16` | 5.99 GiB | 16.03 | 3.19x |

**Why q4_K_M here.** It is the smallest K-quant still generally held to sit close to fp16 in
quality, and this stack runs on kind, on CPU. Weights are only part of what has to fit: each of the
four decode slots holds its own 8192-token KV cache, and the embedding model stays resident
alongside. The whole process measures 7.6 GiB against the 24 GiB limit. A heavier quant buys back
memory that four slots want more, for a difference this workload of tool-call routing and short
grounded answers is unlikely to show.

The tag is spelled out in full rather than left as `qwen3:4b`, so the quantization is stated and
not inherited from whatever Ollama makes the short tag mean.

## Initialization

The init container starts a throwaway server, pulls anything missing, and builds `agent-llm` from
the Modelfile. `ollama show` is the existence check, so a restart with a populated volume touches
the network not at all; `ollama create` runs every time, which is cheap and is what makes a retune
take effect. Because the pull happens before the main container starts, a Pod that reports Ready is
one that can answer.

The models sit on a PVC (`persistence`). Delete it and the next start downloads again.

## Measuring

```sh
make bench          # NAMESPACE, RUNS and PARALLEL override the defaults
```

It port-forwards to the Ollama Pod and reports:

| Metric | Where it comes from |
|---|---|
| Init container duration, scheduled to Ready | Pod status timestamps |
| **TTFT** | the client's own clock, across a `stream=true` request |
| Model load, prompt eval | `load_duration`, `prompt_eval_duration`, from that same request |
| Resident size and how much of it is on the CPU | `ollama ps` |
| Container RSS | `kubectl top pod` |
| Tokens/sec, one request at a time | `eval_count / eval_duration` |
| Tokens/sec aggregate, `PARALLEL` at once | tokens summed over the wall clock |

The prompt and the generation options are constants in the script, not values read from the chart:
two runs only compare if they asked for the same work.

Three separate numbers, and they are not interchangeable:

- **TTFT** — time to first token, measured rather than computed. The request goes out with
  `"stream": true`, the clock starts immediately before curl is handed it, and stops on the first
  streamed chunk carrying generated text. This is the wait a caller actually sits through.
- **`load_duration`** — Ollama's own figure for reading the weights off the PVC into memory. Large
  on a cold start, near zero once the model is resident.
- **`prompt_eval_duration`** — Ollama's figure for the prefill, evaluating the prompt before any
  token can be produced.

The last two are printed beside TTFT because they explain most of it, not because they sum to it.
TTFT is deliberately the larger number: being client-side it also carries the port-forward, the
network, curl's own startup and any time the request spent queued behind another — none of which
appear in Ollama's accounting. **That overhead is a real limitation of this measurement**, and over
a `kubectl port-forward` it is not negligible; measure from inside the cluster if you need it out.
It is still the honest direction to err in, since a caller pays that overhead too.

Each warm run line takes its TTFT and its tokens/sec from the same request, so the two always
describe one generation. The cold-start section unloads the model first with `keep_alive: 0`, so
its TTFT includes the model load where the warm ones do not — the gap between them is the point,
and it is what makes the benchmark useful for cold-start against warm behaviour.

`make smoke` covers the rest: that `agent-llm` was built, that the quantization the weights report
is the one the tag asked for, and that the agent points at a model Ollama serves.

### Results

Every run is logged in [`benchmarks/results.md`](../../benchmarks/results.md), with the raw stdout
under `benchmarks/raw/`. Both columns are a GCP `n4-standard-8`, CPU-only: the first is the original
baseline, the second is what this chart serves now.

| | `llama3.2:3b-q4_K_M` | `qwen3:4b-q4_K_M` |
|---|---|---|
| Container limit | 4 CPU / 8 GiB | 4 CPU / 24 GiB |
| `numParallel` | 1 | 4 |
| Scheduled to Ready | 106 s | 21 s |
| Model load, cold | 3.07 s | 3.32 s |
| Container RSS | 3317 MiB | 7560 MiB |
| Tokens/sec, sequential | 11.38 | 8.26 |
| Tokens/sec, 4 at once | 11.29 | 20.98 |

`qwen3:4b` is the larger model and the slower one on a single request, so the sequential number goes
the way it should. The aggregate number is set by `server.numParallel` rather than by the model: at
one slot the server serialises, which is why the baseline's aggregate collapses onto its sequential
rate. Each slot added through four raised it, the fourth by 63%, at roughly 1.1 GiB of resident
memory apiece. Four is one slot per CPU, which is where the chart sits.

Quantization is the trade-off this setup cannot measure: fewer bits means more rounding error, and
how much that matters depends on the task. If answers degrade, `q5_K_M` and `q6_K` are one edit
away, and the table above says what they cost in memory.

## CPU-only

This chart targets CPU inference and nothing in it is conditional on a GPU. The Modelfile pins
`PARAMETER num_gpu 0`, `resources` asks for cores and memory only, and `nvidia.com/gpu` appears
nowhere in the templates. That is stated rather than left to happen by default, and it is a
deliberate scope choice: the target is a CPU-only machine, so GPU templating would be configuration
for hardware that is not there.

Moving to GPU nodes would mean dropping the `num_gpu` line and adding a GPU resource request —
a change worth making against real hardware rather than carrying untested.
