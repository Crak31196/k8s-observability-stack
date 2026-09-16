# Runbook: Target Down / Restart Loop

> **Template / demo content.** This runbook illustrates the structure used
> for real incident response and RCA (root cause analysis) work. Fill in
> service-specific detail before using it against a real production service.

Triggered by: `TargetDown`, `PrometheusTargetMissing`, or
`InstanceRestartLoop` alerts (Prometheus/Alertmanager)

## Symptom

- Prometheus has been unable to scrape a target (`up == 0`) for 1+ minute,
  or a target has disappeared from service discovery entirely, or a
  process's start time keeps changing (repeated restarts / crash loop).
- Grafana "Target Up/Down" panel shows the instance as DOWN (red).
- In Kubernetes this typically corresponds to `CrashLoopBackOff`,
  `ImagePullBackOff`, `Pending`, or a pod stuck in `Terminating`.

## Likely Causes

1. The application process crashed on startup (bad config, missing env
   var/secret, unhandled exception).
2. Liveness/readiness probe misconfigured, causing Kubernetes to kill a
   healthy pod repeatedly.
3. Out-of-memory kill (OOMKilled) from too-low memory limits.
4. Image pull failure (bad tag, registry auth expired, registry down).
5. Node-level issue: the underlying node is NotReady, drained, or out of
   disk/CPU/memory (evictions).
6. Network policy or DNS change blocking the scrape path itself
   (Prometheus can't reach the target, target may actually be healthy).

## Diagnostic Steps

1. **Confirm scope.** Is it one pod/instance or every replica of the
   service? Check the Grafana "Target Up/Down" panel and
   `up{job="<job>"}` in Prometheus.
2. **Check pod status and events:**
   `kubectl get pods -n <namespace> -l app=<service> -o wide`
   `kubectl describe pod <pod>` — look at `Last State`, `Reason`
   (`OOMKilled`, `Error`, `CrashLoopBackOff`), and recent `Events`.
3. **Check restart count trend:**
   `changes(process_start_time_seconds{job="<job>"}[15m])` in Prometheus —
   confirms whether this is a genuine crash loop.
4. **Check logs** (`kubectl logs <pod> --previous`, or Splunk/Graylog) for
   the stack trace/error from the last crash before the restart.
5. **Check node health:** `kubectl get nodes`, `kubectl describe node
   <node>` for pressure conditions (`MemoryPressure`, `DiskPressure`).
6. **Check probe config:** `kubectl get deployment <name> -o yaml` and
   review `livenessProbe`/`readinessProbe` timing vs. actual app startup
   time.

## Remediation

- **Bad config/secret:** fix the config/secret and roll the deployment
  (`kubectl rollout restart deployment/<name>`).
- **OOMKilled:** raise the memory limit/request or investigate a memory
  leak; redeploy.
- **Bad probe config:** loosen `initialDelaySeconds`/`failureThreshold`
  to match real startup time; redeploy.
- **Image pull failure:** fix the tag/registry credentials, or roll back
  to the last known-good image.
- **Node issue:** cordon/drain the affected node
  (`kubectl cordon <node>`) and let the scheduler reschedule pods
  elsewhere; escalate to infra for node repair/replacement.
- Confirm recovery: target shows `up == 1` for 5+ consecutive minutes with
  no further restarts before standing down.

## Escalation

- If the workload cannot be scheduled anywhere (cluster capacity
  exhausted), escalate to platform/infra on-call immediately.
- If restarts continue after a config/image fix, escalate to the
  service owner/dev team — this is likely an application-level bug.
- Page the incident commander if the outage crosses the SLA's allowed
  downtime window for the affected service.
- After resolution, write up a short RCA (timeline, root cause,
  remediation, follow-up action items) and link it from the incident
  ticket.
