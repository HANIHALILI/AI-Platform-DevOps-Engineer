import json
import logging
import sys
import uuid
from contextvars import ContextVar

from prometheus_client import Counter, Histogram
from starlette.requests import Request
from starlette.responses import Response

from app.config import settings

request_id: ContextVar[str] = ContextVar("request_id", default="-")

log = logging.getLogger("agent")

chat_requests_total = Counter("chat_requests_total", "Chat requests", ["status"])
chat_ttft_seconds = Histogram("chat_ttft_seconds", "Request received to first token event")
chat_duration_seconds = Histogram("chat_duration_seconds", "Full chat request duration")
tool_calls_total = Counter("tool_calls_total", "Tool invocations", ["tool", "status"])
qdrant_search_seconds = Histogram("qdrant_search_seconds", "Qdrant query time", ["status"])


class JsonFormatter(logging.Formatter):
    def format(self, record):
        payload = {
            "ts": self.formatTime(record),
            "level": record.levelname,
            "event": record.getMessage(),
            "request_id": request_id.get(),
            **getattr(record, "fields", {}),
        }
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload)


def setup_logging() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(settings.log_level)


# Lengths and counts only. These lines are shipped to Loki and kept.
def event(name: str, level: int = logging.INFO, **fields) -> None:
    log.log(level, name, extra={"fields": fields})


async def request_id_middleware(request: Request, call_next) -> Response:
    rid = request.headers.get("x-request-id") or uuid.uuid4().hex[:16]
    token = request_id.set(rid)
    try:
        response = await call_next(request)
    finally:
        request_id.reset(token)
    response.headers["X-Request-ID"] = rid
    return response
