#!/usr/bin/env bash
# Start the mock in the background for workflow tests; exports STRUCT_TEST_URL.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export REQUESTS_FILE="${RUNNER_TEMP:-/tmp}/struct-requests.jsonl"
: > "$REQUESTS_FILE"
nohup python3 "$here/mock_struct.py" 8765 > /dev/null 2>&1 &
for _ in $(seq 1 50); do curl -s -o /dev/null http://127.0.0.1:8765/ && break; sleep 0.1; done
echo "REQUESTS_FILE=$REQUESTS_FILE" >> "$GITHUB_ENV"
echo "STRUCT_TEST_URL=http://127.0.0.1:8765" >> "$GITHUB_ENV"
