#!/usr/bin/env bash
# usage: ./bench.sh <label>   (needs port-forward to svc/ollama on 11434)
MODEL="${MODEL:-qwen2.5:1.5b}"; URL="${URL:-http://localhost:11434}"
for i in 1 2 3; do
  curl -s "$URL/api/generate" -d "{\"model\":\"$MODEL\",\"prompt\":\"Explain what a Kubernetes Service is in 5 sentences.\",\"stream\":false,\"options\":{\"num_predict\":128,\"temperature\":0}}" \
  | jq -r --arg l "$1" --arg i "$i" '"\($l),\($i),\(.eval_count),\((.eval_count / .eval_duration * 1e9 * 100 | floor) / 100)"'
done