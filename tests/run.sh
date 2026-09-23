#!/usr/bin/env bash
# Runs notify.sh against tests/mock_struct.py. Needs bash, curl, python3.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
work="$(mktemp -d)"
port="${MOCK_PORT:-8765}"
export REQUESTS_FILE="$work/requests.jsonl"
: > "$REQUESTS_FILE"
python3 "$here/mock_struct.py" "$port" &
mock_pid=$!
trap 'kill $mock_pid 2>/dev/null; rm -rf "$work"' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.1; done

pass=0; fail=0
SHA=0123456789abcdef0123456789abcdef01234567

# run NAME [VAR=value ...] -> sets $out (stdout+stderr), $code, $result, $dep_id
run() {
  local name="$1"; shift
  : > "$work/gh_output"
  out="$(env -i PATH="$PATH" HOME="$HOME" \
    GITHUB_OUTPUT="$work/gh_output" GITHUB_REPOSITORY=acme/api GITHUB_RUN_ID=111 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=deploy \
    GITHUB_EVENT_NAME=push STRUCT_DEFAULT_SHA="$SHA" STRUCT_API_URL="http://127.0.0.1:$port" \
    STRUCT_API_KEY=sk-good STRUCT_ENVIRONMENT=production STRUCT_RETRY_BASE_SECONDS=0 "$@" \
    bash "$root/notify.sh" 2>&1)"
  code=$?
  result="$(sed -n 's/^result=//p' "$work/gh_output")"
  dep_id="$(sed -n 's/^deployment-id=//p' "$work/gh_output")"
  current="$name"
}
last_body() { tail -n 1 "$REQUESTS_FILE" | python3 -c "import json,sys; print(json.dumps(json.loads(sys.stdin.read())['body'], sort_keys=True))"; }
field() { tail -n 1 "$REQUESTS_FILE" | python3 -c "import json,sys; r=json.loads(sys.stdin.read()); print(r['body'].get('$1', '<absent>'))"; }
count() { wc -l < "$REQUESTS_FILE" | tr -d ' '; }
check() {
  if eval "$1"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL [$current]: $1"; echo "$out" | sed 's/^/    /'; fi
}

run "defaults: push, sha from github.sha, repo from github.repository"
check '[ "$code" = 0 ] && [ "$result" = recorded ]'
check '[ "$(field sha)" = "$SHA" ] && [ "$(field repository)" = acme/api ] && [ "$(field environment)" = production ]'
check '[ "$(field status)" = success ] && [ "$(field previousSha)" = "<absent>" ]'
check '[ "$(field idempotencyKey)" = "acme/api:production:$SHA:111:1:deploy" ]'
check '[ "$dep_id" = "dep_$(printf %s "acme/api:production:$SHA:111:1:deploy" | shasum -a 256 | cut -c1-12)" ]'
check '[ "$(tail -n1 "$REQUESTS_FILE" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())[\"authorization\"])")" = "Bearer sk-good" ]'
check 'echo "$out" | grep -q "::add-mask::sk-good"'

first_id="$dep_id"
run "retry with the same key returns the same deployment" 
check '[ "$dep_id" = "$first_id" ]'

run "second service, same sha, different job -> different key" GITHUB_JOB=deploy-other
check '[ "$result" = recorded ] && [ "$dep_id" != "$first_id" ]'

run "dispatch-style override: sha, previous sha, repository" STRUCT_SHA=abcdef1 STRUCT_PREVIOUS_SHA=1234567 STRUCT_REPOSITORY=acme/platform GITHUB_EVENT_NAME=repository_dispatch
check '[ "$result" = recorded ] && [ "$(field sha)" = abcdef1 ] && [ "$(field previousSha)" = 1234567 ] && [ "$(field repository)" = acme/platform ]'
check '! echo "$out" | grep -q "::warning"'

run "repository_dispatch without sha warns" GITHUB_EVENT_NAME=repository_dispatch
check '[ "$result" = recorded ] && echo "$out" | grep -q "::warning title=Struct notify-deploy::This workflow was triggered by repository_dispatch"'

run "explicit idempotency key and padded inputs are trimmed" STRUCT_IDEMPOTENCY_KEY="  checkout-prod-abc  " STRUCT_ENVIRONMENT="  production "
check '[ "$(field idempotencyKey)" = checkout-prod-abc ] && [ "$(field environment)" = production ]'

run "quotes and backslashes in environment stay valid JSON" STRUCT_ENVIRONMENT='prod "eu" \ west'
check '[ "$result" = recorded ] && [ "$(field environment)" = "prod \"eu\" \\ west" ]'

run "failure status (job.status) is reported" STRUCT_STATUS=Failure
check '[ "$result" = recorded ] && [ "$(field status)" = failure ]'

before=$(count)
run "cancelled reports nothing" STRUCT_STATUS=cancelled
check '[ "$code" = 0 ] && [ "$result" = skipped ] && [ "$(count)" = "$before" ]'

run "unknown status is a problem" STRUCT_STATUS=started
check '[ "$code" = 0 ] && [ "$result" = failed ] && echo "$out" | grep -q "::error"'

before=$(count)
run "branch name as sha is rejected before any request" STRUCT_SHA=main
check '[ "$code" = 0 ] && [ "$result" = failed ] && [ "$(count)" = "$before" ] && echo "$out" | grep -q "Branch and tag names"'

run "numeric-looking sha gets a quoting hint" STRUCT_SHA=1.11111122222223E+39
check '[ "$result" = failed ] && echo "$out" | grep -q "read as a number"'

run "ingest key is rejected" STRUCT_API_KEY=pk-123
check '[ "$result" = failed ] && echo "$out" | grep -q "ingest key"'

run "empty key is rejected" STRUCT_API_KEY=
check '[ "$result" = failed ] && echo "$out" | grep -q "api-key is empty"'

run "bad key: annotation, deploy job still passes" STRUCT_API_KEY=sk-bad
check '[ "$code" = 0 ] && [ "$result" = failed ] && echo "$out" | grep -q "rejected the deployment key (401)"'

run "bad key with fail-on-error fails the step" STRUCT_API_KEY=sk-bad STRUCT_FAIL_ON_ERROR=true
check '[ "$code" = 1 ] && [ "$result" = failed ]'

before=$(count)
run "transient 503 is retried" STRUCT_API_KEY=sk-flaky
check '[ "$result" = recorded ] && [ "$(( $(count) - before ))" = 2 ]'

before=$(count)
run "server down: 4 attempts, deploy job still passes" STRUCT_API_KEY=sk-down
check '[ "$code" = 0 ] && [ "$result" = failed ] && [ "$(( $(count) - before ))" = 4 ]'

run "unreachable api: deploy job still passes" STRUCT_API_URL=http://127.0.0.1:9
check '[ "$code" = 0 ] && [ "$result" = failed ] && echo "$out" | grep -q "Could not reach"'

run "trailing slash on api-url" STRUCT_API_URL="http://127.0.0.1:$port/"
check '[ "$result" = recorded ]'

long_env="$(printf 'e%.0s' $(seq 1 250))"
run "long default key is hashed under 255 chars" STRUCT_ENVIRONMENT="$long_env"
check '[ "$result" = recorded ] && case "$(field idempotencyKey)" in sha256:*) true;; *) false;; esac'

run "bad repository" STRUCT_REPOSITORY=just-a-name
check '[ "$result" = failed ] && echo "$out" | grep -q "owner/name"'

echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
