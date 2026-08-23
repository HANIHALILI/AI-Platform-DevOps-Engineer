#!/usr/bin/env bash
# Proves /chat works with no Ollama and no Qdrant: the mock server stands in for the LLM, and
# AGENT_QDRANT_URL points at a closed port so search_docs takes its fallback path.
set -uo pipefail
cd "$(dirname "$0")/.."

APP_PORT=8000
MOCK_PORT=8080
export AGENT_LLM_URL="http://127.0.0.1:${MOCK_PORT}/v1"
export AGENT_EMBED_URL="http://127.0.0.1:${MOCK_PORT}"
export AGENT_QDRANT_URL="http://127.0.0.1:9"
export AGENT_LOG_LEVEL="INFO"

MOCK_PID=""
APP_PID=""
cleanup() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT

wait_for() {
  for _ in $(seq 1 60); do
    curl -sf "$1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "timed out waiting for $1" >&2
  return 1
}

uv run python scripts/mock_llm.py &
MOCK_PID=$!
uv run uvicorn app.main:app --host 127.0.0.1 --port "$APP_PORT" --log-level warning &
APP_PID=$!

wait_for "http://127.0.0.1:${MOCK_PORT}/v1/models" || exit 1
wait_for "http://127.0.0.1:${APP_PORT}/healthz" || exit 1

# -N is required, or curl buffers and streaming looks broken.
ask() {
  echo
  echo "=============================================================="
  echo "== $1"
  echo "=============================================================="
  curl -N -s -X POST "http://127.0.0.1:${APP_PORT}/chat" \
    -H 'Content-Type: application/json' \
    -d "{\"message\": $(printf '%s' "$2" | python -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"
}

ask "plain answer (no tool call)"        "hello there"
ask "search (Qdrant down -> fallback)"   "search the kb for onboarding"
ask "clock call"                         "what time is it"
ask "tool error (ok=false)"              "badtz please"
ask "iteration limit"                    "loop forever"

echo
echo "=============================================================="
echo "== health, readiness, metrics"
echo "=============================================================="
echo "--- /healthz"; curl -s "http://127.0.0.1:${APP_PORT}/healthz"; echo
echo "--- /readyz";  curl -s -w ' [http %{http_code}]' "http://127.0.0.1:${APP_PORT}/readyz"; echo
echo "--- /metrics (ours only)"
curl -s "http://127.0.0.1:${APP_PORT}/metrics" | grep -E '^(chat_requests_total|chat_ttft_seconds_count|chat_duration_seconds_count|tool_calls_total)'
