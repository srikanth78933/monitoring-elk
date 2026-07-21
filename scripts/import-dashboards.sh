#!/usr/bin/env bash
# Imports the pre-built dashboards (logs + infra metrics) and their
# underlying data views/visualizations/saved search, exported from a
# working Kibana via `POST /api/saved_objects/_export` with
# includeReferencesDeep - see kibana/saved-objects/dashboards.ndjson.
# overwrite=true makes this rerun-safe: it replaces existing objects with
# the same IDs rather than erroring or duplicating them.
set -euo pipefail

NAMESPACE="${LOGGING_NAMESPACE:-logging}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NDJSON="${ROOT_DIR}/kibana/saved-objects/dashboards.ndjson"

echo "==> Importing dashboards into Kibana"
cat "${NDJSON}" | kubectl run kibana-import --rm -i --restart=Never -n "${NAMESPACE}" \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -X POST "http://kibana:5601/api/saved_objects/_import?overwrite=true" \
    -H "kbn-xsrf: true" \
    -F "file=@-;filename=dashboards.ndjson;type=application/ndjson"

echo
echo "Dashboards ready: 'Backend App Logs' and 'Infrastructure Metrics' in Kibana."
