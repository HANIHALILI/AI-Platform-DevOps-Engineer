import asyncio
import logging
from datetime import datetime
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from langchain_core.tools import BaseTool, ToolException, tool

from app.config import settings
from app.observability import event, tool_calls_total
from app.rag import Rag, RagUnavailable

TOOL_TIMEOUT = 10


def build_tools(rag: Rag) -> list[BaseTool]:
    @tool
    async def search_docs(query: str, top_k: int = settings.top_k) -> str:
        """Search the internal knowledge base. Use this when the user asks about internal
        documentation or facts you are not sure about."""
        event("tool_call", tool="search_docs")
        k = min(max(top_k, 1), settings.top_k_max)
        try:
            hits = await asyncio.wait_for(rag.search(query, k), TOOL_TIMEOUT)
        except (RagUnavailable, TimeoutError) as exc:
            event("tool_error", logging.WARNING, tool="search_docs", error=type(exc).__name__)
            event("retrieval_unavailable", logging.WARNING)
            tool_calls_total.labels("search_docs", "error").inc()
            # LangGraph sets status="error" only when a tool raises, and ok=false rides on that.
            raise ToolException("Knowledge base unavailable") from exc
        tool_calls_total.labels("search_docs", "ok").inc()
        if not hits:
            return "Nothing found."
        return "\n".join(f"[{i}] ({h.source}) {h.text}" for i, h in enumerate(hits, 1))

    @tool
    async def get_time(timezone: str = "UTC") -> str:
        """Get the current time in an IANA timezone such as 'Asia/Jerusalem'."""
        event("tool_call", tool="get_time")
        try:
            zone = ZoneInfo(timezone)
        except (ZoneInfoNotFoundError, ValueError) as exc:
            event("tool_error", logging.WARNING, tool="get_time", error=type(exc).__name__)
            tool_calls_total.labels("get_time", "error").inc()
            raise ToolException(f"Unknown timezone '{timezone}'") from exc
        tool_calls_total.labels("get_time", "ok").inc()
        return datetime.now(zone).isoformat()

    return [search_docs, get_time]
