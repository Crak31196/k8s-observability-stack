#!/usr/bin/env bash
#
# smoke-test.sh
#
# End-to-end smoke test for the Kubernetes Observability & Alerting Stack.
# Brings the full docker-compose stack up, waits for services to become
# healthy, then asserts that:
#   - Prometheus reports itself healthy (/-/healthy)
#   - Prometheus's own targets API shows the demo-app target as "up"
#   - Grafana reports itself healthy (/api/health)
#   - Alertmanager reports itself healthy (/-/healthy)
# Finally tears the stack down.
#
# Usage: ./tests/smoke-test.sh
# Exit code 0 = all assertions passed, non-zero = failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}" || exit 1

PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
ALERTMANAGER_PORT="${ALERTMANAGER_PORT:-9093}"

MAX_WAIT_SECONDS=120
POLL_INTERVAL_SECONDS=3

FAILURES=0

log() {
  printf '[smoke-test] %s\n' "$1"
}

fail() {
  printf '[smoke-test] FAIL: %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

pass() {
  printf '[smoke-test] PASS: %s\n' "$1"
}

# shellcheck disable=SC2317
cleanup() {
  log "Tearing down stack (docker compose down -v)..."
  docker compose down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for_http() {
  local url="$1"
  local name="$2"
  local waited=0
  while (( waited < MAX_WAIT_SECONDS )); do
    if curl -fsS --max-time 5 "${url}" >/dev/null 2>&1; then
      pass "${name} became reachable at ${url} after ${waited}s"
      return 0
    fi
    sleep "${POLL_INTERVAL_SECONDS}"
    waited=$((waited + POLL_INTERVAL_SECONDS))
  done
  fail "${name} did not become reachable at ${url} within ${MAX_WAIT_SECONDS}s"
  return 1
}

log "Starting stack: docker compose up -d"
if ! docker compose up -d; then
  fail "docker compose up -d failed"
  exit 1
fi

log "Waiting for services to come up..."
wait_for_http "http://localhost:${PROMETHEUS_PORT}/-/healthy" "Prometheus"
wait_for_http "http://localhost:${GRAFANA_PORT}/api/health" "Grafana"
wait_for_http "http://localhost:${ALERTMANAGER_PORT}/-/healthy" "Alertmanager"

# --- Assertion 1: Prometheus health endpoint ---
log "Checking Prometheus /-/healthy ..."
PROM_HEALTH="$(curl -fsS --max-time 5 "http://localhost:${PROMETHEUS_PORT}/-/healthy")"
if [[ "${PROM_HEALTH}" == *"Healthy"* ]]; then
  pass "Prometheus /-/healthy returned: ${PROM_HEALTH}"
else
  fail "Prometheus /-/healthy returned unexpected body: ${PROM_HEALTH}"
fi

# --- Assertion 2: demo-app target is "up" in Prometheus's targets API ---
log "Waiting for demo-app target to report up=1 in Prometheus..."
DEMO_APP_UP="false"
waited=0
while (( waited < MAX_WAIT_SECONDS )); do
  TARGETS_JSON="$(curl -fsS --max-time 5 "http://localhost:${PROMETHEUS_PORT}/api/v1/targets" || true)"
  DEMO_APP_HEALTH="$(echo "${TARGETS_JSON}" | jq -r '.data.activeTargets[] | select(.labels.job=="demo-app") | .health' 2>/dev/null || true)"
  if [[ "${DEMO_APP_HEALTH}" == "up" ]]; then
    DEMO_APP_UP="true"
    break
  fi
  sleep "${POLL_INTERVAL_SECONDS}"
  waited=$((waited + POLL_INTERVAL_SECONDS))
done

if [[ "${DEMO_APP_UP}" == "true" ]]; then
  pass "demo-app target reports health=up in Prometheus targets API"
else
  fail "demo-app target did not report health=up within ${MAX_WAIT_SECONDS}s"
  log "Last targets API response was:"
  echo "${TARGETS_JSON:-<empty>}"
fi

# --- Assertion 3: Grafana health endpoint ---
log "Checking Grafana /api/health ..."
GRAFANA_HEALTH="$(curl -fsS --max-time 5 "http://localhost:${GRAFANA_PORT}/api/health")"
if echo "${GRAFANA_HEALTH}" | jq -e '.database == "ok"' >/dev/null 2>&1; then
  pass "Grafana /api/health returned: ${GRAFANA_HEALTH}"
else
  fail "Grafana /api/health returned unexpected body: ${GRAFANA_HEALTH}"
fi

# --- Assertion 4: Alertmanager health endpoint ---
log "Checking Alertmanager /-/healthy ..."
AM_HEALTH_CODE="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${ALERTMANAGER_PORT}/-/healthy")"
if [[ "${AM_HEALTH_CODE}" == "200" ]]; then
  pass "Alertmanager /-/healthy returned HTTP ${AM_HEALTH_CODE}"
else
  fail "Alertmanager /-/healthy returned HTTP ${AM_HEALTH_CODE}"
fi

if (( FAILURES > 0 )); then
  log "Smoke test FAILED with ${FAILURES} failing assertion(s)."
  exit 1
fi

log "All smoke test assertions passed."
exit 0
