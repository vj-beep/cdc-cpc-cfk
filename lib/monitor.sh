# lib/monitor.sh — Row counting, snapshot monitoring, summary
# Sourced by cdc.sh — depends on lib/common.sh, lib/kafka.sh, lib/aurora.sh

count_source_rows() {
  local total=0
  for db in $DBS; do
    local dr tc
    # Use DISTINCT count for tables without a PK (upsert deduplicates them)
    dr=$(sd "$db" "SET NOCOUNT ON;
DECLARE @total BIGINT = 0;
SELECT @total = @total + p.rows
  FROM sys.tables t
  JOIN sys.partitions p ON t.object_id = p.object_id
  WHERE p.index_id IN (0,1) AND t.is_ms_shipped = 0
    AND EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1);
DECLARE @tname NVARCHAR(256), @sql NVARCHAR(MAX), @cnt BIGINT;
DECLARE nopk CURSOR FAST_FORWARD FOR
  SELECT t.name FROM sys.tables t
  WHERE t.is_ms_shipped = 0
    AND NOT EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1);
OPEN nopk; FETCH NEXT FROM nopk INTO @tname;
WHILE @@FETCH_STATUS = 0 BEGIN
  SET @sql = N'SELECT @c = COUNT(*) FROM (SELECT DISTINCT * FROM ' + QUOTENAME(@tname) + N') t';
  EXEC sp_executesql @sql, N'@c BIGINT OUTPUT', @c = @cnt OUTPUT;
  SET @total = @total + @cnt;
  FETCH NEXT FROM nopk INTO @tname;
END; CLOSE nopk; DEALLOCATE nopk;
SELECT @total;" \
      | tr -d ' ' | grep -E '^[0-9]+$' | head -1 || echo "0")
    tc=$(sd "$db" "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped=0" \
      | tr -d ' ' | grep -E '^[0-9]+$' | head -1 || echo "0")
    printf "    %s: %s rows (%s tables)\n" "$db" "$dr" "$tc"
    sd "$db" "SET NOCOUNT ON; SELECT t.name, CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1) THEN CAST(p.rows AS VARCHAR) ELSE CAST(p.rows AS VARCHAR) + ' (no PK)' END FROM sys.tables t JOIN sys.partitions p ON t.object_id=p.object_id WHERE p.index_id IN (0,1) AND t.is_ms_shipped=0 ORDER BY p.rows DESC" \
      | while IFS= read -r line; do
          line=$(echo "$line" | tr -d '\r' | sed 's/  */  /g'); [ -z "$line" ] && continue
          printf "      %s\n" "$line"
        done
    total=$((total + dr))
  done
  printf "    Total: %s rows (* = no PK, counted as DISTINCT)\n" "$total"
  echo "$total" > /tmp/cdc_source_total
}

count_sink_rows() {
  pg "ANALYZE;" 2>/dev/null
  local sink
  sink=$(pgv "SELECT COALESCE(SUM(n_live_tup),0) FROM pg_stat_user_tables WHERE schemaname IN ('financedb','retaildb','logsdb');")
  sink=$(echo "$sink" | tr -d '[:space:]'); [ -z "$sink" ] && sink=0
  echo "$sink"
}

monitor() {
  local TOTAL="$1" WALL_START="${2:-}" PART_TARGET="${3:-0}" BSTART PREV PREV_TS STALL_COUNT=0 MAX_STALLS=10
  local TIMEOUT_SECS="${MONITOR_TIMEOUT_SECS:-21600}"
  local ANALYZE_INTERVAL=300 LAST_ANALYZE
  local PART_DONE=false PART_INTERVAL=60 LAST_PART_CHECK=0
  BSTART=$(date +%s); PREV=0; PREV_TS=$BSTART; LAST_ANALYZE=$BSTART
  [ -z "$WALL_START" ] && WALL_START=$BSTART
  [ "$PART_TARGET" -le 0 ] 2>/dev/null && PART_DONE=true
  printf "  %-10s %-12s %-12s %-10s %-8s\n" "Elapsed" "Sink" "Remaining" "Rate/m" "Pct"
  while true; do
    sleep 30
    # Periodically expand partitions for newly created topics
    if ! $PART_DONE; then
      local NOW_P
      NOW_P=$(date +%s)
      if [ $((NOW_P - LAST_PART_CHECK)) -ge "$PART_INTERVAL" ]; then
        LAST_PART_CHECK=$NOW_P
        local presult pexp ptotal
        presult=$(expand_partitions "$PART_TARGET")
        pexp=${presult%% *}; ptotal=${presult##* }
        if [ "$pexp" -gt 0 ]; then
          printf "    [partitions] expanded %s new topics to %s partitions (%s total)\n" "$pexp" "$PART_TARGET" "$ptotal"
        fi
        # All 300 topics exist and are expanded — stop checking
        [ "$ptotal" -ge 300 ] && [ "$pexp" -eq 0 ] && PART_DONE=true
      fi
    fi
    local SINK NOW EL REM DL DT RATE PCT
    NOW=$(date +%s)
    if [ $((NOW - LAST_ANALYZE)) -ge "$ANALYZE_INTERVAL" ]; then
      pg "ANALYZE;" 2>/dev/null; LAST_ANALYZE=$NOW
    fi
    SINK=$(pgv "SELECT COALESCE(SUM(n_live_tup),0) FROM pg_stat_user_tables WHERE schemaname IN ('financedb','retaildb','logsdb');")
    SINK=$(echo "$SINK" | tr -d '[:space:]'); [ -z "$SINK" ] && SINK=0
    EL=$(((NOW-WALL_START)/60)); REM=$((TOTAL-SINK)); [ "$REM" -lt 0 ] && REM=0
    DL=$((SINK-PREV)); DT=$((NOW-PREV_TS))
    if [ "$DT" -gt 0 ] && [ "$DL" -gt 0 ]; then RATE=$((DL*60/DT)); else RATE=0; fi
    if [ "$TOTAL" -gt 0 ]; then PCT=$((SINK*100/TOTAL)); else PCT=0; fi
    [ "$PCT" -gt 100 ] && PCT=100
    printf "  %-10s %-12s %-12s %-10s %-8s\n" "${EL}m" "$SINK" "$REM" "${RATE}/m" "${PCT}%"
    if [ "$SINK" -le "$PREV" ]; then
      STALL_COUNT=$((STALL_COUNT + 1))
      if [ "$STALL_COUNT" -ge "$MAX_STALLS" ]; then
        printf "\n  %bWARN%b No progress for %s checks. Check:\n" "$Y" "$NC" "$MAX_STALLS"
        printf "         ./cdc.sh infra status\n         ./cdc.sh connect restart\n\n"; return 1
      fi
    else STALL_COUNT=0; fi
    PREV=$SINK; PREV_TS=$NOW
    if [ $((NOW - BSTART)) -ge "$TIMEOUT_SECS" ]; then
      printf "\n  %bWARN%b Monitor timeout after %sm. Re-attach: ./cdc.sh pipeline monitor\n\n" "$Y" "$NC" "$((TIMEOUT_SECS / 60))"; return 1
    fi
    # n_live_tup is an estimate; treat >=99% with no lag as complete
    if [ "$SINK" -ge "$TOTAL" ] || { [ "$PCT" -ge 99 ] && [ "$STALL_COUNT" -ge 3 ]; }; then
      snapshot_summary "$SINK" "$WALL_START" "$NOW"
      break
    fi
  done
}

snapshot_summary() {
  local TOTAL="$1" T0="$2" T1="$3"
  local TSEC=$((T1 - T0))
  local HRS=$((TSEC / 3600)) MINS=$(((TSEC % 3600) / 60)) SECS=$((TSEC % 60))
  local AR=0; [ "$TSEC" -gt 0 ] && AR=$((TOTAL * 60 / TSEC))

  printf "\n  %b══════════════════════════════════════════════════════════%b\n" "$G" "$NC"
  printf "  %b  Snapshot Complete%b\n" "$G" "$NC"
  printf "  %b══════════════════════════════════════════════════════════%b\n\n" "$G" "$NC"
  printf "  Total rows:  %s\n" "$TOTAL"
  printf "  Wall time:   %dh %dm %ds  (%s seconds)\n" "$HRS" "$MINS" "$SECS" "$TSEC"
  printf "  Avg rate:    %s rows/min\n" "$AR"

  # ── Collect current config ──────────────────────────
  pg "ANALYZE;" 2>/dev/null

  local WORKERS SINK_TASKS_MAX DBZ_TASKS_MAX SINK_BATCH DBZ_FETCH DBZ_BATCH DBZ_QUEUE
  WORKERS=$(kubectl get pods -n "$NS" -l app=connect --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
  [ -z "$WORKERS" ] && WORKERS=0

  # Read live connector configs (pick first connector as representative)
  local cfg
  cfg=$(kafka_exec curl -s http://localhost:8083/connectors/jdbc-sink-financedb/config 2>/dev/null)
  SINK_TASKS_MAX=$(echo "$cfg" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tasks.max','?'))" 2>/dev/null || echo "?")
  SINK_BATCH=$(echo "$cfg" | python3 -c "import sys,json; print(json.load(sys.stdin).get('batch.size','?'))" 2>/dev/null || echo "?")

  cfg=$(kafka_exec curl -s http://localhost:8083/connectors/debezium-financedb/config 2>/dev/null)
  DBZ_TASKS_MAX=$(echo "$cfg" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tasks.max','?'))" 2>/dev/null || echo "?")
  DBZ_FETCH=$(echo "$cfg" | python3 -c "import sys,json; print(json.load(sys.stdin).get('snapshot.fetch.size','?'))" 2>/dev/null || echo "?")
  DBZ_BATCH=$(echo "$cfg" | python3 -c "import sys,json; print(json.load(sys.stdin).get('max.batch.size','?'))" 2>/dev/null || echo "?")
  DBZ_QUEUE=$(echo "$cfg" | python3 -c "import sys,json; print(json.load(sys.stdin).get('max.queue.size','?'))" 2>/dev/null || echo "?")

  printf "\n  Current config:\n"
  printf "    Connect workers:       %s\n" "$WORKERS"
  local dbz_total="?" sink_total="?"
  [[ "$DBZ_TASKS_MAX" =~ ^[0-9]+$ ]] && dbz_total=$((DBZ_TASKS_MAX * 3))
  [[ "$SINK_TASKS_MAX" =~ ^[0-9]+$ ]] && sink_total=$((SINK_TASKS_MAX * 3))
  printf "    Debezium tasks.max:    %s/connector  (x3 = %s total)\n" "$DBZ_TASKS_MAX" "$dbz_total"
  printf "    Sink tasks.max:        %s/connector  (x3 = %s total)\n" "$SINK_TASKS_MAX" "$sink_total"
  printf "    Debezium fetch size:   %s\n" "$DBZ_FETCH"
  printf "    Debezium batch size:   %s\n" "$DBZ_BATCH"
  printf "    Debezium queue size:   %s\n" "$DBZ_QUEUE"
  printf "    Sink batch size:       %s\n" "$SINK_BATCH"

  # ── Per-schema breakdown ────────────────────────────
  printf "\n  Per-schema:\n"
  printf "    %-15s %12s %8s\n" "Schema" "Rows" "Tables"
  local schema_rows="" max_sr=0 min_sr=999999999999
  for s in $SINK_SCHEMAS; do
    local sr tc
    sr=$(pgv "SELECT COALESCE(SUM(n_live_tup),0) FROM pg_stat_user_tables WHERE schemaname='${s}';" | tr -d '[:space:]')
    tc=$(pgv "SELECT COUNT(*) FROM pg_stat_user_tables WHERE schemaname='${s}';" | tr -d '[:space:]')
    printf "    %-15s %12s %8s\n" "$s" "$sr" "$tc"
    schema_rows="${schema_rows}${s}:${sr} "
    [ "$sr" -gt "$max_sr" ] && max_sr=$sr
    [ "$sr" -lt "$min_sr" ] && min_sr=$sr
  done

  # ── Per-table breakdown ─────────────────────────────
  printf "\n  Top 20 tables by row count:\n"
  printf "    %-15s %-40s %12s\n" "Schema" "Table" "Rows"
  local top1_rows=0 top1_name="" table_count=0
  pgv "SELECT schemaname, relname, n_live_tup FROM pg_stat_user_tables WHERE schemaname IN ('financedb','retaildb','logsdb') ORDER BY n_live_tup DESC LIMIT 20;" \
    | while IFS='|' read -r schema tbl rows; do
        schema=$(echo "$schema" | tr -d '[:space:]')
        tbl=$(echo "$tbl" | tr -d '[:space:]')
        rows=$(echo "$rows" | tr -d '[:space:]')
        printf "    %-15s %-40s %12s\n" "$schema" "$tbl" "$rows"
      done
  top1_rows=$(pgv "SELECT COALESCE(MAX(n_live_tup),0) FROM pg_stat_user_tables WHERE schemaname IN ('financedb','retaildb','logsdb');" | tr -d '[:space:]')
  top1_name=$(pgv "SELECT schemaname||'.'||relname FROM pg_stat_user_tables WHERE schemaname IN ('financedb','retaildb','logsdb') ORDER BY n_live_tup DESC LIMIT 1;" | tr -d '[:space:]')
  table_count=$(pgv "SELECT COUNT(*) FROM pg_stat_user_tables WHERE schemaname IN ('financedb','retaildb','logsdb');" | tr -d '[:space:]')

  # ── Tuning recommendations ──────────────────────────
  printf "\n  %b── Tuning Recommendations ──%b\n\n" "$C" "$NC"
  local tips=0

  # 1. Worker utilization: total tasks vs workers
  local total_dbz_tasks=0 total_sink_tasks=0
  [[ "${DBZ_TASKS_MAX:-0}" =~ ^[0-9]+$ ]] && total_dbz_tasks=$((DBZ_TASKS_MAX * 3))
  [[ "${SINK_TASKS_MAX:-0}" =~ ^[0-9]+$ ]] && total_sink_tasks=$((SINK_TASKS_MAX * 3))
  local total_tasks=$((total_dbz_tasks + total_sink_tasks))
  if [ "$WORKERS" -gt 0 ] && [ "$total_tasks" -gt 0 ]; then
    local tasks_per_worker=$((total_tasks / WORKERS))
    if [ "$tasks_per_worker" -lt 3 ]; then
      tips=$((tips + 1))
      printf "  %d. %bUnderutilized workers%b — %s tasks across %s workers (%s/worker).\n" \
        "$tips" "$Y" "$NC" "$total_tasks" "$WORKERS" "$tasks_per_worker"
      printf "     Reduce workers or increase tasks.max. Try:\n"
      printf "       ./cdc.sh pipeline snapshot %s\n\n" "$((total_tasks / 4 + 1))"
    fi
    if [ "$total_tasks" -gt $((WORKERS * 8)) ]; then
      tips=$((tips + 1))
      printf "  %d. %bOverloaded workers%b — %s tasks on %s workers (%s/worker).\n" \
        "$tips" "$Y" "$NC" "$total_tasks" "$WORKERS" "$tasks_per_worker"
      printf "     Add workers to spread the load. Try:\n"
      printf "       ./cdc.sh pipeline snapshot %s\n\n" "$((total_tasks / 5 + 1))"
    fi
  fi

  # 2. Schema imbalance: flag if one DB has 2x+ rows of another
  if [ "$min_sr" -gt 0 ] && [ "$max_sr" -gt $((min_sr * 2)) ]; then
    tips=$((tips + 1))
    printf "  %d. %bSchema imbalance%b — largest schema has %sx more rows than smallest.\n" \
      "$tips" "$Y" "$NC" "$((max_sr / min_sr))"
    printf "     Uneven data means some Debezium tasks finish early and sit idle.\n"
    printf "     Consider increasing debezium_task_max to spread tables across more tasks.\n\n"
  fi

  # 3. Large table hotspot: if top table > 20% of total
  if [ "$TOTAL" -gt 0 ] && [ "$top1_rows" -gt $((TOTAL / 5)) ]; then
    local top_pct=$((top1_rows * 100 / TOTAL))
    tips=$((tips + 1))
    printf "  %d. %bLarge table hotspot%b — %s has %s%% of all rows (%s).\n" \
      "$tips" "$Y" "$NC" "$top1_name" "$top_pct" "$top1_rows"
    printf "     This table bottlenecks the snapshot. Options:\n"
    printf "       - Increase snapshot.fetch.size (currently %s) -> try 20000 or 50000\n" "$DBZ_FETCH"
    printf "       - Increase max.batch.size (currently %s) -> try 8192\n" "$DBZ_BATCH"
    printf "       - In terraform.tfvars: debezium_task_max = %s\n\n" "$((${DBZ_TASKS_MAX:-10} + 5))"
  fi

  # 4. Sink throughput: check batch size
  if [ "${SINK_BATCH:-0}" != "?" ] && [ "${SINK_BATCH:-0}" -lt 5000 ] 2>/dev/null; then
    tips=$((tips + 1))
    printf "  %d. %bSmall sink batch size%b — currently %s.\n" \
      "$tips" "$Y" "$NC" "$SINK_BATCH"
    printf "     Larger batches reduce Aurora round-trips. Try:\n"
    printf "       In terraform.tfvars: jdbc_sink_batch_size = 10000\n\n"
  fi

  # 5. Rate-based projection: what if 2x workers?
  if [ "$AR" -gt 0 ] && [ "$WORKERS" -gt 0 ]; then
    local projected=$((AR * 2))
    local proj_secs=$((TOTAL * 60 / projected))
    local proj_h=$((proj_secs / 3600)) proj_m=$(((proj_secs % 3600) / 60))
    tips=$((tips + 1))
    printf "  %d. %bProjection%b — at 2x workers (%s), estimated time: ~%dh %dm\n" \
      "$tips" "$C" "$NC" "$((WORKERS * 2))" "$proj_h" "$proj_m"
    printf "     (assumes linear scaling; actual gains depend on source/sink bottlenecks)\n"
    printf "       ./cdc.sh pipeline snapshot %s\n\n" "$((WORKERS * 2))"
  fi

  # 6. Debezium queue sizing
  if [ "${DBZ_BATCH:-0}" != "?" ] && [ "${DBZ_QUEUE:-0}" != "?" ] 2>/dev/null; then
    local ratio=$((${DBZ_QUEUE:-0} / ${DBZ_BATCH:-1}))
    if [ "$ratio" -lt 4 ]; then
      tips=$((tips + 1))
      printf "  %d. %bSmall Debezium queue%b — queue/batch ratio is %s (recommend >=4).\n" \
        "$tips" "$Y" "$NC" "$ratio"
      printf "     Increase max.queue.size to avoid backpressure stalls.\n"
      printf "       Suggested: max.queue.size = %s\n\n" "$((${DBZ_BATCH:-4096} * 8))"
    fi
  fi

  if [ "$tips" -eq 0 ]; then
    printf "  %bNo obvious bottlenecks detected.%b Config looks well-tuned for this workload.\n\n" "$G" "$NC"
  fi

  printf "  Verify: ./cdc.sh pipeline verify\n\n"
}
