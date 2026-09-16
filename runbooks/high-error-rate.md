# Runbook: High Error Rate

> **Template / demo content.** This runbook illustrates the structure used
> for real incident response and RCA (root cause analysis) work. Fill in
> service-specific detail before using it against a real production service.

Triggered by: `HighErrorRate` alert (Prometheus/Alertmanager)

## Symptom

- More than 5% of HTTP responses from the service are returning a 5xx
  status code, sustained for 5+ minutes.
- Grafana "Service Health" dashboard shows the error-rate panel above the
  SLA threshold line.
- Customers/users may be reporting failed requests, timeouts, or partial
  outages before this alert fires if the threshold is set too high.

## Likely Causes

1. A recent deployment introduced a regression (bad config, bad code path,
   failed migration).
2. A downstream dependency (database, cache, third-party API) is degraded
   or unreachable.
3. Resource exhaustion on the pod/node (CPU throttling, OOMKilled, disk
   full) causing failed requests.
4. Connection pool / thread pool exhaustion under load.
5. Bad or expired credentials/certificates to a downstream service.

## Diagnostic Steps

1. **Check the dashboard.** Confirm scope: is this one instance, one
   Kubernetes deployment, or the whole service?
   `sum by (job) (rate(http_requests_total{code=~"5.."}[5m]))`
2. **Correlate with deploys.** Check recent `kubectl rollout history` /
   CI-CD deploy logs against the time the error rate started climbing.
3. **Check pod status.**
   `kubectl get pods -n <namespace> -l app=<service>`
   `kubectl describe pod <pod>` for restarts, OOMKilled, CrashLoopBackOff.
4. **Check logs** in Splunk/Graylog for stack traces or error spikes
   correlated with the alert window. Filter by `status:>=500`.
5. **Check downstream dependencies** (DB connection errors, upstream API
   error rates, DNS resolution failures).
6. **Check resource metrics** (CPU/memory) via node-exporter/cAdvisor
   dashboards for throttling or memory pressure.

## Remediation

- **If caused by a bad deploy:** roll back
  (`kubectl rollout undo deployment/<name>`) or `helm rollback`.
- **If caused by resource exhaustion:** scale out
  (`kubectl scale deployment/<name> --replicas=N`) or raise
  resource limits/requests.
- **If caused by a downstream dependency:** fail over to a healthy
  replica/region, or apply a circuit breaker / retry-with-backoff if
  available, and open a ticket with the dependency's owner.
- **If caused by expired credentials/certs:** rotate the credential/cert
  and redeploy.
- Confirm recovery on the Grafana dashboard: error-rate panel back under
  threshold for at least 10 minutes before standing down.

## Escalation

- If not resolved within 15 minutes of triage, escalate to the on-call
  service owner per the SLA policy.
- If the root cause is a shared platform dependency (e.g. shared database,
  ingress, DNS), escalate to the platform/infra on-call in parallel.
- Page the incident commander if the error rate impacts multiple services
  or breaches the customer-facing SLA for longer than the agreed window.
- After resolution, write up a short RCA (timeline, root cause,
  remediation, follow-up action items) and link it from the incident
  ticket.
