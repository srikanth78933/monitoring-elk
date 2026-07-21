#!/usr/bin/env bash
# Kibana has no Ingress in this setup - reach it via port-forward on demand.
set -euo pipefail

NAMESPACE="${LOGGING_NAMESPACE:-logging}"

echo "Kibana -> http://localhost:5601 (Ctrl+C to stop)"
kubectl port-forward -n "${NAMESPACE}" svc/kibana 5601:5601
