#!/usr/bin/env bash
# Deploys Elasticsearch, Kibana, Filebeat, and Metricbeat into the
# `logging` namespace of the existing EKS cluster. Local equivalent of the
# Jenkinsfile "Deploy ELK stack" stage - run this directly to test a change
# before wiring it into Jenkins, or to redeploy manually.
#
# Assumes kubectl already points at the target cluster - run
# `aws eks update-kubeconfig --name <cluster> --region <region>` first if
# it doesn't (see Enterprise-DevOps-Learning-Platform's
# scripts/configure-kubeconfig.sh for that project's cluster name).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NAMESPACE="${LOGGING_NAMESPACE:-logging}"

echo "==> Namespace"
kubectl apply -f "${ROOT_DIR}/kubernetes/namespace.yaml"

echo "==> Elasticsearch"
kubectl apply -f "${ROOT_DIR}/kubernetes/elasticsearch.yaml"
kubectl rollout status statefulset/elasticsearch -n "${NAMESPACE}" --timeout=300s

echo "==> Kibana"
kubectl apply -f "${ROOT_DIR}/kubernetes/kibana.yaml"

echo "==> Filebeat (RBAC, config, DaemonSet)"
kubectl apply -f "${ROOT_DIR}/kubernetes/filebeat-rbac.yaml"
kubectl apply -f "${ROOT_DIR}/kubernetes/filebeat-configmap.yaml"
kubectl apply -f "${ROOT_DIR}/kubernetes/filebeat-daemonset.yaml"

echo "==> Metricbeat (RBAC, config, DaemonSet)"
kubectl apply -f "${ROOT_DIR}/kubernetes/metricbeat-rbac.yaml"
kubectl apply -f "${ROOT_DIR}/kubernetes/metricbeat-configmap.yaml"
kubectl apply -f "${ROOT_DIR}/kubernetes/metricbeat-daemonset.yaml"

echo "==> Waiting for Kibana, Filebeat, and Metricbeat to roll out"
kubectl rollout status deployment/kibana -n "${NAMESPACE}" --timeout=180s
kubectl rollout status daemonset/filebeat -n "${NAMESPACE}" --timeout=180s
kubectl rollout status daemonset/metricbeat -n "${NAMESPACE}" --timeout=180s

echo "==> Importing dashboards (data views, visualizations, saved search, dashboards)"
"${ROOT_DIR}/scripts/import-dashboards.sh"

echo "Deploy complete. Run scripts/kibana-port-forward.sh to open Kibana."
