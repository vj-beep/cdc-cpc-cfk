# lib/kafka.sh — Kafka topic and Schema Registry helpers
# Sourced by cdc.sh — depends on lib/common.sh (kafka_exec, NS)

# Expand under-partitioned data topics to target count.
# Prints: "<expanded> <total>" (e.g. "12 300")
expand_partitions() {
  local target="$1" expanded=0 total=0 tp cur
  local topics
  topics=$(kafka_exec kafka-topics --bootstrap-server localhost:9071 --list \
    | grep -E '^(financedb|retaildb|logsdb)\.' || true)
  [ -z "$topics" ] && echo "0 0" && return
  while IFS= read -r tp; do
    tp=$(echo "$tp" | tr -d '[:space:]'); [ -z "$tp" ] && continue
    total=$((total + 1))
    cur=$(kafka_exec kafka-topics --bootstrap-server localhost:9071 \
      --describe --topic "$tp" 2>/dev/null | grep -oP 'PartitionCount:\s*\K[0-9]+' || echo "1")
    if [ "$cur" -lt "$target" ]; then
      kafka_exec kafka-topics --bootstrap-server localhost:9071 \
        --alter --topic "$tp" --partitions "$target" 2>/dev/null || true
      expanded=$((expanded + 1))
    fi
  done <<< "$topics"
  echo "$expanded $total"
}

delete_cdc_topics() {
  local all_topics topics count topic_csv
  all_topics=$(kafka_exec kafka-topics --bootstrap-server localhost:9071 --list || echo "")
  topics=$(echo "$all_topics" | grep -E '^(financedb\.|retaildb\.|logsdb\.|__debezium|connect-|_connect-)' | sort)
  if [ -n "$topics" ]; then
    count=$(echo "$topics" | wc -l | tr -d '[:space:]')
    topic_csv=$(echo "$topics" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | paste -sd ',' -)
    printf "    Deleting %s topics (batch) ...\n" "$count"
    kafka_exec kafka-topics --bootstrap-server localhost:9071 \
      --delete --if-exists --topic "$topic_csv" 2>/dev/null || true
    printf "    %bOK%b %s topics deleted\n" "$G" "$NC" "$count"
  else
    printf "    %bOK%b no topics to delete\n" "$G" "$NC"
  fi
}

delete_connect_consumer_groups() {
  local groups count
  groups=$(kafka_exec kafka-consumer-groups --bootstrap-server localhost:9071 --list \
    | grep -E '^connect-' | sort || echo "")
  if [ -n "$groups" ]; then
    count=$(echo "$groups" | wc -l | tr -d '[:space:]')
    printf "    Deleting %s consumer groups ...\n" "$count"
    while IFS= read -r grp; do
      [ -z "$grp" ] && continue
      kafka_exec kafka-consumer-groups --bootstrap-server localhost:9071 \
        --delete --group "$grp" 2>/dev/null || true
      printf "    deleted %s\n" "$grp"
    done <<< "$groups"
    printf "    %bOK%b %s consumer groups deleted\n" "$G" "$NC" "$count"
  else
    printf "    %bOK%b no consumer groups to delete\n" "$G" "$NC"
  fi
}

delete_all_topics() {
  local all_topics topics count
  all_topics=$(kafka_exec kafka-topics --bootstrap-server localhost:9071 --list || echo "")
  topics=$(echo "$all_topics" | grep -vE '^(__consumer_offsets|_schemas|^$)' | sort)
  if [ -n "$topics" ]; then
    count=$(echo "$topics" | wc -l | tr -d '[:space:]')
    local topic_csv
    topic_csv=$(echo "$topics" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | paste -sd ',' -)
    printf "    Deleting %s topics (batch) ...\n" "$count"
    kafka_exec kafka-topics --bootstrap-server localhost:9071 \
      --delete --if-exists --topic "$topic_csv" 2>/dev/null || true
    printf "    %bOK%b %s topics deleted\n" "$G" "$NC" "$count"
  else
    printf "    %bOK%b no topics to delete\n" "$G" "$NC"
  fi
}

delete_sr_subjects() {
  local mode="${1:-cdc}"  # "cdc" = CDC-related only, "all" = everything
  local result
  result=$(kubectl exec kafka-0 -n "$NS" -c kafka -- bash -c '
SR="http://schemaregistry.confluent.svc.cluster.local:8081"
MODE="'"$mode"'"
SUBJECTS=$(curl -s $SR/subjects | python3 -c "
import sys, json
subjects = json.load(sys.stdin)
mode = \"$MODE\"
if mode == \"all\":
    filtered = subjects
else:
    filtered = [s for s in subjects if any(s.startswith(p) for p in (\"financedb.\",\"retaildb.\",\"logsdb.\",\"__debezium\"))]
for s in filtered:
    print(s)
" 2>/dev/null)
[ -z "$SUBJECTS" ] && echo "0" && exit 0
COUNT=$(echo "$SUBJECTS" | wc -l)
echo "$COUNT"
echo "$SUBJECTS" | while IFS= read -r s; do
  [ -z "$s" ] && continue
  curl -s -X DELETE "$SR/subjects/$s?permanent=false" >/dev/null 2>&1
  curl -s -X DELETE "$SR/subjects/$s?permanent=true" >/dev/null 2>&1
done
' 2>/dev/null)
  local count
  count=$(echo "$result" | head -1 | tr -d '[:space:]')
  if [ -z "$count" ] || [ "$count" = "0" ]; then
    printf "    %bOK%b no SR subjects to delete\n" "$G" "$NC"
  else
    printf "    %bOK%b %s SR subjects deleted\n" "$G" "$NC" "$count"
  fi
}
