import pytest
from langchain_core.messages import AIMessageChunk, ToolMessage
from langchain_core.tools import ToolException

from app.agent import decode, run
from app.rag import RagUnavailable
from app.tools import build_tools


class FakeAgent:
    def __init__(self, events):
        self.events = events

    async def astream(self, *args, **kwargs):
        for item in self.events:
            yield item


async def collect(events) -> list[dict]:
    return [decode(chunk) async for chunk in run(FakeAgent(events), "hi")]


async def test_empty_content_chunk_emits_no_token():
    # Chunks carrying tool-call fragments have empty content; unfiltered they look like stuttering.
    events = await collect([("messages", (AIMessageChunk(content=""), {}))])
    assert [e["type"] for e in events] == ["done"]


async def test_tool_error_becomes_ok_false():
    msg = ToolMessage(content="boom", name="get_time", tool_call_id="1", status="error")
    events = await collect([("updates", {"tools": {"messages": [msg]}})])
    assert events[0] == {"type": "tool_result", "name": "get_time", "ok": False, "preview": "boom"}


async def test_tool_update_without_status_raises():
    # The reason the events are models: a LangChain version that stops setting `status` must fail
    # loudly here instead of marking every failure a success.
    class NoStatus:
        name = "get_time"
        content = "boom"

    with pytest.raises(AttributeError):
        await collect([("updates", {"tools": {"messages": [NoStatus()]}})])


async def test_exactly_one_done():
    events = await collect(
        [
            ("messages", (AIMessageChunk(content="hello"), {})),
            ("messages", (AIMessageChunk(content=" there"), {})),
        ]
    )
    assert sum(e["type"] == "done" for e in events) == 1
    assert events[-1]["type"] == "done"


async def test_search_docs_raises_tool_exception_and_stream_still_completes():
    class BrokenRag:
        async def search(self, query, k):
            raise RagUnavailable("down")

    search_docs, _ = build_tools(BrokenRag())
    with pytest.raises(ToolException):
        await search_docs.ainvoke({"query": "x"})

    # ToolNode turns that into an error ToolMessage, so the stream still reaches its terminal event.
    msg = ToolMessage(
        content="Knowledge base unavailable", name="search_docs", tool_call_id="1", status="error"
    )
    events = await collect([("updates", {"tools": {"messages": [msg]}})])
    assert events[0]["ok"] is False
    assert events[-1]["type"] == "done"
