import logging
import time
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from pydantic import BaseModel, Field

from app.agent import Error, build_agent, decode, run, sse
from app.config import settings
from app.observability import (
    chat_duration_seconds,
    chat_requests_total,
    chat_ttft_seconds,
    event,
    request_id_middleware,
    setup_logging,
)
from app.rag import Rag
from app.tools import build_tools

READY_TIMEOUT = 5


@asynccontextmanager
async def lifespan(app: FastAPI):
    setup_logging()
    app.state.rag = Rag()
    app.state.agent = build_agent(build_tools(app.state.rag))
    yield


app = FastAPI(lifespan=lifespan)
app.middleware("http")(request_id_middleware)


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=8000)


@app.post("/chat")
async def chat(body: ChatRequest, request: Request):
    async def stream():
        event("request_start", message_length=len(body.message))
        started = time.perf_counter()
        ttft = None
        iterations = 0
        status = "ok"
        try:
            async for chunk in run(request.app.state.agent, body.message):
                if await request.is_disconnected():
                    status = "disconnected"
                    break
                payload = decode(chunk)
                if payload["type"] == "token" and ttft is None:
                    ttft = time.perf_counter() - started
                    chat_ttft_seconds.observe(ttft)
                elif payload["type"] == "done":
                    iterations = payload["iterations"]
                yield chunk
        except Exception as exc:
            status = "error"
            event("request_failed", logging.ERROR, error=type(exc).__name__)
            yield sse(Error(message="internal error"))
        finally:
            duration = time.perf_counter() - started
            chat_duration_seconds.observe(duration)
            chat_requests_total.labels(status).inc()
            event(
                "request_end",
                status=status,
                duration_ms=round(duration * 1000),
                ttft_ms=round(ttft * 1000) if ttft is not None else None,
                iterations=iterations,
            )

    # X-Accel-Buffering is required: without it the nginx ingress buffers the response, and
    # streaming works locally but breaks in the cluster.
    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


# Liveness must not touch external services, or a slow model load becomes CrashLoopBackOff.
@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


# Qdrant is reported but does not gate readiness, because search_docs degrades gracefully.
@app.get("/readyz")
async def readyz(request: Request):
    try:
        async with httpx.AsyncClient(timeout=READY_TIMEOUT) as client:
            llm = (await client.get(f"{settings.llm_url}/models")).status_code == 200
    except httpx.HTTPError:
        llm = False
    qdrant = await request.app.state.rag.ping()
    return JSONResponse(
        {"llm": llm, "qdrant": qdrant}, status_code=200 if llm else 503
    )


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
