#!/usr/bin/env bash
set -euo pipefail

kubectl -n monty port-forward svc/monty-server 8000:8000 &
pf_pid=$!
trap 'kill "$pf_pid" 2>/dev/null || true; wait "$pf_pid" 2>/dev/null || true' EXIT

for _ in {1..30}; do
  if curl --fail --silent --max-time 2 http://localhost:8000/health > /dev/null; then
    break
  fi
  sleep 2
done
curl --fail --silent --show-error --max-time 5 http://localhost:8000/health
result=$(curl --fail --silent --show-error --max-time 30 \
  --header 'Content-Type: text/plain' --data-binary '1 + 1' http://localhost:8000/run)
if [[ "$result" != 2 ]]; then
  printf 'Unexpected execution result: %s\n' "$result" >&2
  exit 1
fi
