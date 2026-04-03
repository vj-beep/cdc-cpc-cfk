# lib/cmd-infra.sh — infra subcommand
# Sourced by cdc.sh — depends on lib/common.sh, lib/connect.sh, lib/kafka.sh, lib/monitor.sh

SUB="${1:-help}"; shift 2>/dev/null || true

case "$SUB" in
  status)
    printf "\n%b   +=== Infra Status ===%b\n\n" "$C" "$NC"
    epf || true
    printf "  Connectors:\n"
    for cn in $(curl -s --max-time 10 "${API}" 2>/dev/null | python3 -c "import sys,json;[print(c) for c in json.load(sys.stdin)]" 2>/dev/null); do
      STATUS_JSON=$(curl -s --max-time 10 "${API}/${cn}/status" 2>/dev/null)
      st=$(echo "$STATUS_JSON" \
        | python3 -c "import sys,json;print(json.load(sys.stdin)['connector']['state'])" 2>/dev/null || echo "?")
      tk=$(echo "$STATUS_JSON" \
        | python3 -c "import sys,json;d=json.load(sys.stdin);print('/'.join(t['state'] for t in d.get('tasks',[])))" 2>/dev/null || echo "?")
      printf "    %-35s %-10s tasks: %s\n" "$cn" "$st" "$tk"
      ERRORS=$(echo "$STATUS_JSON" \
        | python3 -c "
import sys,json
d=json.load(sys.stdin)
for t in d.get('tasks',[]):
  if t['state']=='FAILED':
    tr=t.get('trace','')
    print(f\"      task {t['id']}: {tr[:200]}\")" 2>/dev/null || true)
      [ -n "$ERRORS" ] && printf "%b%s%b\n" "$R" "$ERRORS" "$NC"
    done
    printf "\n  Connect pods:\n"
    kubectl get pods -n "$NS" -l app=connect -o wide --no-headers 2>/dev/null | while IFS= read -r line; do
      pod=$(echo "$line" | awk '{print $1}')
      st=$(echo "$line" | awk '{print $3}')
      nd=$(echo "$line" | awk '{print $7}')
      it=$(kubectl get node "$nd" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "?")
      printf "    %-40s %-10s %s\n" "$pod" "$st" "$it"
    done
    if [ -n "$PH" ] && [ -n "$PU" ]; then
      SINK=$(count_sink_rows)
      TABLES=$(pgv "SELECT COUNT(*) FROM pg_stat_user_tables;" | tr -d '[:space:]')
      printf "\n  Aurora: %s rows across %s tables\n" "$SINK" "$TABLES"
    fi
    printf "\n"
    ;;

  topics)
    ACTION="${1:-list}"; shift 2>/dev/null || true
    case "$ACTION" in
      list)
        printf "\n%b   +=== Kafka Topics ===%b\n\n" "$C" "$NC"
        ALL=$(kafka_exec kafka-topics --bootstrap-server localhost:9071 --list || echo "")
        INT=$(echo "$ALL" | grep -cE '^(_confluent|confluent\.|__consumer|_schemas)' 2>/dev/null || echo "0")
        CDC=$(echo "$ALL" | grep -vcE '^(_confluent|confluent\.|__consumer|_schemas|^$)' 2>/dev/null || echo "0")
        printf "    Internal: %s\n    CDC data: %s\n\n" "$INT" "$CDC"
        echo "$ALL" | grep -vE '^(_confluent|confluent\.|__consumer|_schemas|^$)' | sort | while read -r t; do
          printf "    %s\n" "$t"
        done
        printf "\n"
        ;;
      clean)
        printf "\n%b   +=== Clean CDC Topics ===%b\n\n" "$C" "$NC"
        PODS=$(kubectl get pods -n "$NS" -l app=connect --no-headers 2>/dev/null | grep -c "1/1" || true)
        PODS=$(echo "$PODS" | tr -d '[:space:]')
        if [ -n "$PODS" ] && [ "$PODS" -gt 0 ] 2>/dev/null; then
          printf "    %bWARN%b Connect has %s running pods. Recommend: ./cdc.sh connect stop\n\n" "$Y" "$NC" "$PODS"
        fi
        delete_cdc_topics
        ;;
      nuke)
        printf "\n%b   +=== NUKE: All Topics ===%b\n\n" "$R" "$NC"
        printf "    This stops Connect and deletes ALL non-system topics.\n"
        read -p "    Type 'nuke' to confirm: " CONFIRM
        [ "$CONFIRM" != "nuke" ] && { printf "    Aborted.\n\n"; exit 0; }
        printf "\n    Stopping Connect ...\n"
        connect_stop
        delete_all_topics
        printf "\n    %bOK%b Restart with: ./cdc.sh connect cdc\n\n" "$G" "$NC"
        ;;
      *)
        printf "\n  infra topics [clean|nuke]  (default: list)\n\n"
        ;;
    esac
    ;;

  grafana)
    printf "\n%b   +=== Import Grafana Dashboard ===%b\n\n" "$C" "$NC"
    GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
    GRAFANA_USER="${GRAFANA_USER:-admin}"
    GRAFANA_PASS="${GRAFANA_PASS:-admin}"
    DASH_FILE="${SCRIPT_DIR}/config/grafana/cdc-pipeline-flow.json"
    [ ! -f "$DASH_FILE" ] && { printf "    %bERROR%b %s not found\n\n" "$R" "$NC" "$DASH_FILE"; exit 1; }
    HTTP_CODE=$(curl -s --max-time 10 -o /tmp/grafana_resp.json -w "%{http_code}" \
      -X POST "${GRAFANA_URL}/api/dashboards/db" \
      -H "Content-Type: application/json" \
      -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
      -d @"$DASH_FILE")
    if [ "$HTTP_CODE" = "200" ]; then
      DASH_URL=$(python3 -c "import json;print(json.load(open('/tmp/grafana_resp.json')).get('url',''))" 2>/dev/null || echo "")
      printf "    %bOK%b Dashboard imported\n    Open: %s%s\n\n" "$G" "$NC" "$GRAFANA_URL" "$DASH_URL"
    else
      printf "    %bERROR%b Import failed (HTTP %s)\n    Manual: open %s/dashboard/import\n\n" "$R" "$NC" "$HTTP_CODE" "$GRAFANA_URL"
    fi
    rm -f /tmp/grafana_resp.json
    ;;

  *)
    printf "\n  ./cdc.sh infra <status|topics [clean|nuke]|grafana>\n\n"
    ;;
esac
