# lib/cmd-toxiproxy.sh — toxiproxy subcommand (on-prem latency simulation)
# Sourced by cdc.sh — depends on lib/common.sh

SUB="${1:-help}"; shift 2>/dev/null || true
TOXI_POD=$(kubectl get pod -n "$NS" -l app=toxiproxy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
TOXI_API="http://localhost:8474"

_toxi_fwd() {
  if ! curl -s --max-time 2 "${TOXI_API}/version" > /dev/null 2>&1; then
    pkill -f "kubectl port-forward.*toxiproxy.*8474" 2>/dev/null || true
    sleep 1
    kubectl port-forward "pod/${TOXI_POD}" -n "$NS" 8474:8474 > /dev/null 2>&1 &
    sleep 2
  fi
}

case "$SUB" in
  setup)
    printf "\n%b   +=== Toxiproxy Setup ===%b\n\n" "$C" "$NC"
    if [ -z "$TOXI_POD" ]; then
      printf "    %bERROR%b No toxiproxy pod found. Set toxiproxy_enabled = true in terraform.tfvars and run terraform apply.\n\n" "$R" "$NC"
      exit 1
    fi
    _toxi_fwd

    # Read config from ConfigMap
    _RDS_HOST=$(kubectl get configmap toxiproxy-config -n "$NS" -o jsonpath='{.data.sqlserver-host}' 2>/dev/null)
    _DEF_LAT=$(kubectl get configmap toxiproxy-config -n "$NS" -o jsonpath='{.data.default-latency-ms}' 2>/dev/null)
    _DEF_JIT=$(kubectl get configmap toxiproxy-config -n "$NS" -o jsonpath='{.data.default-jitter-ms}' 2>/dev/null)

    printf "    Creating proxy: sqlserver -> %s:1433\n" "$_RDS_HOST"
    # Remove existing proxy if any
    curl -s -X DELETE "${TOXI_API}/proxies/sqlserver" > /dev/null 2>&1 || true
    curl -s -X POST "${TOXI_API}/proxies" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"sqlserver\",\"listen\":\"0.0.0.0:1433\",\"upstream\":\"${_RDS_HOST}:1433\",\"enabled\":true}" > /dev/null 2>&1

    printf "    Adding latency: %sms +/- %sms\n" "$_DEF_LAT" "$_DEF_JIT"
    curl -s -X POST "${TOXI_API}/proxies/sqlserver/toxics" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"latency_downstream\",\"type\":\"latency\",\"stream\":\"downstream\",\"attributes\":{\"latency\":${_DEF_LAT},\"jitter\":${_DEF_JIT}}}" > /dev/null 2>&1
    curl -s -X POST "${TOXI_API}/proxies/sqlserver/toxics" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"latency_upstream\",\"type\":\"latency\",\"stream\":\"upstream\",\"attributes\":{\"latency\":${_DEF_LAT},\"jitter\":${_DEF_JIT}}}" > /dev/null 2>&1

    printf "    %bOK%b Proxy active — Debezium will route through toxiproxy\n\n" "$G" "$NC"
    ;;

  status)
    printf "\n%b   +=== Toxiproxy Status ===%b\n\n" "$C" "$NC"
    if [ -z "$TOXI_POD" ]; then
      printf "    %bNOT DEPLOYED%b — set toxiproxy_enabled = true\n\n" "$Y" "$NC"
      exit 0
    fi
    _toxi_fwd
    printf "    Pod: %s\n" "$TOXI_POD"
    printf "\n    Proxies:\n"
    curl -s "${TOXI_API}/proxies" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for name,p in d.items():
  print(f\"      {name}: {p['listen']} -> {p['upstream']}  enabled={p['enabled']}\")
  for t in p.get('toxics',[]):
    attrs = ', '.join(f'{k}={v}' for k,v in t['attributes'].items())
    print(f\"        {t['name']} ({t['type']}, {t['stream']}): {attrs}\")
" 2>/dev/null || printf "      (no proxies configured — run: ./cdc.sh toxiproxy setup)\n"
    printf "\n"
    ;;

  latency)
    LAT_MS="${1:-20}"; JIT_MS="${2:-5}"
    printf "\n  Setting latency: %sms +/- %sms (both directions)\n" "$LAT_MS" "$JIT_MS"
    if [ -z "$TOXI_POD" ]; then
      printf "    %bERROR%b No toxiproxy pod\n\n" "$R" "$NC"; exit 1
    fi
    _toxi_fwd
    # Update existing toxics (delete + recreate)
    for dir in downstream upstream; do
      curl -s -X DELETE "${TOXI_API}/proxies/sqlserver/toxics/latency_${dir}" > /dev/null 2>&1 || true
      curl -s -X POST "${TOXI_API}/proxies/sqlserver/toxics" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"latency_${dir}\",\"type\":\"latency\",\"stream\":\"${dir}\",\"attributes\":{\"latency\":${LAT_MS},\"jitter\":${JIT_MS}}}" > /dev/null 2>&1
    done
    printf "    %bOK%b RTT ~ %sms (each direction %sms +/- %sms)\n\n" "$G" "$NC" "$((LAT_MS * 2))" "$LAT_MS" "$JIT_MS"
    ;;

  bandwidth)
    RATE_KB="${1:-128000}"
    printf "\n  Setting bandwidth limit: %s KB/s\n" "$RATE_KB"
    if [ -z "$TOXI_POD" ]; then
      printf "    %bERROR%b No toxiproxy pod\n\n" "$R" "$NC"; exit 1
    fi
    _toxi_fwd
    for dir in downstream upstream; do
      curl -s -X DELETE "${TOXI_API}/proxies/sqlserver/toxics/bw_${dir}" > /dev/null 2>&1 || true
      curl -s -X POST "${TOXI_API}/proxies/sqlserver/toxics" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"bw_${dir}\",\"type\":\"bandwidth\",\"stream\":\"${dir}\",\"attributes\":{\"rate\":${RATE_KB}}}" > /dev/null 2>&1
    done
    printf "    %bOK%b Bandwidth capped at ~%s Mbps\n\n" "$G" "$NC" "$((RATE_KB * 8 / 1000))"
    ;;

  reset)
    printf "\n  Removing all toxics (proxy stays active, zero latency) ...\n"
    if [ -z "$TOXI_POD" ]; then
      printf "    %bERROR%b No toxiproxy pod\n\n" "$R" "$NC"; exit 1
    fi
    _toxi_fwd
    for toxic in latency_downstream latency_upstream bw_downstream bw_upstream; do
      curl -s -X DELETE "${TOXI_API}/proxies/sqlserver/toxics/${toxic}" > /dev/null 2>&1 || true
    done
    printf "    %bOK%b All toxics removed — passthrough mode\n\n" "$G" "$NC"
    ;;

  *)
    printf "\n  ./cdc.sh toxiproxy <setup|status|latency [ms] [jitter]|bandwidth [KB/s]|reset>\n\n"
    printf "    setup                 Create proxy + apply default latency\n"
    printf "    status                Show proxy and active toxics\n"
    printf "    latency [ms] [jit]    Set latency (default 20ms +/- 5ms per direction)\n"
    printf "    bandwidth [KB/s]      Cap bandwidth (default 128000 = ~1Gbps)\n"
    printf "    reset                 Remove all toxics (passthrough)\n\n"
    printf "  Presets:\n"
    printf "    Same-metro DX/TGW:    ./cdc.sh toxiproxy latency 15 5\n"
    printf "    Cross-country:        ./cdc.sh toxiproxy latency 40 10\n"
    printf "    Degraded link:        ./cdc.sh toxiproxy latency 80 20\n\n"
    ;;
esac
