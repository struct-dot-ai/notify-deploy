#!/usr/bin/env bash
# Report a deploy to Struct: POST {api-url}/api/deployments/.
#
# Needs only bash and curl, so it runs in minimal runner containers (no jq,
# python or node). Inputs arrive as STRUCT_* environment variables, never
# interpolated into this script, so no input can inject shell.
#
# By default nothing here can fail the caller's deploy: every problem becomes
# an ::error:: annotation and the step exits 0. fail-on-error=true turns
# those into a failing step.
set -uo pipefail

result="failed"
deployment_id=""

set_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

finish() {
  set_output result "$result"
  set_output deployment-id "$deployment_id"
  exit "${1:-0}"
}

fail_on_error="$(printf '%s' "${STRUCT_FAIL_ON_ERROR:-false}" | tr '[:upper:]' '[:lower:]')"

problem() {
  # Annotation text must stay on one line; %0A is the workflow-command newline.
  local message="${1//$'\n'/%0A}"
  result="failed"
  echo "::error title=Struct notify-deploy::${message}"
  if [ "$fail_on_error" = "true" ]; then
    finish 1
  fi
  finish 0
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

has_control_chars() {
  case "$1" in
    *[[:cntrl:]]*) return 0 ;;
  esac
  return 1
}

json_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

api_key="$(trim "${STRUCT_API_KEY:-}")"
environment="$(trim "${STRUCT_ENVIRONMENT:-}")"
sha="$(trim "${STRUCT_SHA:-}")"
repository="$(trim "${STRUCT_REPOSITORY:-}")"
status="$(trim "${STRUCT_STATUS:-success}")"
previous_sha="$(trim "${STRUCT_PREVIOUS_SHA:-}")"
idempotency_key="$(trim "${STRUCT_IDEMPOTENCY_KEY:-}")"
api_url="$(trim "${STRUCT_API_URL:-https://api.struct.ai}")"

if [ -n "$api_key" ]; then
  echo "::add-mask::${api_key}"
fi

status="$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]')"
case "$status" in
  success | failure | error) ;;
  cancelled | skipped)
    echo "Deploy status is ${status}; nothing reported to Struct."
    result="skipped"
    finish 0
    ;;
  *) problem "status must be success, failure or error (got '${status}')." ;;
esac

if ! command -v curl > /dev/null 2>&1; then
  problem "curl is not installed on this runner; install it before this step."
fi

[ -n "$api_key" ] || problem "api-key is empty. Pass your Struct deployment key from a secret, and check the secret is available to this job."
case "$api_key" in
  pk-*) problem "api-key is an ingest key (pk-...). Use a deployment key (sk-...) from Struct Settings > Deployment Keys." ;;
esac

[ -n "$environment" ] || problem "environment is empty."
[ "${#environment}" -le 255 ] || problem "environment is longer than 255 characters."
if has_control_chars "$environment"; then problem "environment contains control characters."; fi

if [ -z "$sha" ]; then
  sha="$(trim "${STRUCT_DEFAULT_SHA:-}")"
  case "${GITHUB_EVENT_NAME:-}" in
    repository_dispatch | workflow_run | schedule)
      echo "::warning title=Struct notify-deploy::This workflow was triggered by ${GITHUB_EVENT_NAME}, so github.sha is the tip of the default branch, not necessarily the commit you deployed. Pass the deployed commit as the sha input."
      ;;
  esac
fi
if [[ "$sha" =~ ^[0-9.]+[eE][+][0-9]+$ ]]; then
  problem "sha '${sha}' was read as a number. Quote an all-digit SHA in YAML, for example sha: '1234567'."
fi
if ! [[ "$sha" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
  problem "sha must be a commit SHA of 7 to 64 hex characters (got '${sha}'). Branch and tag names are not accepted."
fi
if [ -n "$previous_sha" ] && ! [[ "$previous_sha" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
  problem "previous-sha must be a commit SHA of 7 to 64 hex characters (got '${previous_sha}')."
fi

[ -n "$repository" ] || repository="${GITHUB_REPOSITORY:-}"
if ! [[ "$repository" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
  problem "repository must be owner/name (got '${repository}')."
fi

if [ -z "$idempotency_key" ]; then
  idempotency_key="${repository}:${environment}:${sha}:${GITHUB_RUN_ID:-local}:${GITHUB_RUN_ATTEMPT:-1}:${GITHUB_JOB:-job}"
  if [ "${#idempotency_key}" -gt 255 ]; then
    if command -v sha256sum > /dev/null 2>&1; then
      idempotency_key="sha256:$(printf '%s' "$idempotency_key" | sha256sum | cut -d' ' -f1)"
    else
      idempotency_key="sha256:$(printf '%s' "$idempotency_key" | shasum -a 256 | cut -d' ' -f1)"
    fi
  fi
fi
[ "${#idempotency_key}" -le 255 ] || problem "idempotency-key is longer than 255 characters."
if has_control_chars "$idempotency_key"; then problem "idempotency-key contains control characters."; fi

body="{\"repository\":$(json_string "$repository"),\"sha\":$(json_string "$sha"),\"environment\":$(json_string "$environment"),\"status\":$(json_string "$status"),\"idempotencyKey\":$(json_string "$idempotency_key")"
if [ -n "$previous_sha" ]; then
  body="${body},\"previousSha\":$(json_string "$previous_sha")"
fi
body="${body}}"

endpoint="${api_url%/}/api/deployments/"
response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT

echo "Reporting ${repository}@${sha} reaching '${environment}' (${status}) to Struct."

attempt=1
max_attempts=4
http_code="000"
while :; do
  http_code="$(curl --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --output "$response_file" --write-out '%{http_code}' \
    --request POST "$endpoint" \
    --header @- \
    --data-binary "$body" <<HEADERS
Authorization: Bearer ${api_key}
Content-Type: application/json
User-Agent: struct-notify-deploy/1
HEADERS
  )"
  curl_exit=$?
  if [ "$curl_exit" -eq 0 ] && [ "${http_code:0:1}" = "2" ]; then
    break
  fi
  retryable=false
  if [ "$curl_exit" -ne 0 ] || [ "$http_code" = "429" ] || [ "${http_code:0:1}" = "5" ]; then
    retryable=true
  fi
  if [ "$retryable" != "true" ] || [ "$attempt" -ge "$max_attempts" ]; then
    break
  fi
  delay=$((attempt * ${STRUCT_RETRY_BASE_SECONDS:-3}))
  echo "Struct returned ${http_code} (curl exit ${curl_exit}); retrying in ${delay}s (attempt $((attempt + 1)) of ${max_attempts})."
  sleep "$delay"
  attempt=$((attempt + 1))
done

response="$(head -c 2000 "$response_file" 2>/dev/null || true)"

if [ "$curl_exit" -ne 0 ]; then
  problem "Could not reach ${endpoint} after ${attempt} attempt(s) (curl exit ${curl_exit})."
fi
case "$http_code" in
  2*) ;;
  401) problem "Struct rejected the deployment key (401). Check the key is a current deployment key (sk-...) for your Struct organization." ;;
  403) problem "Struct cannot use this repository (403). Usually Struct's GitHub App is not installed on ${repository}, or is missing a permission. Details: ${response}" ;;
  422) problem "Struct rejected the request (422): ${response}" ;;
  *) problem "Struct returned HTTP ${http_code} after ${attempt} attempt(s): ${response}" ;;
esac

deployment_id="$(printf '%s' "$response" | grep -o '"id" *: *"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
result="recorded"
echo "Struct recorded deployment ${deployment_id:-<unknown id>}."
finish 0
