# monitoring-elk

Centralized log and metric collection for apps running on
`mycompany-dev-eks` (currently `simple-java-app` in the `default`
namespace; originally built against
[Enterprise-DevOps-Learning-Platform](https://github.com/srikanth78933/Enterprise-DevOps-Learning-Platform)'s
`enterprise-devops` backend, which isn't deployed on this cluster right
now). Filebeat and Metricbeat both run as DaemonSets on every node -
Filebeat tails every container's logs, Metricbeat pulls CPU/memory from
each node's kubelet - and ship to a single Elasticsearch, with Kibana on
top for search and dashboards.

## Why no Logstash

This is Filebeat/Metricbeat -> Elasticsearch -> Kibana, not the full ELK
pipeline. Logstash adds a deployment to run and grok/filter pipelines to
maintain, and buys nothing this setup needs: Filebeat's own processors
already extract structured fields (see below), and there's no fan-in from
multiple heterogeneous sources that would justify a routing layer. Add
Logstash later if you need custom enrichment Filebeat processors can't
express.

## Architecture

```
                 ┌─────────────┐
 node 1  ──────▶ │  Filebeat   │─┐
                 │  Metricbeat │─┤
 node 2  ──────▶ │  Filebeat   │─┼──▶ Elasticsearch (single-node) ──▶ Kibana
                 │  Metricbeat │─┤
 node N  ──────▶ │  Filebeat   │─┘
                 │  Metricbeat │
                 └─────────────┘
   DaemonSets, one pod per node       StatefulSet, `logging` namespace
   Filebeat:  /var/log/containers/*.log
   Metricbeat: each node's kubelet (:10250/stats/summary) + /proc, /sys
```

Everything lives in the `logging` namespace, separate from app
namespaces. Elasticsearch and Kibana are ClusterIP-only (no Ingress, no
auth) - reachable from inside the cluster and via port-forward, not from
the internet. That's the deliberate "simple setup" tradeoff: no TLS/auth
to stand up first, at the cost of Kibana only being reachable when you're
port-forwarding.

Metricbeat's `kubernetes` module (metricsets: `node`, `pod`, `container`,
`volume`) reads directly from each node's kubelet - no kube-state-metrics
dependency, so no separate Deployment-mode component, just the DaemonSet.
That means cluster-level object metrics (desired vs. available replicas,
etc.) aren't collected, only resource usage. Add kube-state-metrics +
the `state_*` metricsets later if you need that.

Filebeat's `dissect` processor parses a Logback-style console log line
(`%d{yyyy-MM-dd HH:mm:ss} [%thread] %-5level %logger{36} - %msg%n` - the
`enterprise-devops` backend's format) into `log.level` / `log.logger` /
`message` fields, so dashboards can filter and aggregate by log level
instead of doing text search. Apps that don't log in this format (e.g.
`simple-java-app`, which just does a bare `System.out.println`) still get
indexed, just without those structured fields - `ignore_failure: true`
means a mismatch never drops the line, only leaves it less parsed. Update
the tokenizer in `kubernetes/filebeat-configmap.yaml` if the app's log
format changes.

## Deploy

**Via Jenkins**: point a pipeline job at this repo's `Jenkinsfile`. It
reuses the `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` Jenkins
credentials already configured for the app repo's pipeline (same cluster,
same account) — no new credentials to add.

**Manually**:
```bash
aws eks update-kubeconfig --name mycompany-dev-eks --region us-east-1
./scripts/deploy-elk.sh
./scripts/verify-elk.sh
```

`scripts/deploy-elk.sh` applies the namespace, Elasticsearch, Kibana,
Filebeat, and Metricbeat, waits for each rollout, then runs
`scripts/import-dashboards.sh` to load `kibana/saved-objects/dashboards.ndjson`
- both data views and both dashboards (see below) exist the moment it
exits, no manual clicking required. Every step is a plain `kubectl apply`
or an `overwrite=true` import, so rerunning this against a cluster that
already has everything deployed is a safe no-op.

## Access Kibana

```bash
./scripts/kibana-port-forward.sh
```

Then open http://localhost:5601. Two dashboards are already built:

- **Backend App Logs** — http://localhost:5601/app/dashboards#/view/dashboard-backend-app-logs
  Log volume over time by namespace, log volume by pod, and a raw
  ERROR-level table (empty until an app with leveled logging, like
  `enterprise-devops`, actually logs an error - `simple-java-app` never
  will, see above).
- **Infrastructure Metrics** — http://localhost:5601/app/dashboards#/view/dashboard-infra-metrics
  Node CPU/memory usage over time, and top-10 pod CPU/memory usage over
  time - sourced from Metricbeat.

Or go to **Discover** and pick the `App Logs (filebeat-*)` data view
directly. Every pod on the cluster shows up (Filebeat isn't scoped to one
namespace); filter to one app with e.g.:

```
kubernetes.namespace : "default"
```

(that's where `simple-java-app` lands - its Helm chart/Jenkins pipeline
set no `--namespace`, so it falls back to `default`).

## Dashboards are code, not clicks

`kibana/saved-objects/dashboards.ndjson` is a full export (via
`POST /api/saved_objects/_export` with `includeReferencesDeep: true`) of
both dashboards and everything they reference - data views,
visualizations, the saved search. `scripts/import-dashboards.sh` re-imports
it with `overwrite=true`, so it's rerun-safe and reproduces the exact same
dashboards on a fresh cluster. If you change a dashboard by hand in the
Kibana UI, re-export it the same way to keep this file in sync:

```bash
kubectl run kb-export --rm -i --restart=Never -n logging \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -X POST "http://kibana:5601/api/saved_objects/_export" \
    -H "kbn-xsrf: true" -H "Content-Type: application/json" \
    -d '{"objects":[{"type":"dashboard","id":"dashboard-backend-app-logs"},{"type":"dashboard","id":"dashboard-infra-metrics"}],"includeReferencesDeep":true}' \
  > kibana/saved-objects/dashboards.ndjson
```

(strip any stray `pod "kb-export" deleted...` text `kubectl run --rm`
appends to stdout before committing - check the last line parses as JSON.)

## Repo layout

```
kubernetes/
  namespace.yaml              → `logging` namespace
  elasticsearch.yaml          → single-node ES, no auth, 10Gi gp2 PVC, fsGroup 1000
  kibana.yaml                  → Kibana Deployment + ClusterIP Service
  filebeat-rbac.yaml           → ServiceAccount + ClusterRole for k8s metadata enrichment
  filebeat-configmap.yaml      → filebeat.yml (dissect parsing, ES output)
  filebeat-daemonset.yaml      → one Filebeat pod per node
  metricbeat-rbac.yaml         → ServiceAccount + ClusterRole (nodes/stats, /metrics)
  metricbeat-configmap.yaml    → metricbeat.yml (kubernetes + system modules)
  metricbeat-daemonset.yaml    → one Metricbeat pod per node
kibana/saved-objects/
  dashboards.ndjson            → both dashboards + data views + visualizations, exported
scripts/
  deploy-elk.sh                → apply everything + wait for rollout + import dashboards
  import-dashboards.sh         → (re)imports dashboards.ndjson, overwrite=true
  verify-elk.sh                → ES health + DaemonSet rollout + log/metric doc counts
  kibana-port-forward.sh       → localhost:5601 -> Kibana
Jenkinsfile                    → CI entrypoint, calls the scripts above
```

## Sizing note (validated live, not guessed)

This was deployed and debugged against the real cluster - the numbers
below are what actually worked, not defaults:

- **Nodes are small**: 2-4x t3.small-class (~1.42Gi allocatable memory
  each). Elasticsearch's "normal" defaults (1g heap, 1.5Gi request) don't
  fit - that request alone exceeds one node's total capacity, so the pod
  never schedules and cluster-autoscaler can't help (a same-type new node
  hits the identical ceiling).
- **Elasticsearch** (`kubernetes/elasticsearch.yaml`): 512m heap
  (`-Xms512m -Xmx512m`), 700Mi/1Gi request/limit. Also needs
  `securityContext.fsGroup: 1000` - without it, a freshly provisioned EBS
  volume mounts owned by root while the ES container runs as uid 1000, so
  it can't write its own `node.lock` and crash-loops.
- **Kibana** (`kubernetes/kibana.yaml`): 700Mi/1Gi request/limit - a 600Mi
  limit OOM-kills its Node.js process during startup even with default
  plugins.
- Deploying this stack made cluster-autoscaler grow the node group 2→4.
  There's real but not huge headroom left (~500Mi+ free per node at last
  check) - re-run `kubectl describe node <name> | grep -A5 "Allocated resources"`
  before adding more to this namespace.

## Uninstall

```bash
kubectl delete namespace logging
```

Deletes Elasticsearch, Kibana, Filebeat, Metricbeat, and the ES PVC (data
included) in one shot, and leaves app namespaces untouched.
