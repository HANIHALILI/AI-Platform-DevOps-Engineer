# Inference tier

```
agent  --HTTP-->  ollama  -->  agent-llm  -->  qwen3:4b-q8_0  -->  CPU
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
Raise `resources` to match: weights scale with the parameter count, and the table below gives the
multiplier each quantization costs. Move `inference.numThread` with `resources.limits.cpu` too.

Retuning is the same edit against `inference`, and costs no download: the checksum annotation rolls
the Pod, and the init container rebuilds `agent-llm` from weights already on the volume.

## Quantization

### Measured selection

The deployed profile is `qwen3:4b-q8_0`, with 4 CPU threads, 4 parallel
requests, an 8192-token context and a 20 GiB request / 24 GiB limit. Under the
fixed benchmark it reached 26.81 aggregate tok/s and 9772 MiB RSS. The directly
measured `q4_K_M` profile reached 20.98 aggregate tok/s and 7560 MiB RSS. In
exchange for the 2.16 GiB higher resident footprint, `q8_0` adds 1.65 s to cold
TTFT (7.89 s vs 6.24 s) but yields 27.8% more aggregate throughput. It also
retains more weight precision than a 4-bit quantization, which is the expected
direction for text quality; task-quality evaluation remains workload-specific.

The selected profile has roughly 14 GiB of headroom below its 24 GiB limit. If
memory density or cold-start latency is more important than throughput and
precision, switch `model.quantization` back to `q4_K_M`.

`q8_0` stores each weight as an 8-bit integer, in blocks with one scale apiece, which is close to a
straight cast of the fp16 tensors. `q4_K_M` is a llama.cpp K-quant instead: roughly four bits per
weight, with the tensors that suffer most under compression, attention `wv` and the `w2`
projections, kept at six. The `M` is that medium mix.

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

**What has to fit.** Weights are only part of it: each of the four decode slots holds its own
8192-token KV cache, and the embedding model stays resident alongside. That is what the 9772 MiB
above is measuring, and against a 24 GiB limit the precision `q8_0` keeps costs memory this Pod
already has. On a tighter limit the trade goes the other way, which is what the `q4_K_M` row is
there for.

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
| Resident size of each loaded model | `ollama ps` |
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
under `benchmarks/raw/` and the graded answers under `benchmarks/quality/raw/`, all on a GCP
`n4-standard-8`, CPU-only.

`server.numParallel` is what moved the aggregate number, not the model: at one slot the server
serialises, four requests take four turns, and the aggregate lands below the sequential rate at
5.98 tok/s. Every slot added through four raised it, the fourth from 14.34 to 20.98, at roughly
1.1 GiB of resident memory apiece. Four is one slot per CPU, which is where the chart sits.

Text quality is the part `make bench` cannot see, so `make quality` covers it separately: five
deterministic prompts, each declaring the concepts a grounded answer has to contain, with the full
answers kept for reading. Both quantizations scored 5/5, which says the selected profile keeps the
required concepts rather than ranking either model in general.

## CPU-only

This chart targets CPU inference and nothing in it is conditional on a GPU. The Modelfile pins
`PARAMETER num_gpu 0`, `resources` asks for cores and memory only, and `nvidia.com/gpu` appears
nowhere in the templates. That is stated rather than left to happen by default, and it is a
deliberate scope choice: the target is a CPU-only machine, so GPU templating would be configuration
for hardware that is not there.

Moving to GPU nodes would mean dropping the `num_gpu` line and adding a GPU resource request —
a change worth making against real hardware rather than carrying untested.
