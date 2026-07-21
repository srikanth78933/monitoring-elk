#!/usr/bin/env bash
# Registers the Kibana data view (index pattern) so logs are browsable in
# Discover / usable in dashboards the moment this script returns. Runs as a
# throwaway in-cluster pod rather than assuming curl is on the local
# machine or inside the kibana/elasticsearch containers.
set -euo pipefail

NAMESPACE="${LOGGING_NAMESPACE:-logging}"

echo "==> Creating Kibana data view 'filebeat-*' (@timestamp)"
kubectl run kibana-setup --rm -i --restart=Never -n "${NAMESPACE}" \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -X POST "http://kibana:5601/api/data_views/data_view" \
    -H "kbn-xsrf: true" -H "Content-Type: application/json" \
    -d '{"data_view":{"title":"filebeat-*","name":"App Logs (filebeat-*)","timeFieldName":"@timestamp"}}'

echo
echo "Data view ready (already-exists errors here are harmless - rerun-safe)."
