"""Fake OpenAI-compatible LLM and Ollama embedding server, so the service runs with no Ollama."""

import asyncio
import hashlib
import json
import math
import os
import time
import uuid

import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse

app = FastAPI()

DIM = 384
ARG_CHUNKS = 3
ARG_DELAY = 0.03
TOKEN_DELAY = 0.05


def _frame(delta: dict, finish: str | None = None) -> str:
    payload = {
        "id": f"chatcmpl-{uuid.uuid4().hex[:8]}",
        "object": "chat.completion.chunk",
        "created": int(time.time()),
        "model": "mock",
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }
    return f"data: {json.dumps(payload)}\n\n"


def _split(text: str, parts: int) -> list[str]:
    size = math.ceil(len(text) / parts)
    return [text[i : i + size] for i in range(0, len(text), size)] or [""]


async def _tool_call(name: str, args: dict):
    yield _frame({"role": "assistant", "content": ""})
    yield _frame(
        {"tool_calls": [{"index": 0, "id": f"call_{uuid.uuid4().hex[:8]}", "type": "function",
                         "function": {"name": name, "arguments": ""}}]}
    )
    # Real servers dribble arguments out in fragments; do the same so the client side is exercised.
    for part in _split(json.dumps(args), ARG_CHUNKS):
        await asyncio.sleep(ARG_DELAY)
        yield _frame({"tool_calls": [{"index": 0, "function": {"arguments": part}}]})
    yield _frame({}, finish="tool_calls")


async def _text(answer: str):
    yield _frame({"role": "assistant", "content": ""})
    for word in answer.split():
        await asyncio.sleep(TOKEN_DELAY)
        yield _frame({"content": word + " "})
    yield _frame({}, finish="stop")


def _plan(messages: list[dict]) -> tuple[str, dict] | str:
    last_user = next(
        (m.get("content") or "" for m in reversed(messages) if m.get("role") == "user"), ""
    )
    text = last_user.lower()
    answered = any(m.get("role") == "tool" for m in messages)
    if "loop" in text:
        return "get_time", {"timezone": "UTC"}  # never settles: exercises the recursion limit
    if answered:
        return "Done — here is the answer based on the tool result."
    if "badtz" in text:
        return "get_time", {"timezone": "Mars/Olympus"}
    if "time" in text:
        return "get_time", {"timezone": "Asia/Jerusalem"}
    if "search" in text or "kb" in text:
        return "search_docs", {"query": "internal documentation", "top_k": 3}
    return "Hello. I can answer directly without calling any tool."


@app.get("/v1/models")
async def models():
    return {"object": "list", "data": [{"id": "mock", "object": "model"}]}


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    body = await request.json()
    plan = _plan(body.get("messages", []))

    async def gen():
        source = _text(plan) if isinstance(plan, str) else _tool_call(*plan)
        async for frame in source:
            yield frame
        yield "data: [DONE]\n\n"

    return StreamingResponse(gen(), media_type="text/event-stream")


def _vector(text: str) -> list[float]:
    raw = b"".join(
        hashlib.sha256(text.encode() + bytes([i])).digest() for i in range(DIM // 32 + 1)
    )
    vals = [b / 255 - 0.5 for b in raw[:DIM]]
    norm = math.sqrt(sum(v * v for v in vals)) or 1.0
    return [v / norm for v in vals]


# OllamaEmbeddings may call either path depending on version.
@app.post("/api/embed")
async def embed(request: Request):
    body = await request.json()
    texts = body.get("input") or []
    if isinstance(texts, str):
        texts = [texts]
    return {"model": body.get("model", "mock"), "embeddings": [_vector(t) for t in texts]}


@app.post("/api/embeddings")
async def embeddings(request: Request):
    body = await request.json()
    return {"embedding": _vector(body.get("prompt", ""))}


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=int(os.environ.get("MOCK_PORT", 8080)), log_level="warning")
