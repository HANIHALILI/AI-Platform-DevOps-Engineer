#!/usr/bin/env bash
# Runs deterministic, rubric-based quality checks against the deployed model.
# The rubric is deliberately transparent: every case lists the concepts a
# grounded answer must cover; raw answers remain available for human review.
set -euo pipefail

NS=${NAMESPACE:-ai-platform}
CASES=${CASES:-benchmarks/quality/cases.tsv}
OUT=${OUT:-benchmarks/quality/raw/$(date -u +%Y%m%dT%H%M%SZ).md}
PORT=11437

fail() { echo "FAILED: $1" >&2; exit 1; }
command -v jq >/dev/null || fail "jq is required"
mkdir -p "$(dirname "$OUT")"

POD=$(kubectl -n "$NS" get pod -l app=ollama -o jsonpath='{.items[0].metadata.name}')
DEPLOYED_MODEL=$(kubectl -n "$NS" get deploy ollama -o jsonpath='{.spec.template.spec.initContainers[0].env[?(@.name=="SERVED")].value}')
MODEL=${MODEL_OVERRIDE:-$DEPLOYED_MODEL}
test -n "$POD" && test -n "$MODEL" || fail "Ollama Pod or served model is missing"

kubectl -n "$NS" port-forward "pod/$POD" "$PORT:11434" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -sf "http://127.0.0.1:$PORT/api/tags" >/dev/null && break; sleep 1; done

passed=0 total=0
{
  echo "# Quality run"
  echo
  echo "- Model: \`$MODEL\`"
  echo "- Cases: \`$CASES\`"
  echo
} > "$OUT"

while IFS='|' read -r id prompt terms; do
  [[ -z "$id" || "$id" == \#* ]] && continue
  total=$((total + 1))
  payload=$(jq -nc --arg model "$MODEL" --arg prompt "$prompt" \
    '{model:$model,prompt:$prompt,stream:false,think:false,options:{temperature:0,seed:42,num_predict:512}}')
  answer=$(curl -sS --max-time 180 "http://127.0.0.1:$PORT/api/generate" \
    -H 'Content-Type: application/json' -d "$payload" | jq -r '.response')
  lower=$(tr '[:upper:]' '[:lower:]' <<<"$answer")
  missing=()
  IFS=',' read -r -a required <<<"$terms"
  for term in "${required[@]}"; do
    [[ "$lower" == *"$term"* ]] || missing+=("$term")
  done
  if ((${#missing[@]} == 0)); then verdict=PASS; passed=$((passed + 1)); else verdict="FAIL (missing: ${missing[*]})"; fi
  {
    echo "## $id — $verdict"
    echo
    echo "$answer"
    echo
  } >> "$OUT"
done < "$CASES"

echo "quality $passed/$total; raw answers: $OUT"
test "$passed" = "$total"
