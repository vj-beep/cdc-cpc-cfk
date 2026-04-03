# lib/cmd-flink.sh — flink subcommand
# Sourced by cdc.sh — depends on lib/common.sh

SUB="${1:-help}"; shift 2>/dev/null || true
CMF_URL="${CMF_URL:-http://localhost:8090}"
FLINK_STATE_BUCKET="${FLINK_STATE_BUCKET:-$(terraform output -raw flink_state_bucket 2>/dev/null || echo "")}"

_resolve_flink_tpl() {
  local tmp; tmp=$(mktemp)
  sed "s|__FLINK_STATE_BUCKET__|${FLINK_STATE_BUCKET}|g" "$1" > "$tmp"
  echo "$tmp"
}

case "$SUB" in
  setup)
    printf "\n%b   +=== Flink Setup ===%b\n\n" "$C" "$NC"
    pkill -f "port-forward.*cmf-service" 2>/dev/null || true
    nohup kubectl port-forward svc/cmf-service -n flink 8090:80 > /dev/null 2>&1 &
    sleep 3
    confluent flink environment create cdc-env \
      --url "$CMF_URL" --kubernetes-namespace flink 2>/dev/null || true
    printf "    %bOK%b environment cdc-env\n" "$G" "$NC"
    CATALOG_FILE="${SCRIPT_DIR}/config/flink-k8s/kafka-catalog.json"
    if [ -f "$CATALOG_FILE" ]; then
      curl -s --max-time 10 -H "Content-Type: application/json" \
        -X POST "${CMF_URL}/cmf/api/v1/catalogs/kafka" \
        -d @"$CATALOG_FILE" > /dev/null 2>&1 || true
      printf "    %bOK%b kafka catalog\n" "$G" "$NC"
    fi
    printf "    %bOK%b state bucket: %s\n\n" "$G" "$NC" "${FLINK_STATE_BUCKET:-<unset>}"
    ;;

  sql)
    FILE="${1:-}"
    [ -z "$FILE" ] || [ ! -f "$FILE" ] && { printf "\n  Usage: ./cdc.sh flink sql <sql-file>\n\n"; exit 1; }
    printf "\n  Deploying %s ...\n" "$FILE"
    STMT=""
    while IFS= read -r line; do
      stripped=$(echo "$line" | sed 's/^[[:space:]]*//')
      case "$stripped" in --*) continue ;; "") continue ;; esac
      STMT="${STMT} ${line}"
      if echo "$line" | grep -q ';[[:space:]]*$'; then
        printf "    -> %.60s...\n" "$(echo "$STMT" | head -c 60)"
        echo "$STMT" | confluent flink statement create - \
          --environment cdc-env --url "$CMF_URL" 2>&1 | head -3 || true
        STMT=""
      fi
    done < "$FILE"
    printf "    %bDone%b\n\n" "$G" "$NC"
    ;;

  app)
    FILE="${1:-}"
    [ -z "$FILE" ] || [ ! -f "$FILE" ] && { printf "\n  Usage: ./cdc.sh flink app <json-file>\n\n"; exit 1; }
    printf "\n  Deploying %s ...\n" "$FILE"
    RESOLVED=$(_resolve_flink_tpl "$FILE")
    confluent flink application create "$RESOLVED" --environment cdc-env --url "$CMF_URL"
    rm -f "$RESOLVED"
    printf "    %bDone%b\n\n" "$G" "$NC"
    ;;

  status)
    printf "\n%b   +=== Flink Status ===%b\n\n" "$C" "$NC"
    printf "  Environments:\n"
    confluent flink environment list --url "$CMF_URL" 2>/dev/null | head -20 || printf "    (none)\n"
    printf "\n  Applications:\n"
    confluent flink application list --environment cdc-env --url "$CMF_URL" 2>/dev/null | head -20 || printf "    (none)\n"
    printf "\n  Pods:\n"
    kubectl get pods -n flink --no-headers 2>/dev/null | while IFS= read -r line; do printf "    %s\n" "$line"; done
    printf "\n"
    ;;

  stop)
    APP="${1:-}"
    if [ -z "$APP" ]; then
      printf "\n  Stopping ALL Flink apps ...\n"
      for a in $(confluent flink application list --environment cdc-env --url "$CMF_URL" -o json 2>/dev/null \
        | python3 -c "import sys,json;[print(x['metadata']['name']) for x in json.load(sys.stdin)]" 2>/dev/null); do
        confluent flink application delete "$a" --environment cdc-env --url "$CMF_URL" 2>/dev/null || true
        printf "    stopped %s\n" "$a"
      done
    else
      confluent flink application delete "$APP" --environment cdc-env --url "$CMF_URL" 2>/dev/null || true
      printf "    stopped %s\n" "$APP"
    fi
    printf "\n"
    ;;

  ui)
    APP="${1:-}"; PORT="${2:-8091}"
    [ -z "$APP" ] && { printf "\n  Usage: ./cdc.sh flink ui <app> [port]\n\n"; exit 1; }
    printf "\n  %s -> http://localhost:%s ...\n\n" "$APP" "$PORT"
    confluent flink application web-ui-forward "$APP" --environment cdc-env --port "$PORT" --url "$CMF_URL"
    ;;

  logs)
    APP="${1:-}"
    [ -z "$APP" ] && { printf "\n  Usage: ./cdc.sh flink logs <app>\n\n"; exit 1; }
    JM=$(kubectl get pods -n flink -l "app=$APP,component=jobmanager" --no-headers 2>/dev/null | awk '{print $1}' | head -1)
    [ -z "$JM" ] && { printf "  No JobManager pod for %s\n\n" "$APP"; exit 1; }
    kubectl logs -n flink "$JM" --tail=100 -f
    ;;

  *)
    printf "\n  ./cdc.sh flink <setup|sql|app|status|stop|ui|logs>\n\n"
    ;;
esac
