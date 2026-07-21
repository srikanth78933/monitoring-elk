# monitoring-elk

Centralized log collection for the backend deployed by
[Enterprise-DevOps-Learning-Platform](https://github.com/srikanth78933/Enterprise-DevOps-Learning-Platform)
(`enterprise-devops` namespace, `mycompany-dev-eks` cluster). Filebeat runs
as a DaemonSet on every node, tails every container's logs, and ships them
to Elasticsearch. Kibana sits on top for search and dashboards.

## Why no Logstash

This is Filebeat -> Elasticsearch -> Kibana, not the full ELK pipeline.
Logstash adds a deployment to run and grok/filter pipelines to maintain,
and buys nothing this setup needs: Filebeat's own processors already
extract structured fields (see below), and there's no fan-in from multiple
heterogeneous sources that would justify a routing layer. Add Logstash
later if you need custom enrichment Filebeat processors can't express.

## Architecture

```
                 ┌─────────────┐
 node 1  ──────▶ │  Filebeat   │─┐
 node 2  ──────▶ │  Filebeat   │─┼──▶ Elasticsearch (single-node) ──▶ Kibana
 node N  ──────▶ │  Filebeat   │─┘
                 └─────────────┘
   DaemonSet, one pod per node        StatefulSet, `logging` namespace
   reads /var/log/containers/*.log
```

Everything lives in the `logging` namespace, separate from
`enterprise-devops`. Elasticsearch and Kibana are ClusterIP-only (no
Ingress, no auth) - reachable from inside the cluster and via
port-forward, not from the internet. That's the deliberate "simple setup"
tradeoff: no TLS/auth to stand up first, at the cost of Kibana only being
reachable when you're port-forwarding.

Filebeat's `dissect` processor parses the backend's console log format
(`application.yml` -> `logging.pattern.console` in the app repo:
`%d{yyyy-MM-dd HH:mm:ss} [%thread] %-5level %logger{36} - %msg%n`) into
`log.level` / `log.logger` / `message` fields, so dashboards can filter and
aggregate by log level instead of doing text search. If that pattern ever
changes in the app repo, update the tokenizer in
`kubernetes/filebeat-configmap.yaml` to match — a mismatch just leaves
lines unparsed (still indexed under `message`), it doesn't drop them.

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

`scripts/deploy-elk.sh` applies the namespace, Elasticsearch, Kibana, and
Filebeat, waits for each rollout, then registers the `filebeat-*` Kibana
data view automatically so logs are ready to browse the moment it exits.

## Access Kibana

```bash
./scripts/kibana-port-forward.sh
```

Then open http://localhost:5601. The `filebeat-*` data view already
exists — go to **Discover**, pick it, and you should see log lines from
every pod in the cluster, including `enterprise-devops` backend/MySQL
pods. Filter to just the app with:

```
kubernetes.namespace : "enterprise-devops"
```

Other apps on the same cluster show up too, without any config change
here — Filebeat runs per-node and isn't scoped to one namespace. E.g.
`simple-java-app` (from the `simple-java-app` repo's Jenkins pipeline)
deploys via `helm upgrade --install simple-java-app ...` with no
`--namespace` flag, so it lands in `default`:

```
kubernetes.namespace : "default"
```

Note: that app has no structured logging (see its `App.java` — one
`System.out.println` at startup, nothing per-request, no levels), so its
lines will show up in Discover but `log.level`/`log.logger` stay empty for
them — the "log volume by level" / "errors table" dashboard panels built
below only have data for apps that log like `enterprise-devops` does.

## Building the dashboards

The data view is created automatically; the dashboards themselves are a
few minutes of clicking in Kibana (Stack Management -> Saved Objects
export/import wasn't worth the fragility here — Kibana's saved-object
schema is version-specific and untested NDJSON is more likely to fail an
import than save you the five minutes). In **Dashboard -> Create
dashboard**, add these panels against the `filebeat-*` data view:

1. **Log volume over time** — Lens, bar chart, X-axis `@timestamp`
   (auto interval), break down by `log.level`. Immediate view of error
   spikes.
2. **Errors table** — Lens, table, filter `log.level : "ERROR"`, rows =
   `message.keyword` (top values), metric = count. Shows which errors are
   noisiest.
3. **Log volume by pod** — Lens, bar or pie chart, break down by
   `kubernetes.pod.name`, filtered to
   `kubernetes.namespace : "enterprise-devops"`. Confirms both backend
   replicas (and MySQL) are actually shipping logs, not just one.

Save the dashboard as e.g. "Backend App Logs".

## Infra/resource metrics (CPU, memory, JVM)

Out of scope here on purpose — this repo is about logs. The app repo
already reserves `/actuator/prometheus` for a Prometheus + Grafana stack
(see `project-06-monitoring-prometheus-grafana` in that repo), which is
the better fit for time-series resource/JVM metrics than bolting
Metricbeat onto this Kibana. Say the word if you'd rather have metrics in
Kibana too and I'll add a Metricbeat DaemonSet here instead.

## Repo layout

```
kubernetes/
  namespace.yaml            → `logging` namespace
  elasticsearch.yaml         → single-node ES, no auth, 10Gi gp2 PVC
  kibana.yaml                → Kibana Deployment + ClusterIP Service
  filebeat-rbac.yaml         → ServiceAccount + ClusterRole for k8s metadata enrichment
  filebeat-configmap.yaml    → filebeat.yml (dissect parsing, ES output)
  filebeat-daemonset.yaml    → one Filebeat pod per node
scripts/
  deploy-elk.sh              → apply everything + wait for rollout
  create-data-view.sh        → registers the `filebeat-*` Kibana data view
  verify-elk.sh               → ES health + Filebeat rollout + doc counts
  kibana-port-forward.sh     → localhost:5601 -> Kibana
Jenkinsfile                  → CI entrypoint, calls the scripts above
```

## Sizing note

Elasticsearch requests 1.5Gi/250m and limits to 2Gi/1000m — tune
`kubernetes/elasticsearch.yaml` to whatever your node group's instance
type actually has headroom for; this wasn't validated against live node
capacity.

## Uninstall

```bash
kubectl delete namespace logging
```

Deletes Elasticsearch, Kibana, Filebeat, and the ES PVC (data included) in
one shot, and leaves `enterprise-devops` untouched.
