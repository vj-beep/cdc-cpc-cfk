# lib/connect.sh — Connect lifecycle helpers
# Sourced by cdc.sh — depends on lib/common.sh, lib/aurora.sh

epf() {
  if ! curl -s --max-time 2 http://localhost:8083/ > /dev/null 2>&1; then
    pkill -f "kubectl port-forward svc/connect.*8083" 2>/dev/null || true
    sleep 1
    kubectl port-forward svc/connect -n "$NS" 8083:8083 > /dev/null 2>&1 &
    local pf_pid=$! attempt=0
    while [ "$attempt" -lt 10 ]; do
      sleep 2
      if ! kill -0 "$pf_pid" 2>/dev/null; then
        printf "    %bERROR%b port-forward process died\n" "$R" "$NC"; return 1
      fi
      if curl -s --max-time 2 http://localhost:8083/ > /dev/null 2>&1; then return 0; fi
      attempt=$((attempt + 1))
    done
    printf "    %bWARN%b Connect REST not reachable on :8083 after 20s\n" "$Y" "$NC"
    kill "$pf_pid" 2>/dev/null || true; return 1
  fi
}

wait_connect() {
  local target="$1" timeout="${2:-300}" start elapsed
  start=$(date +%s)
  while true; do
    sleep 5
    r=$(kubectl get pods -n "$NS" -l app=connect --no-headers 2>/dev/null | grep -c "1/1" || true)
    r=$(echo "$r" | tr -d '[:space:]')
    elapsed=$(( $(date +%s) - start ))
    printf "\r    %s/%s ready (%ss)" "$r" "$target" "$elapsed"
    if [ "$r" = "$target" ]; then
      printf "\n    %bOK%b %s pods ready in %ss\n" "$G" "$NC" "$target" "$elapsed"; return 0
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      printf "\n    %bERROR%b timed out after %ss — only %s/%s ready\n" "$R" "$NC" "$timeout" "$r" "$target"; return 1
    fi
  done
}

wait_connectors_running() {
  local timeout="${1:-120}" start elapsed
  start=$(date +%s)
  printf "    Waiting for connectors to be RUNNING ...\n"
  while true; do
    sleep 5; elapsed=$(( $(date +%s) - start ))
    local total=0 running=0 failed=0 failed_names=""
    for cn in $ALL_CONNECTORS; do
      local st
      st=$(curl -s --max-time 5 "${API}/${cn}/status" 2>/dev/null \
        | python3 -c "import sys,json;print(json.load(sys.stdin)['connector']['state'])" 2>/dev/null || echo "MISSING")
      total=$((total + 1))
      if [ "$st" = "RUNNING" ]; then running=$((running + 1))
      elif [ "$st" = "FAILED" ]; then failed=$((failed + 1)); failed_names="${failed_names} ${cn}"; fi
    done
    printf "\r    %s/%s running (%ss)" "$running" "$total" "$elapsed"
    if [ "$running" -eq "$total" ]; then
      printf "\n    %bOK%b all %s connectors running\n" "$G" "$NC" "$total"; return 0
    fi
    if [ "$failed" -gt 0 ]; then
      printf "\n    %bERROR%b %s connector(s) FAILED:%s\n" "$R" "$NC" "$failed" "$failed_names"
      printf "    Run: ./cdc.sh connect restart\n"; return 1
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      printf "\n    %bWARN%b timed out — %s/%s running\n" "$Y" "$NC" "$running" "$total"; return 1
    fi
  done
}

connect_stop() {
  kubectl annotate scaledobject connect-autoscaler -n "$NS" \
    autoscaling.keda.sh/paused-replicas="0" --overwrite 2>/dev/null || true
  kubectl patch connect connect -n "$NS" --type merge -p '{"spec":{"replicas":0}}' 2>/dev/null || true
  kubectl delete pods -n "$NS" -l app=connect --force --grace-period=0 2>/dev/null || true
  sleep 5
}

connect_scale() {
  local profile="$1" replicas="$2"
  local node_profile cpu_limit cpu_req cpu_lim mem_req mem_lim aurora_fn wait_timeout=300

  case "$profile" in
    cdc)
      node_profile="cdc-steady"; cpu_limit="256"
      cpu_req="1"; cpu_lim="2"; mem_req="4Gi"; mem_lim="8Gi"
      aurora_fn="aurora_tune_revert"
      ;;
    bulk)
      node_profile="bulk-load"
      cpu_req="2"; cpu_lim="4"; mem_req="8Gi"; mem_lim="16Gi"
      cpu_limit="$((replicas * cpu_lim + 16))"
      aurora_fn="aurora_tune_bulk"; wait_timeout=600
      ;;
  esac

  # Pause KEDA -> patch nodepool -> patch Connect -> restart pods -> wait -> resume KEDA -> tune Aurora
  kubectl annotate scaledobject connect-autoscaler -n "$NS" \
    autoscaling.keda.sh/paused-replicas="$replicas" --overwrite 2>/dev/null || true

  # Only patch the nodepool that matches the profile (don't touch 'confluent' nodepool)
  if kubectl get nodepool "$node_profile" &>/dev/null; then
    kubectl patch nodepool "$node_profile" --type merge \
      -p "{\"spec\":{\"limits\":{\"cpu\":\"${cpu_limit}\"}}}" 2>/dev/null || true
  fi

  kubectl patch connect connect -n "$NS" --type merge \
    -p "{\"spec\":{\"replicas\":${replicas},\"podTemplate\":{\"affinity\":{\"nodeAffinity\":{\"requiredDuringSchedulingIgnoredDuringExecution\":{\"nodeSelectorTerms\":[{\"matchExpressions\":[{\"key\":\"workload-profile\",\"operator\":\"In\",\"values\":[\"${node_profile}\"]}]}]}}},\"tolerations\":[{\"key\":\"workload-profile\",\"value\":\"${node_profile}\",\"effect\":\"NoSchedule\"}],\"resources\":{\"requests\":{\"cpu\":\"${cpu_req}\",\"memory\":\"${mem_req}\"},\"limits\":{\"cpu\":\"${cpu_lim}\",\"memory\":\"${mem_lim}\"}}}}}"

  kubectl delete pods -n "$NS" -l app=connect --force --grace-period=0 2>/dev/null || true
  wait_connect "$replicas" "$wait_timeout"

  kubectl annotate scaledobject connect-autoscaler -n "$NS" \
    autoscaling.keda.sh/paused-replicas- --overwrite 2>/dev/null || true

  $aurora_fn
}
