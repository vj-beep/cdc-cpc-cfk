#!/usr/bin/env bash
set -euo pipefail

NS="confluent"
FNS="flink"

# ------------------------------------------------------------------
# Cleanup: kill any existing port-forwards from previous runs
# ------------------------------------------------------------------
printf "Cleaning up existing port-forwards...\n"

# Confluent Platform
pkill -f "port-forward.*controlcenter.*9021" 2>/dev/null || true
pkill -f "port-forward.*kafka-ui.*8080"      2>/dev/null || true
pkill -f "port-forward.*schemaregistry.*8081" 2>/dev/null || true
pkill -f "port-forward.*connect.*8083"        2>/dev/null || true

# Monitoring
pkill -f "port-forward.*grafana.*3000"        2>/dev/null || true

# CP Flink
pkill -f "port-forward.*cmf-service.*8084"    2>/dev/null || true

# Catch-all
pkill -f "port-forward.*-n confluent"  2>/dev/null || true
pkill -f "port-forward.*-n flink"      2>/dev/null || true
pkill -f "port-forward.*-n monitoring" 2>/dev/null || true

sleep 1

# ------------------------------------------------------------------
# Start fresh port-forwards
# ------------------------------------------------------------------
printf "\nPort-forwards (Ctrl+C to stop):\n\n"
printf "  Control Center:   http://localhost:9021\n"
printf "  Kafka-UI:         http://localhost:8080\n"
printf "  Schema Registry:  http://localhost:8081\n"
printf "  Connect REST:     http://localhost:8083\n"
printf "  Grafana:          http://localhost:3000\n"
printf "  Flink CMF:        http://localhost:8090\n\n"

# --- Confluent Platform ---
kubectl port-forward svc/controlcenter -n "${NS}" 9021:9021 &
kubectl port-forward svc/kafka-ui -n "${NS}" 8080:8080 &
kubectl port-forward svc/schemaregistry -n "${NS}" 8081:8081 &
kubectl port-forward svc/connect -n "${NS}" 8083:8083 &

# --- Monitoring ---
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80 &

# --- CP Flink (CMF) ---
# CMF exposes port 80; we map it to 8084 locally to avoid clashes.
# Flink Web UI is per-application: use ./cdc.sh flink ui <app> [port]
if kubectl get svc cmf-service -n "${FNS}" > /dev/null 2>&1; then
  kubectl port-forward svc/cmf-service -n "${FNS}" 8084:80 &
  printf "  CMF port-forward started.\n"
else
  printf "  (CMF service not found in ns/%s — skipping)\n" "${FNS}"
fi

wait
