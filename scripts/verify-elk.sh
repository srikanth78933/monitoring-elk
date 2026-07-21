#!/usr/bin/env bash
# Smoke-tests the ELK stack after a deploy: ES is healthy, Filebeat is
# running on every node, and app logs are actually landing in the index.
set -euo pipefail

NAMESPACE="${LOGGING_NAMESPACE:-logging}"

echo "==> Elasticsearch cluster health"
kubectl run es-verify --rm -i --restart=Never -n "${NAMESPACE}" \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s "http://elasticsearch:9200/_cluster/health?pretty"

echo
echo "==> Filebeat DaemonSet (desired should equal ready)"
kubectl get daemonset filebeat -n "${NAMESPACE}"

echo
echo "==> Log volume by namespace, last 15 minutes"
kubectl run es-count --rm -i --restart=Never -n "${NAMESPACE}" \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -X GET "http://elasticsearch:9200/filebeat-*/_search" \
    -H "Content-Type: application/json" \
    -d '{"size":0,"query":{"range":{"@timestamp":{"gte":"now-15m"}}},"aggs":{"by_namespace":{"terms":{"field":"kubernetes.namespace"}}}}'
echo
