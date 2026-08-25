# Inference tier

```
agent  --HTTP-->  ollama  -->  agent-llm  -->  llama3.2:3b-instruct-q4_K_M  -->  CPU
                              (Modelfile)         (quantized GGUF weights)
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
Raise `resources` to match, since a 7B at q4_K_M is roughly 4.4GB of weights against 1.9GB for this
3B, and move `inference.numThread` with `resources.limits.cpu` if you change it.

Retuning is the same edit against `inference`, and costs no download: the checksum annotation rolls
the Pod, and the init container rebuilds `agent-llm` from weights already on the volume.

## Quantization

`Q4_K_M` is a llama.cpp K-quant. Weights are stored in blocks with their own scale at roughly four
bits each, and the tensors that suffer most under compression, attention `wv` and the `w2`
projections, are kept at six. The `M` is that medium mix.

Read from the Ollama registry manifests for `llama3.2` 3B on 2026-08-25, against a parameter count
of 3.21B:

| Tag | Weights on disk | Bits/parameter | Relative |
|---|---|---|---|
| `q4_K_M` | 1.88 GiB | 5.03 | 1.00x |
| `q5_K_M` | 2.16 GiB | 5.79 | 1.15x |
| `q6_K` | 2.46 GiB | 6.59 | 1.31x |
| `q8_0` | 3.19 GiB | 8.53 | 1.69x |
| `fp16` | 5.99 GiB | 16.03 | 3.19x |

**Why q4_K_M here.** It is the smallest K-quant still generally held to sit close to fp16 in
quality, and this stack runs on kind, on CPU, under an 8GB memory limit. Weights are only part of
what has to fit: an 8192-token KV cache is another 0.88 GiB, before compute buffers and the resident
embedding model. q6_K would add 0.58 GiB of weights for a difference this workload, tool-call
routing and short grounded answers, is unlikely to show. Choosing q4_K_M over fp16 saves 4.11 GiB,
which is the difference between fitting the default limits and not.

`llama3.2:3b`, the tag this chart used before, resolves to the same digest as
`llama3.2:3b-instruct-q4_K_M` — so the served quantization has not changed, only whether it is
stated or inherited from whatever Ollama happens to make `:3b` mean.

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

**No measurements have been taken.** This repository targets a local kind cluster, and none was
available when the chart was written: no Docker, no cluster, and no NVIDIA GPU on the machine.
Every number above is a file size read from the registry or arithmetic from the published
architecture. Run `make bench` on the real Linux cluster and fill this in.

| | q4_K_M | q6_K |
|---|---|---|
| Scheduled to Ready | | |
| Model load, cold | | |
| TTFT, cold | | |
| TTFT, warm | | |
| Resident size | | |
| Tokens/sec, sequential | | |
| Tokens/sec, 4 at once | | |

Direction only, for what to expect — none of this was run here and none of it should be quoted as a
result. Memory is the one not really in doubt: weights are read into memory much as they are stored,
so q6_K should cost about the extra 0.58 GiB, and the KV cache does not move with the quantization
of the weights. Throughput on CPU is usually bound by memory bandwidth rather than compute, so
fewer bits per weight generally means more tokens/sec. Startup should track file size. Quality is
the trade-off being made and the one this setup cannot measure: fewer bits means more rounding
error, and how much that matters depends on the task. If answers degrade, `q5_K_M` and `q6_K` are
one edit away, and the table above says what they cost.

## CPU-only

This chart targets CPU inference and nothing in it is conditional on a GPU. The Modelfile pins
`PARAMETER num_gpu 0`, `resources` asks for cores and memory only, and `nvidia.com/gpu` appears
nowhere in the templates. That is stated rather than left to happen by default, and it is a
deliberate scope choice: the target is a CPU-only machine, so GPU templating would be configuration
for hardware that is not there.

Moving to GPU nodes would mean dropping the `num_gpu` line and adding a GPU resource request —
a change worth making against real hardware rather than carrying untested.
