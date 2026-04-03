# lib/cmd-connect.sh — connect subcommand
# Sourced by cdc.sh — depends on lib/common.sh, lib/connect.sh, lib/kafka.sh

SUB="${1:-help}"; shift 2>/dev/null || true
N="${1:-}"

if [ -n "$N" ] && ! echo "$N" | grep -qE '^[0-9]+$'; then
  printf "    %bERROR%b replica count must be a number, got '%s'\n" "$R" "$NC" "$N"; exit 1
fi

case "$SUB" in
  cdc)
    N="${N:-2}"
    printf "\n%b   +=== Connect: CDC Profile (%s workers) ===%b\n" "$C" "$N" "$NC"
    connect_scale cdc "$N"
    printf "\n"
    ;;

  bulk)
    N="${N:-4}"
    printf "\n%b   +=== Connect: Bulk Profile (%s workers) ===%b\n" "$C" "$N" "$NC"
    connect_scale bulk "$N"
    printf "\n"
    ;;

  aggressive)
    N="${N:-6}"
    PARTITIONS=8
    printf "\n%b   +=== Connect: Aggressive Profile (%s workers) ===%b\n" "$C" "$N" "$NC"

    connect_scale bulk "$N"
    epf; sleep 5

    # Expand topic partitions (durable -- CFK does not revert this)
    printf "\n    Expanding topics to %s partitions ...\n" "$PARTITIONS"
    TOPICS=$(kafka_exec kafka-topics --bootstrap-server localhost:9071 --list \
      | grep -E '^(financedb|retaildb|logsdb)\.' || true)
    if [ -n "$TOPICS" ]; then
      echo "$TOPICS" | while read -r tp; do
        tp=$(echo "$tp" | tr -d '[:space:]'); [ -z "$tp" ] && continue
        kafka_exec kafka-topics --bootstrap-server localhost:9071 \
          --alter --topic "$tp" --partitions "$PARTITIONS" 2>/dev/null || true
      done
      printf "      %bOK%b topics expanded\n" "$G" "$NC"
    else
      printf "      %bSKIP%b no data topics yet\n" "$Y" "$NC"
    fi

    printf "\n    Revert with: ./cdc.sh connect cdc\n"
    printf "    For permanent connector tuning, edit 12-connectors.tf\n\n"
    ;;

  stop)
    printf "\n  Stopping Connect ...\n"
    connect_stop
    printf "    %bOK%b Connect scaled to 0\n\n" "$G" "$NC"
    ;;

  restart)
    CONN_NAME="${1:-}"
    epf || { printf "    %bERROR%b Connect not reachable\n\n" "$R" "$NC"; exit 1; }
    if [ -n "$CONN_NAME" ]; then
      printf "\n  Restarting %s ...\n" "$CONN_NAME"
      curl -s --max-time 10 -X POST "${API}/${CONN_NAME}/restart?includeTasks=true&onlyFailed=true" > /dev/null 2>&1
      printf "    %bOK%b restart requested for %s\n\n" "$G" "$NC" "$CONN_NAME"
    else
      printf "\n  Restarting all failed tasks ...\n"
      for cn in $ALL_CONNECTORS; do
        curl -s --max-time 10 -X POST "${API}/${cn}/restart?includeTasks=true&onlyFailed=true" 2>/dev/null > /dev/null
        st=$(curl -s --max-time 5 "${API}/${cn}/status" 2>/dev/null \
          | python3 -c "import sys,json;print(json.load(sys.stdin)['connector']['state'])" 2>/dev/null || echo "?")
        printf "    %-35s %s\n" "$cn" "$st"
      done
      printf "\n    %bOK%b restart requested for all connectors\n\n" "$G" "$NC"
    fi
    ;;

  *)
    printf "\n  ./cdc.sh connect <cdc [N]|bulk [N]|aggressive [N]|stop|restart [name]>\n\n"
    ;;
esac
