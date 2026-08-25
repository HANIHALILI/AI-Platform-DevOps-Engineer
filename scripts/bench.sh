#!/usr/bin/env bash
# Measures the deployed inference tier: startup, cold start, resident memory and
# tokens/sec. Run after `make deploy`.
#
#   NAMESPACE   namespace of the release      (default ai-platform)
#   RUNS        sequential measured requests  (default 3)
#   PARALLEL    simultaneous requests         (default 4)
#
# The prompt and the generation options are fixed on purpose: two runs are only
# comparable if they asked the model for the same work. Every duration Ollama
# reports is in nanoseconds; every one printed here is in seconds.
#
# TTFT is measured, not derived: the requests it comes from are streamed, the
# clock is the client's, and it stops on the first chunk carrying generated
# text. Ollama's own load_duration and prompt_eval_duration are reported beside
# it as the server-side components of that wait, not as a substitute for it.
set -euo pipefail

NS=${NAMESPACE:-ai-platform}
RUNS=${RUNS:-3}
PARALLEL=${PARALLEL:-4}

PORT=11435
PROMPT='Explain what a Kubernetes readiness probe is, how it differs from a liveness probe, and when each one should be used. Answer in full sentences.'
OPTIONS='{"num_predict":256,"temperature":0,"seed":42}'

fail() { echo "FAILED: $1" >&2; exit 1; }

# TTFT is timed with the EPOCHREALTIME builtin. Without it the number reported
# would silently be zero rather than a measurement, so refuse instead.
[ -n "${EPOCHREALTIME:-}" ] || fail "bash 5 or newer is required to measure TTFT"

POD=$(kubectl -n "$NS" get pod -l app=ollama -o jsonpath='{.items[0].metadata.name}')
test -n "$POD" || fail "no ollama Pod in namespace $NS"

MODEL=$(kubectl -n "$NS" get deploy ollama \
  -o jsonpath='{.spec.template.spec.initContainers[0].env[?(@.name=="SERVED")].value}')
BASE=$(kubectl -n "$NS" get deploy ollama \
  -o jsonpath='{.spec.template.spec.initContainers[0].env[?(@.name=="BASE_MODEL")].value}')

kubectl -n "$NS" port-forward "pod/$POD" "$PORT:11434" >/dev/null 2>&1 &
PF=$!
TMP=$(mktemp -d)
trap 'kill $PF 2>/dev/null || true; rm -rf "$TMP"' EXIT

API=http://127.0.0.1:$PORT
for _ in $(seq 30); do
  curl -sf --max-time 2 "$API/api/tags" >/dev/null && break
  sleep 1
done
curl -sf --max-time 10 "$API/api/show" -d "{\"model\":\"$MODEL\"}" >/dev/null \
  || fail "$MODEL did not answer through the port-forward to $POD"

# Not streamed. Used only where the whole response is what matters and no TTFT
# is wanted, which is the aggregate run at the end.
generate() {
  curl -sS --max-time 900 "$API/api/generate" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"$PROMPT\",\"stream\":false,\"options\":$OPTIONS}"
}

# Streamed, which is what makes a real TTFT possible. Prints two lines: the
# client-observed TTFT in nanoseconds, then that same request's summary object —
# so the TTFT and the tokens/sec read off the summary describe one generation
# and not two. The clock starts before curl is handed the request and stops on
# the first chunk that carries generated text, so it includes the client, the
# port-forward and the network.
stream() {
  local began
  began=${EPOCHREALTIME/[.,]/}
  curl -sS --no-buffer --max-time 900 "$API/api/generate" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"$PROMPT\",\"stream\":true,\"options\":$OPTIONS}" \
  | {
      first= summary=
      while IFS= read -r chunk; do
        # Qwen3 can stream reasoning in "thinking" before it streams an answer
        # in "response". Both are user-visible generated text, so either is a
        # valid first token. The trailing summary carries an empty response.
        case $chunk in
          *'"thinking":""'|*'"response":""'*) ;;
          *'"thinking":"'*|*'"response":"'*) [ -n "$first" ] || first=${EPOCHREALTIME/[.,]/} ;;
        esac
        case $chunk in *'"done":true'*) summary=$chunk ;; esac
      done
      # EPOCHREALTIME is a builtin, and dropping the separator leaves whole
      # microseconds — so taking a timestamp costs no fork, and the arithmetic
      # can wait until the stream is over. A `date` call here would put its own
      # process spawn inside the interval being measured.
      echo "$(( first ? (first - began) * 1000 : 0 ))"
      echo "$summary"
    }
}

# Empty, not a failure, when the field is absent: a request that timed out or
# came back an error has no eval_count, and that must not take the run down
# without saying why.
num()  { grep -oE "\"$2\": *[0-9]+" <<<"$1" | head -1 | sed 's/.*[: ]//' || true; }
secs() { awk -v n="$1" 'BEGIN { printf "%.2f", n/1e9 }'; }

echo "== configuration"
echo "pod                  $POD"
echo "served model         $MODEL"
echo "base model           $BASE   (quantization ${BASE##*-})"
echo "options              $OPTIONS"
echo "runs / parallel      $RUNS / $PARALLEL"
kubectl -n "$NS" get deploy ollama -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | grep OLLAMA_
kubectl -n "$NS" get deploy ollama -o jsonpath='limits: {.spec.template.spec.containers[0].resources.limits}{"\n"}'

echo
echo "== startup"
# The init container pulls the weights and builds the served model; the server
# only starts once it exits. A first ever start includes the download and a
# later one reads the PVC, so the two are not comparable.
started=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.initContainerStatuses[0].state.terminated.startedAt}')
finished=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.initContainerStatuses[0].state.terminated.finishedAt}')
scheduled=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.startTime}')
ready=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}')
echo "init container       $(( $(date -d "$finished" +%s) - $(date -d "$started" +%s) )) s   (pull + ollama create)"
echo "scheduled to Ready   $(( $(date -d "$ready" +%s) - $(date -d "$scheduled" +%s) )) s   (init, then the server and its probes)"

echo
echo "== cold start (model unloaded first)"
# keep_alive 0 unloads the model, so the next request pays the load again.
curl -sS --max-time 60 "$API/api/generate" -d "{\"model\":\"$MODEL\",\"keep_alive\":0}" >/dev/null
for _ in $(seq 15); do
  curl -sS --max-time 5 "$API/api/ps" | grep -q "$MODEL" || break
  sleep 1
done
cold=$(stream)
summary=${cold#*$'\n'}
echo "TTFT                 $(secs "${cold%%$'\n'*}") s   (client-observed: send -> first streamed token)"
echo "  model load         $(secs "$(num "$summary" load_duration)") s   (Ollama-reported: weights off the PVC)"
echo "  prompt eval        $(secs "$(num "$summary" prompt_eval_duration)") s   (Ollama-reported: prompt prefill)"

echo
echo "== resident memory"
# SIZE is what this model holds; PROCESSOR says how much of it is on the CPU.
kubectl -n "$NS" exec deploy/ollama -- ollama ps
RSS=$(kubectl top pod "$POD" -n "$NS" --no-headers 2>/dev/null | awk '{ print $3 }' || true)
echo "container RSS        ${RSS:-unavailable}   (the whole process, every model it holds)"

echo
echo "== warm requests ($RUNS runs, one at a time)"
stream >/dev/null   # warm-up, discarded
sum=0
for i in $(seq "$RUNS"); do
  out=$(stream)
  summary=${out#*$'\n'}
  count=$(num "$summary" eval_count)
  rate=$(awk -v c="$count" -v d="$(num "$summary" eval_duration)" 'BEGIN { printf "%.2f", c/(d/1e9) }')
  sum=$(awk -v s="$sum" -v r="$rate" 'BEGIN { printf "%.2f", s + r }')
  echo "run $i               TTFT $(secs "${out%%$'\n'*}") s   $count tok   $rate tok/s"
done
awk -v s="$sum" -v n="$RUNS" 'BEGIN { printf "mean                 %.2f tok/s\n", s/n }'
# Both numbers on a run line come from the one request: the TTFT off the client's
# clock, the rate off eval_count/eval_duration in that request's own summary.
# eval_count falls short of num_predict whenever the model stops on its own, so
# runs compare on tok/s and not on wall time.

echo
echo "== aggregate throughput ($PARALLEL at once)"
began=$(date +%s%N)
pids=""
for i in $(seq "$PARALLEL"); do
  generate > "$TMP/p$i" &
  pids="$pids $!"
done
# These PIDs and not a bare `wait`: the port-forward is a background job too and
# it never exits.
wait $pids
wall=$(awk -v a="$began" -v b="$(date +%s%N)" 'BEGIN { printf "%.2f", (b-a)/1e9 }')
tokens=$(for i in $(seq "$PARALLEL"); do num "$(cat "$TMP/p$i")" eval_count; done | awk '{ s += $1 } END { print s+0 }')
echo "$PARALLEL requests           $tokens tok  $wall s wall  $(awk -v t="$tokens" -v w="$wall" 'BEGIN { printf "%.2f", t/w }') tok/s aggregate"
# OLLAMA_NUM_PARALLEL is what moves this number. At 1 the server serialises, so
# what is measured is queueing rather than parallel decode.
