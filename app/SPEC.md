# BUILD SPEC — agent-service

A FastAPI service with a streaming `/chat` endpoint. A LangGraph ReAct agent decides when to call
tools; one of those tools searches a Qdrant collection.

Size: expect roughly **450 lines under `app/`**. Not a limit — a sanity check. If it comes out far
larger, look for extra abstractions or files, not for lines to shave.

Guiding rule: **we picked a framework, so we use it.** Anything LangGraph or a LangChain
integration already does, we do not reimplement. Our own code is limited to what is actually ours:
configuration, the two tools, the SSE contract, and the operational surface.

---

## Rules

- Python 3.12, async. Type hints on function signatures, not on every local.
- Only the dependencies in `pyproject.toml`.
- Use the prebuilt agent, the prebuilt vector store, the prebuilt splitter. No hand-rolled
  `StateGraph`, no hand-rolled embedding client, no hand-rolled chunker.
- No abstraction with a single implementation — no `Protocol`, no factory, no registry class.
- Comment only what isn't obvious. No docstrings on short functions — **except tool docstrings**,
  which are the description the model reads.
- Catch exceptions only where there's a defined recovery. Otherwise let them raise.
- No config outside `config.py`. No `print()` outside `scripts/`.
- Run everything through `uv run`.
- **If an API here differs from the installed version, follow the installed version** and keep the
  described behaviour. These libraries move fast.

---

## Files

```
pyproject.toml
.python-version
uv.lock
app/
  __init__.py
  config.py           # settings from env                 ~40 lines
  observability.py    # logging with request_id, metrics   ~50 lines
  rag.py              # Qdrant: index and search           ~55 lines
  tools.py            # the two tools                      ~35 lines
  agent.py            # the agent, and stream -> SSE       ~70 lines
  main.py             # the API                            ~70 lines
scripts/
  mock_llm.py    # fake LLM + embedding server
  index.py       # CLI: rebuild the collection
  validate.sh
tests/
  test_agent.py
```

Each file gets one sentence of description. If a file needs two, split it; if two files share one,
merge them. Do not add files beyond this list.

---

## `app/config.py`

`pydantic-settings`, env prefix `AGENT_`, module-level `settings = Settings()`.

| Field | Default |
|---|---|
| `llm_url` | `http://ollama:11434/v1` |
| `llm_model` | `llama3.2:3b` |
| `llm_key` | `not-needed` |
| `llm_temperature` | `0.1` |
| `embed_url` | `http://ollama:11434` |
| `embed_model` | `all-minilm` |
| `qdrant_url` | `http://qdrant:6333` |
| `qdrant_key` | `None` |
| `collection` | `docs` |
| `top_k` | `3` |
| `top_k_max` | `5` |
| `chunk_size` | `800` |
| `chunk_overlap` | `100` |
| `max_iterations` | `5` |
| `log_level` | `INFO` |

Validated at import: `chunk_overlap < chunk_size`, `1 <= top_k <= top_k_max`, `max_iterations` in
`[1, 10]`, `llm_temperature` in `[0.0, 2.0]`.
Nothing else is configurable — timeouts (120 s for the LLM, 30 s for embeddings, 10 s per tool)
are constants in code, since they don't change between environments.

> `all-minilm` rather than `nomic-embed-text`: nomic requires `search_document:` / `search_query:`
> task prefixes that `OllamaEmbeddings` does not add, which would mean writing our own embedding
> path again. all-minilm needs no prefixes and is 45 MB instead of 274 MB.

---

## `app/rag.py`

Owns the vector store. **The only module that imports `langchain_qdrant` or `langchain_ollama`.**
`agent.py` must not mention vectors, Qdrant, or embeddings.

```python
class RagUnavailable(Exception): ...

class Hit(NamedTuple):
    text: str
    source: str
    score: float

class Rag:
    async def search(self, query: str, k: int) -> list[Hit]
    async def rebuild(self, path: Path) -> tuple[int, int]   # (files, chunks)
    async def ping(self) -> bool
```

Built from `OllamaEmbeddings(model=settings.embed_model, base_url=settings.embed_url)` and
`QdrantVectorStore`.

**`rebuild(path)`** — read `*.md` recursively under `path`, sorted by name, into `Document(page_content=...,
metadata={"source": name})`, split with
`RecursiveCharacterTextSplitter(chunk_size=settings.chunk_size, chunk_overlap=settings.chunk_overlap)`,
then:

```python
QdrantVectorStore.from_documents(
    chunks, embedding=self.embeddings, url=settings.qdrant_url,
    api_key=settings.qdrant_key, collection_name=settings.collection,
    force_recreate=True,
)
```

`force_recreate=True` gives full-rebuild semantics in one keyword — no incremental path, no point
IDs to keep stable, and stale chunks from edited files cannot survive. Exceptions propagate: a
seeding job must fail loudly.

**`search`** — connect lazily via `QdrantVectorStore.from_existing_collection(...)`, cached after
the first successful call, then `await store.asimilarity_search_with_score(query, k=k)`, mapped to `Hit`.

Any failure — including a missing collection — raises `RagUnavailable`. On a missing collection,
log `collection missing — run scripts/index.py`, so an empty knowledge base is visible rather than
silent. `ping` returns `False` instead of raising.

---

## `app/tools.py`

`@tool` from `langchain_core.tools`, with no `args_schema` — the schema is inferred from the type
hints, and **the docstring is the description the model reads.** Write it for the model.

```python
@tool
async def search_docs(query: str, top_k: int = 3) -> str:
    """Search the internal knowledge base. Use this when the user asks about internal
    documentation or facts you are not sure about."""
```

Clamps `top_k` to `[1, settings.top_k_max]`, calls `rag.search` wrapped in
`asyncio.wait_for(..., 10)`, and formats numbered lines `[1] (source) text`.

**Failure rule for both tools: `ok=false` means the tool could not do its job; an empty result is
still a job done.**

| Case | Behaviour | `ok` |
|---|---|---|
| `search_docs`, no hits | return `"Nothing found."` | `true` |
| `search_docs`, `RagUnavailable` or timeout | log a warning, `raise ToolException("Knowledge base unavailable")` | `false` |
| `get_time`, unknown timezone | `raise ToolException("Unknown timezone '<tz>'")` | `false` |

`ToolException` is caught by `ToolNode(handle_tool_errors=True)` and turned into a `ToolMessage`
carrying our text with `status="error"`. **The exception never leaves the graph**, so `/chat` still
works with Qdrant down — and the model sees the same readable text either way. Only the client's
`ok` flag changes, and now it means something. LangGraph sets `status="error"` solely when a tool
raises, so a returned error string would report success.

Result text is **not truncated**: chunks are already bounded by `chunk_size`, so a second limit
here would only cut sentences in half and split the knob in two. `top_k_max` is what bounds how
much reaches the model — `top_k_max * chunk_size` is the worst case, and it has to stay well under
the inference server's context window (Ollama defaults to `num_ctx: 2048` and silently drops the
oldest messages — the system prompt — when it overflows). Set `num_ctx` explicitly in Part 3.

```python
@tool
async def get_time(timezone: str = "UTC") -> str:
    """Get the current time in an IANA timezone such as 'Asia/Jerusalem'."""
```

ISO-8601 via `zoneinfo`. This tool exists so the model has an actual choice to make between tools.

`rag` is captured by closure: `build_tools(rag)` returns the two tool objects. No module-level
globals. Each tool increments `tool_calls_total{tool,status}`.

---

## `app/agent.py`

### Building it

```python
llm = ChatOpenAI(
    base_url=settings.llm_url, api_key=settings.llm_key, model=settings.llm_model,
    temperature=settings.llm_temperature, timeout=120, max_retries=2,
)
agent = create_react_agent(llm, tools=[search_docs, get_time], prompt=SYSTEM_PROMPT)
```

`create_react_agent` (from `langgraph.prebuilt`) builds the agent/tools loop, binds the tools,
routes on tool calls, and returns tool errors to the model as `ToolMessage`s so it can correct
itself. All of that is the framework's job.

**No checkpointer.** The service is stateless; a `MemorySaver` would put conversation state in pod
memory and break horizontal scaling.

The iteration limit is `config={"recursion_limit": 2 * settings.max_iterations}` — each turn is two
node visits. Exceeding it raises `GraphRecursionError`.

### System prompt

```
You are a helpful assistant running inside a Kubernetes cluster.

- Use search_docs when the user asks about internal documentation or something you are not sure about.
- Use get_time when the user asks about the current time.
- Don't call a tool if you can answer directly.
- One tool per turn.
- After a tool returns, answer the user. Don't describe the tool call.
- Be concise.
```

Terse and rule-shaped because the model is 3B.

### SSE events

The event contract is ours, not LangChain's, so this part we write — as Pydantic models:

```python
class Token(BaseModel):
    type: Literal["token"] = "token"
    content: str

class ToolCall(BaseModel):
    type: Literal["tool_call"] = "tool_call"
    name: str
    args: dict

class ToolResult(BaseModel):
    type: Literal["tool_result"] = "tool_result"
    name: str
    ok: bool
    preview: str          # first 200 chars of the tool output

class Done(BaseModel):
    type: Literal["done"] = "done"
    iterations: int

class Error(BaseModel):
    type: Literal["error"] = "error"
    message: str

Event = Token | ToolCall | ToolResult | Done | Error
```

Serialized with `f"data: {event.model_dump_json()}\n\n"`.

The models exist because this is the boundary between a fast-moving third-party structure and what
we promise the client. `ok = msg.status != "error"` quietly yields `True` if a LangChain version
stops setting `status`, marking every failed tool as a success; `ok: bool` and `name: str` make
that blow up at the boundary instead.

```python
async def run(agent, message: str) -> AsyncIterator[str]
```

Consume `agent.astream({"messages": [("user", message)]}, stream_mode=["messages", "updates"],
config=...)` and translate:

| Mode | Payload | Emit |
|---|---|---|
| `messages` | `(chunk, meta)` | `token` — **only when `chunk` is an `AIMessageChunk` with non-empty `str` content.** `stream_mode="messages"` emits from every node, not just the model: without the type check, tool output streams to the client as if the model had typed it. Tool-call fragments also arrive as empty-content chunks and must be skipped |
| `updates` | `agent` node | one `tool_call` per entry in `msg.tool_calls`; count the visit for `iterations` |
| `updates` | `tools` node | `tool_result` with `ok = msg.status != "error"` |

Finish with one `done`. Catch `GraphRecursionError` → one `error`. Exactly one terminal event per
stream.

Node updates arrive after the node finishes, so a `tool_call` event lands after that turn's
(empty) token stream. That's fine — a tool-calling turn produces no visible tokens.

---

## `app/observability.py`

### Logging

Stdlib `logging`, JSON to stdout, level from settings. A `ContextVar` holds `request_id`; the
formatter reads it, so every line emitted during a request carries the same id without being
passed around. `setup_logging()` and the middleware that sets the id both live here; the
middleware echoes the id back as an `X-Request-ID` response header and reuses an incoming one.

Without this, logs from three pods under load are unreadable — and tracing agent execution is
exactly what Track B is for.

| Event | Fields |
|---|---|
| `request_start` | `request_id`, `message_length` |
| `tool_call` | tool name |
| `tool_error` | tool name, exception class |
| `retrieval_unavailable` | — |
| `request_end` | `status`, `duration_ms`, `ttft_ms`, `iterations` |

**Never log message content, tool arguments, query text, or document text** — log lengths and
counts. In-cluster these lines are shipped to Loki and kept.

### Metrics

Four, no more:

```
chat_requests_total{status}
chat_ttft_seconds            # request received -> first token event
chat_duration_seconds        # full request
tool_calls_total{tool,status}
```

TTFT is the metric that matters for a streaming service, and the one Track B names: total duration
says little on its own, since a 30-second request feels fast when the first token lands in half a
second.

---

## `app/main.py`

Assembly and routes only. Lifespan builds `Rag`, calls `build_tools(rag)` and `build_agent(tools)`,
stores them on `app.state`, and calls `setup_logging()`. No indexing at startup — that's
`scripts/index.py`.

### `POST /chat`

Body `{"message": str}`, 1–8000 chars. `StreamingResponse`, `media_type="text/event-stream"`:

```
Cache-Control: no-cache
X-Accel-Buffering: no
```

`X-Accel-Buffering: no` is required — without it nginx ingress buffers the response, and streaming
works locally but breaks in the cluster.

Stop if `await request.is_disconnected()`. Any unhandled exception → log it, emit one `error`
event, end the stream.

### Health

| Route | Behaviour |
|---|---|
| `GET /healthz` | always `200 {"status":"ok"}` — no I/O, no dependency checks |
| `GET /readyz` | `200` if `GET {llm_url}/models` answers (plain `httpx`), else `503`. Report Qdrant in the body but don't gate on it |
| `GET /metrics` | `prometheus_client.generate_latest` |

Liveness must not touch external services, or a slow model load becomes CrashLoopBackOff. Qdrant
doesn't gate readiness because `search_docs` degrades gracefully.

---

## Scripts

**`scripts/mock_llm.py`** — FastAPI on 8080 so the service runs with no Ollama.
`GET /v1/models`; `POST /v1/chat/completions` streaming OpenAI-shaped SSE ending in `data: [DONE]`;
`POST /api/embed` and `POST /api/embeddings` returning a deterministic normalized vector from
`sha256(text)` (both paths, since `OllamaEmbeddings` may call either).

By last user message: `"time"` → clock tool call then an answer; `"search"` or `"kb"` → search tool
call then an answer; `"loop"` → a tool call every time, exercising the recursion limit; `"badtz"` →
a `get_time` call with an invalid timezone, so `ok=false` is seen end to end through the tool
itself, not only through Qdrant being down; otherwise plain text word by word. Emit tool-call arguments across three chunks, 30 ms apart, so the client
side sees what a real server does.

> **Iteration cutoff.** `create_react_agent` tracks `remaining_steps` and, when the budget runs
> out, injects a canned "need more steps" message rather than raising `GraphRecursionError` — the
> stream would otherwise end with no assistant text and a plain `done`, a silent truncation. Detect
> it structurally: when the iteration count reaches `max_iterations` and the final agent turn
> produced neither tool calls nor streamed text, emit `Error`. Keep the `GraphRecursionError`
> handler as well, in case a future version raises again.

**`scripts/index.py`** — `uv run python scripts/index.py --path DIR`. `--path` is required, so a
rebuild is never run against a directory by accident. Calls `rebuild`, prints the file and chunk
counts, exits non-zero on failure — that exit code is what turns the Part 3 Job red.

The corpus itself is out of scope for now: the script takes any directory of `*.md`.

**`scripts/validate.sh`** — starts the mock server and the app with an unreachable
`AGENT_QDRANT_URL`, then `curl -N` against `/chat` for: a plain answer, a search (shows the
fallback), a clock call, `"badtz"` (shows a tool error), and `"loop"` (shows the iteration limit);
plus `/healthz`, `/readyz`, `/metrics`. Kills both on exit. It never needs a real Qdrant or Ollama
— that is the point of it. `-N` is required or curl buffers and streaming looks broken.

---

## Tests

`tests/test_agent.py`, five tests, roughly 60 lines. The assessment never asks for tests —
`validate.sh` is the required proof — so these cover only the two things that fail *silently* and
would never be caught by eye in a `curl` session, plus the contract the brief does require.

Nothing here re-tests LangGraph. Routing, tool binding and the ReAct loop are the framework's job.

| Test | Why this one |
|---|---|
| A `messages` chunk with empty `content` emits nothing | Chunks carrying tool-call fragments have empty content. Unfiltered, empty `token` events leak into the stream and look like the model stuttering |
| A `tools` update with `status="error"` becomes `ToolResult(ok=False)` | A failed tool marked as a success looks completely normal in the stream. Not findable by hand |
| A `tools` update with no `status` raises | This is the reason the events are Pydantic models. If a LangChain version stops setting `status`, this fails loudly instead of marking every failure a success |
| Exactly one `Done` at the end of a stream | Zero or two terminal events break any client parsing the stream |
| `search_docs` raises `ToolException` when `rag.search` fails, and the graph still completes | The brief requires the endpoint to work with dependencies mocked; this is that guarantee |

`agent.astream` is stubbed with canned `("messages", ...)` and `("updates", ...)` tuples, and
`rag` is a stub object. No network, no model, no Qdrant.

## Done when

1. `uv run ruff check` and `uv run pytest` pass.
2. `bash scripts/validate.sh` prints the five expected event sequences.
3. `/chat` works with no Ollama and no Qdrant running.
4. `curl -N` shows tokens arriving over time, not in one burst.
5. Every log line of a request carries the same `request_id`, and it comes back as a header. No
   message content appears in any log line.
6. Against a live Qdrant, `uv run python scripts/index.py --path DIR` reports the file and chunk
   counts; running it twice leaves the collection size unchanged.
7. Every field in `config.py` is settable by environment variable.
8. `SIGTERM` lets in-flight streams finish instead of cutting them — a `/chat` request can run for
   a minute, and Part 3 sets `terminationGracePeriodSeconds` to match.
9. `grep -rl "langchain_qdrant\|langchain_ollama" app/` returns only `app/rag.py`.

---

## Known deviations

- `create_react_agent` is deprecated in LangGraph v1 in favour of `langchain.agents.create_agent`.
  Kept, because moving would add the full `langchain` package as a new top-level dependency.
- Criterion 6 (re-index idempotency) needs a live Qdrant and is verified in Part 2, not locally.
