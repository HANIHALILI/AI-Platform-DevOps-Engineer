import json
from collections.abc import AsyncIterator
from typing import Literal

from langchain_core.messages import AIMessageChunk
from langchain_core.tools import BaseTool
from langchain_openai import ChatOpenAI
from langgraph.errors import GraphRecursionError
from langgraph.prebuilt import ToolNode, create_react_agent
from pydantic import BaseModel

from agent.config import settings

LLM_TIMEOUT = 120

SYSTEM_PROMPT = """You are a helpful assistant running inside a Kubernetes cluster.

- Use search_docs when the user asks about internal documentation or something you are not sure about.
- Use get_time when the user asks about the current time.
- Don't call a tool if you can answer directly.
- One tool per turn.
- After a tool returns, answer the user. Don't describe the tool call.
- Be concise."""


# No checkpointer: a MemorySaver would put conversation state in pod memory and break scaling.
def build_agent(tools: list[BaseTool]):
    llm = ChatOpenAI(
        base_url=settings.llm_url,
        api_key=settings.llm_key,
        model=settings.llm_model,
        temperature=settings.llm_temperature,
        timeout=LLM_TIMEOUT,
        max_retries=2,
    )
    # Keeps a ToolException inside the graph as a ToolMessage with status="error", so /chat still
    # answers with Qdrant down. `str` and not True, which would wrap it in repr(exc).
    node = ToolNode(tools, handle_tool_errors=str)
    return create_react_agent(llm, tools=node, prompt=SYSTEM_PROMPT)


# Our contract, not LangChain's. The required fields make a version that stops setting `status`
# fail here instead of marking every failed tool call a success.
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
    preview: str


class Done(BaseModel):
    type: Literal["done"] = "done"
    iterations: int


class Error(BaseModel):
    type: Literal["error"] = "error"
    message: str
    iterations: int = 0


Event = Token | ToolCall | ToolResult | Done | Error


def sse(event: Event) -> str:
    return f"data: {event.model_dump_json()}\n\n"


def decode(chunk: str) -> dict:
    return json.loads(chunk.removeprefix("data: "))


async def run(agent, message: str) -> AsyncIterator[str]:
    # Each turn is two node visits, so the recursion limit is twice the iteration budget.
    config = {"recursion_limit": 2 * settings.max_iterations}
    iterations = 0
    streamed = 0  # tokens emitted since the last agent update
    cut_off = False
    try:
        async for mode, payload in agent.astream(
            {"messages": [("user", message)]},
            stream_mode=["messages", "updates"],
            config=config,
        ):
            if mode == "messages":
                chunk, _meta = payload
                # "messages" carries every node's output, and tool-call fragments arrive as
                # empty-content chunks, so only non-empty model chunks are tokens.
                if isinstance(chunk, AIMessageChunk) and isinstance(chunk.content, str) and chunk.content:
                    streamed += 1
                    yield sse(Token(content=chunk.content))
                continue
            for node, update in payload.items():
                if node == "agent":
                    iterations += 1
                    for msg in update["messages"]:
                        for call in msg.tool_calls:
                            yield sse(ToolCall(name=call["name"], args=call["args"]))
                        # Out of budget, the prebuilt agent injects a canned message instead of
                        # raising, so the turn ends with neither tool calls nor streamed text.
                        cut_off = (
                            iterations >= settings.max_iterations
                            and not msg.tool_calls
                            and streamed == 0
                        )
                    streamed = 0
                elif node == "tools":
                    for msg in update["messages"]:
                        yield sse(
                            ToolResult(
                                name=msg.name,
                                ok=msg.status != "error",
                                preview=str(msg.content)[:200],
                            )
                        )
    except GraphRecursionError:
        cut_off = True
    if cut_off:
        yield sse(Error(message="iteration limit reached", iterations=iterations))
    else:
        yield sse(Done(iterations=iterations))
