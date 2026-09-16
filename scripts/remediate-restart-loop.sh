#!/usr/bin/env bash
#
# remediate-restart-loop.sh
#
# Demonstrates the "cron job for automated maintenance" pattern used to
# enhance reliability and minimize downtime: periodically check a target's
# health endpoint, and if it is unhealthy, attempt an automated remediation
# (restart) and send a notification.
#
# This is a TEMPLATE/DEMO script. It is safe to run as-is against the
# demo-app in this repo's docker-compose stack, and is written so the
# restart/notify logic is easy to swap for `kubectl rollout restart` in a
# real Kubernetes environment.
#
# Usage:
#   ./remediate-restart-loop.sh [health_url] [restart_command]
#
# Environment variables:
#   HEALTH_URL        URL to curl for a health check (default below)
#   RESTART_CMD       Shell command to run to remediate (default: docker
#                      compose restart demo-app)
#   NOTIFY_WEBHOOK_URL Optional webhook URL to POST a notification to.
#                      Left unset by default - no real webhook is called.
#   MAX_RETRIES        How many times to retry the health check before
#                      declaring the target unhealthy (default: 3)
#   RETRY_DELAY_SECONDS Delay between retries in seconds (default: 5)
#
# How to wire this into cron (traditional host/VM):
#   */5 * * * * /opt/observability/scripts/remediate-restart-loop.sh \
#       >> /var/log/remediate-restart-loop.log 2>&1
#
# How to wire this into Kubernetes:
#   See scripts/k8s-cronjob-example.yaml in this repo for a CronJob
#   manifest that runs an equivalent health-check-and-remediate loop
#   on a schedule inside the cluster.

set -euo pipefail

HEALTH_URL="${1:-${HEALTH_URL:-http://localhost:8080/metrics}}"
RESTART_CMD="${2:-${RESTART_CMD:-docker compose restart demo-app}}"
NOTIFY_WEBHOOK_URL="${NOTIFY_WEBHOOK_URL:-}"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-5}"

log() {
  printf '%s [remediate-restart-loop] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$1"
}

notify() {
  local message="$1"
  log "NOTIFY: ${message}"
  if [[ -n "${NOTIFY_WEBHOOK_URL}" ]]; then
    # Real webhook call - only happens if the operator has configured
    # NOTIFY_WEBHOOK_URL. No default/real webhook is baked into this repo.
    curl -fsS -X POST \
      -H 'Content-Type: application/json' \
      -d "{\"text\": \"${message}\"}" \
      "${NOTIFY_WEBHOOK_URL}" \
      >/dev/null 2>&1 || log "WARNING: failed to deliver notification to webhook"
  fi
}

check_health() {
  curl -fsS --max-time 5 -o /dev/null "${HEALTH_URL}"
}

main() {
  log "Checking health of ${HEALTH_URL}"

  local attempt=1
  while (( attempt <= MAX_RETRIES )); do
    if check_health; then
      log "Health check passed on attempt ${attempt}/${MAX_RETRIES}."
      exit 0
    fi
    log "Health check failed on attempt ${attempt}/${MAX_RETRIES}."
    attempt=$((attempt + 1))
    if (( attempt <= MAX_RETRIES )); then
      sleep "${RETRY_DELAY_SECONDS}"
    fi
  done

  log "Target unhealthy after ${MAX_RETRIES} attempts. Attempting remediation."
  notify "ALERT: ${HEALTH_URL} is unhealthy after ${MAX_RETRIES} checks. Running remediation: ${RESTART_CMD}"

  if eval "${RESTART_CMD}"; then
    log "Remediation command succeeded: ${RESTART_CMD}"
    notify "RESOLVED: remediation command '${RESTART_CMD}' completed for ${HEALTH_URL}"
    exit 0
  else
    log "Remediation command failed: ${RESTART_CMD}"
    notify "ESCALATE: remediation command '${RESTART_CMD}' failed for ${HEALTH_URL}. Manual intervention required."
    exit 1
  fi
}

main "$@"
