#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

# compose up -d returns once containers start, not once they're ready, and the api
# just exits if the db isn't up yet at boot (no retry) - so we can't assume
# started == serving
wait_healthy() {
  local service="$1"
  local timeout="${2:-60}"
  local elapsed=0
  local cid
  cid="$(docker compose ps -q "$service")"
  if [[ -z "$cid" ]]; then
    echo "error: service '${service}' has no running container" >&2
    exit 1
  fi
  until [[ "$(docker inspect --format='{{.State.Health.Status}}' "$cid")" == "healthy" ]]; do
    sleep 2
    elapsed=$((elapsed + 2))
    if (( elapsed >= timeout )); then
      echo "error: ${service} did not become healthy within ${timeout}s" >&2
      exit 1
    fi
  done
}

cmd_up() {
  if [[ ! -f .env ]]; then
    cp .env.example .env
    echo "Created .env from .env.example"
  fi
  docker compose up -d --build
  wait_healthy postgres
  wait_healthy api
  echo "up: postgres and api are healthy"
}

cmd_smoke() {
  # does NOT call cmd_up - this only checks what's already running, doesn't start it.
  # --max-time on every curl below so a down stack fails fast instead of hanging

  local port
  port="$(grep -E '^PORT=' .env 2>/dev/null | tail -1 | cut -d= -f2 || true)"
  port="${port:-8080}"
  local base_url="http://localhost:${port}"

  local resp body status

  if ! resp="$(curl -sS --max-time 10 -w '\n%{http_code}' "${base_url}/health")"; then
    echo "smoke FAIL: cannot reach ${base_url}/health — is the stack up? (run '$(basename "$0") up' first)" >&2
    exit 1
  fi
  body="$(echo "$resp" | sed '$d')"
  status="$(echo "$resp" | tail -n1)"
  if [[ "$status" != "200" ]]; then
    echo "smoke FAIL: GET /health expected 200, got ${status}: ${body}" >&2
    exit 1
  fi

  resp="$(curl -sS --max-time 10 -w '\n%{http_code}' -X POST "${base_url}/users" \
    -H 'Content-Type: application/json' -d '{"name":"ops-smoke-test"}')"
  body="$(echo "$resp" | sed '$d')"
  status="$(echo "$resp" | tail -n1)"
  if [[ "$status" != "201" ]]; then
    echo "smoke FAIL: POST /users expected 201, got ${status}: ${body}" >&2
    exit 1
  fi
  local user_id
  user_id="$(echo "$body" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)"
  if [[ -z "$user_id" ]]; then
    echo "smoke FAIL: could not read id from POST /users response: ${body}" >&2
    exit 1
  fi

  resp="$(curl -sS --max-time 10 -w '\n%{http_code}' -X POST "${base_url}/notifications" \
    -H 'Content-Type: application/json' \
    -d "{\"user_id\":${user_id},\"title\":\"ops smoke\",\"body\":\"created by scripts/ops.sh smoke\",\"channel\":\"in_app\"}")"
  body="$(echo "$resp" | sed '$d')"
  status="$(echo "$resp" | tail -n1)"
  if [[ "$status" != "201" ]]; then
    echo "smoke FAIL: POST /notifications expected 201, got ${status}: ${body}" >&2
    exit 1
  fi
  if ! echo "$body" | grep -q "\"user_id\":${user_id}"; then
    echo "smoke FAIL: notification response missing user_id ${user_id}: ${body}" >&2
    exit 1
  fi

  echo "smoke OK: user_id=${user_id}, notification created and linked correctly"
}

cmd="${1:-}"
case "$cmd" in
  up) cmd_up ;;
  down) docker compose down ;;
  status) docker compose ps ;;
  logs) docker compose logs --tail=200 ;;
  smoke) cmd_smoke ;;
  *) echo "Usage: $(basename "$0") {up|down|status|logs|smoke}" >&2; exit 1 ;;
esac
