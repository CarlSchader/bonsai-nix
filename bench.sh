#!/usr/bin/env bash
# Streaming decode benchmark for the Bonsai 2 27B llama-server.
# Sends a mixed battery of prompts through /v1/chat/completions and reports
# per-prompt and aggregate tokens/s (net of TTFT). With CONCURRENCY>1 the
# prompts are sent simultaneously, which is what a fleet of agents looks like.
#
# Usage: ./bench.sh [base_url] [model]
# Env:   MAX_TOKENS=800  CONCURRENCY=1  REASONING=medium|xhigh (default: server default)
set -euo pipefail
BASE="${1:-http://127.0.0.1:8080}"
MODEL="${2:-bonsai-2-27b}"
MAX_TOKENS="${MAX_TOKENS:-800}"
CONCURRENCY="${CONCURRENCY:-1}"
REASONING="${REASONING:-}"

PROMPTS=(
  "Write a Python function that parses an ISO-8601 timestamp without external libraries, with type hints and docstring, and a small pytest suite."
  "Prove that the sum of the first n odd numbers is n^2, then compute the sum of the first 250 odd numbers step by step."
  "Explain how CUDA graphs reduce launch overhead and when they cannot be used. Be precise and technical."
  "Write a short story (about 300 words) about a lighthouse keeper who discovers the sea has stopped moving."
  "Refactor this bash into a robust script with set -euo pipefail, functions and argument parsing: for f in *.log; do gzip \$f; mv \$f.gz archive/; done"
  "Implement an LRU cache in Rust with O(1) get/put, generic over key and value, with unit tests."
  "Explain the difference between optimistic and pessimistic locking with a concrete SQL example of each."
  "Write a TypeScript function that deeply merges two objects, with correct types, and describe its edge cases."
)

python3 - "$BASE" "$MODEL" "$MAX_TOKENS" "$CONCURRENCY" "$REASONING" "${PROMPTS[@]}" <<'EOF'
import json, sys, time, urllib.request, statistics
from concurrent.futures import ThreadPoolExecutor

base, model, max_tokens, conc, reasoning, *prompts = sys.argv[1:]
conc = int(conc)

def run(p):
    req_body = {
        "model": model,
        "stream": True,
        "max_tokens": int(max_tokens),
        "stream_options": {"include_usage": True},
        "messages": [{"role": "user", "content": p}],
    }
    if reasoning:
        req_body["reasoning_effort"] = reasoning
    req = urllib.request.Request(
        base + "/v1/chat/completions", json.dumps(req_body).encode(),
        {"Content-Type": "application/json"},
    )
    t0 = time.perf_counter(); t_first = None; usage = None; n_chunks = 0
    with urllib.request.urlopen(req, timeout=3600) as r:
        for line in r:
            if not line.startswith(b"data: ") or line.strip() == b"data: [DONE]":
                continue
            ev = json.loads(line[6:])
            if ev.get("usage"):
                usage = ev["usage"]
            ch = ev.get("choices") or []
            d = (ch[0].get("delta") or {}) if ch else {}
            if d.get("content") or d.get("reasoning_content"):
                if t_first is None:
                    t_first = time.perf_counter()
                n_chunks += 1
    t_end = time.perf_counter()
    n = usage["completion_tokens"] if usage else n_chunks
    ttft = (t_first or t_end) - t0
    rate = n / max(t_end - (t_first or t0), 0.001)
    return p, n, ttft, rate, t_end - t0

t0 = time.perf_counter()
with ThreadPoolExecutor(conc) as ex:
    results = list(ex.map(run, prompts))
wall = time.perf_counter() - t0

for p, n, ttft, rate, _ in results:
    print(f"{rate:6.1f} tok/s  ({n} tok, TTFT {ttft:.2f}s)  {p[:60]}...")
rates = [r[3] for r in results]
total = sum(r[1] for r in results)
print(f"\nconcurrency {conc}: per-stream median {statistics.median(rates):.1f} tok/s "
      f"(min {min(rates):.1f}, max {max(rates):.1f}); aggregate {total/wall:.1f} tok/s over {wall:.1f}s")
EOF
