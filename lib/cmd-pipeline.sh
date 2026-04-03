# lib/cmd-pipeline.sh — pipeline subcommand
# Sourced by cdc.sh — depends on all lib modules

SUB="${1:-help}"; shift 2>/dev/null || true

case "$SUB" in
  snapshot)
    N="${1:-6}"
    printf "\n%b   +=== Full Snapshot (%s workers) ===%b\n\n" "$C" "$N" "$NC"

    # [1/6] Count source rows
    printf "  [1/6] Counting source rows ...\n"
    count_source_rows
    TOTAL=$(cat /tmp/cdc_source_total 2>/dev/null || echo "0")
    if [ "$TOTAL" -eq 0 ]; then
      printf "    %bERROR%b No rows in SQL Server. Run ./scripts/seed-source-db.sh first.\n\n" "$R" "$NC"; exit 1
    fi

    # [2/6] Reset pipeline
    printf "\n  [2/6] Resetting pipeline ...\n"
    connect_stop
    printf "\n    Deleting SR subjects ...\n"
    delete_sr_subjects cdc
    printf "\n    Deleting CDC data topics ...\n"
    delete_cdc_topics
    printf "\n    Resetting Connect offsets and schema history ...\n"
    for topic in confluent.connect-offsets confluent.connect-configs confluent.connect-status _sh_financedb _sh_retaildb _sh_logsdb; do
      kafka_exec kafka-topics --bootstrap-server localhost:9071 \
        --delete --if-exists --topic "$topic" 2>/dev/null || true
      printf "    deleted %s\n" "$topic"
    done
    printf "\n    Deleting stale consumer groups ...\n"
    delete_connect_consumer_groups
    printf "\n    Cleaning Aurora ...\n"
    aurora_clean

    # [3/6] Start Connect
    SNAP_START=$(date +%s)
    printf "\n  [3/6] Starting Connect (bulk, %s workers) ...\n" "$N"
    connect_scale bulk "$N"
    epf || { printf "    %bERROR%b Cannot reach Connect REST\n\n" "$R" "$NC"; exit 1; }
    wait_connectors_running 180

    # [4/6] Scale tasks and partitions for parallel writes
    snap_tasks=$((N > 1 ? N : 3))
    printf "\n  [4/6] Scaling connectors to %s tasks/partitions ...\n" "$snap_tasks"

    # Update Debezium source connectors: topic.creation.default.partitions
    for db in $DBS; do
      cfg=$(curl -s "$API/debezium-${db}/config" 2>/dev/null)
      if [ -n "$cfg" ]; then
        echo "$cfg" | python3 -c "
import sys, json
cfg = json.load(sys.stdin)
cfg['topic.creation.default.partitions'] = '$snap_tasks'
print(json.dumps(cfg))
" | curl -s -X PUT -H "Content-Type: application/json" -d @- "$API/debezium-${db}/config" >/dev/null 2>&1
        printf "    debezium-%s -> topic.creation.default.partitions=%s\n" "$db" "$snap_tasks"
      fi
    done

    # Update JDBC sink connectors: tasks.max
    for db in $DBS; do
      cfg=$(curl -s "$API/jdbc-sink-${db}/config" 2>/dev/null)
      if [ -n "$cfg" ]; then
        echo "$cfg" | python3 -c "
import sys, json
cfg = json.load(sys.stdin)
cfg['tasks.max'] = '$snap_tasks'
print(json.dumps(cfg))
" | curl -s -X PUT -H "Content-Type: application/json" -d @- "$API/jdbc-sink-${db}/config" >/dev/null 2>&1
        printf "    jdbc-sink-%s -> tasks.max=%s\n" "$db" "$snap_tasks"
      fi
    done
    printf "    %bOK%b connectors scaled (CFK will revert on next reconcile)\n" "$G" "$NC"

    # [5/6] Initial partition expansion (continues in monitor)
    printf "\n  [5/6] Expanding topic partitions to %s ...\n" "$snap_tasks"
    # Wait for Debezium to create some data topics (up to 90s)
    for attempt in $(seq 1 18); do
      topic_count=$(kafka_exec kafka-topics --bootstrap-server localhost:9071 --list \
        | grep -cE '^(financedb|retaildb|logsdb)\.' || echo "0")
      [ "$topic_count" -ge 100 ] && break
      sleep 5
    done
    printf "    %s data topics found\n" "$topic_count"
    result=$(expand_partitions "$snap_tasks")
    exp_count=${result%% *}; exp_total=${result##* }
    if [ "$exp_total" -gt 0 ]; then
      printf "    %bOK%b %s/%s topics expanded to %s partitions\n" "$G" "$NC" "$exp_count" "$exp_total" "$snap_tasks"
      [ "$exp_total" -lt 300 ] && printf "    Remaining topics will be expanded during monitor\n"
    else
      printf "    %bWARN%b no data topics found after 90s\n" "$Y" "$NC"
    fi

    # [6/6] Monitor
    printf "\n  [6/6] Monitoring snapshot -> Aurora ...\n"
    printf "         Started: %s\n" "$(date -d @"$SNAP_START" '+%Y-%m-%d %H:%M:%S')"
    printf "         Re-attach anytime: ./cdc.sh pipeline monitor\n\n"
    monitor "$TOTAL" "$SNAP_START" "$snap_tasks"
    ;;

  cdc)
    GB_DAY="${1:-300}"
    BATCH=500
    BYTES_PER_ROW=650
    BYTES_PER_SEC=$((GB_DAY * 1073741824 / 86400))
    ROWS_PER_SEC=$((BYTES_PER_SEC / BYTES_PER_ROW))
    if [ "$ROWS_PER_SEC" -gt 0 ]; then
      SLEEP_MS=$((BATCH * 1000 / ROWS_PER_SEC))
    else
      SLEEP_MS=1000
    fi

    FIN="accounts transactions ledger invoices payments vendors budgets forecasts credit_lines credit_scores"
    RET="products orders order_items inventory shipments returns reviews promotions categories suppliers"
    LOG="app_events api_calls user_sessions error_logs metrics alerts notifications jobs task_queue system_audit"

    printf "\n%b   +=== CDC Load: %s GB/day ===%b\n\n" "$C" "$GB_DAY" "$NC"
    printf "    Target:  %s rows/sec (%s MB/s)\n" "$ROWS_PER_SEC" "$((BYTES_PER_SEC / 1048576))"
    printf "    Batch:   %s rows | Tables: 30 | Mix: 70/20/10 I/U/D\n" "$BATCH"
    printf "    Ctrl+C to stop.\n\n"

    TOTAL_OPS=0; START_TS=$(date +%s)
    printf "  %-10s %-12s %-10s %-10s\n" "Elapsed" "Total Ops" "Rate/s" "GB est"

    while true; do
      for db in $DBS; do
        case "$db" in
          financedb) TBLS="$FIN" ;; retaildb) TBLS="$RET" ;; logsdb) TBLS="$LOG" ;;
        esac
        for t in $TBLS; do
          RAND=$((RANDOM % 100))
          if [ "$RAND" -lt 70 ]; then
            sd "$db" "INSERT INTO dbo.${t}(ref_id,name,category,amount,status,description,metadata,padding)
              SELECT TOP($BATCH) ABS(CHECKSUM(NEWID()))%1000000,
                CONCAT(N'${t}-cdc-',ABS(CHECKSUM(NEWID()))%100000),N'cdc',
                CAST(RAND(CHECKSUM(NEWID()))*9999+1 AS DECIMAL(12,2)),N'active',
                CONCAT(N'CDC ',SYSUTCDATETIME()),N'{\"cdc\":true}',REPLICATE('C',200)
              FROM dbo.${t}" 2>/dev/null || true
          elif [ "$RAND" -lt 90 ]; then
            sd "$db" "UPDATE TOP($BATCH) dbo.${t}
              SET amount=CAST(RAND(CHECKSUM(NEWID()))*9999+1 AS DECIMAL(12,2)),
                  status=CASE WHEN status=N'active' THEN N'updated' ELSE N'active' END,
                  updated_at=SYSUTCDATETIME()
              WHERE id % $((RANDOM % 100 + 1)) = 0" 2>/dev/null || true
          else
            sd "$db" "DELETE TOP($((BATCH/5))) FROM dbo.${t}
              WHERE description LIKE N'CDC%'
              AND id IN (SELECT TOP($((BATCH/5))) id FROM dbo.${t}
                         WHERE description LIKE N'CDC%' ORDER BY id ASC)" 2>/dev/null || true
          fi
          TOTAL_OPS=$((TOTAL_OPS + BATCH))
          if [ "$SLEEP_MS" -gt 0 ]; then
            sleep "$(echo "scale=3; $SLEEP_MS/1000" | bc 2>/dev/null || echo "$((SLEEP_MS / 1000)).$(printf '%03d' $((SLEEP_MS % 1000)))")"
          fi
        done
      done
      NOW=$(date +%s); EL=$((NOW - START_TS))
      if [ "$EL" -gt 0 ]; then
        RATE=$((TOTAL_OPS / EL))
        GB_EST=$(echo "scale=2; $TOTAL_OPS * 650 / 1073741824" | bc 2>/dev/null || echo "?")
      else RATE=0; GB_EST=0; fi
      printf "\r  %-10s %-12s %-10s %-10s" "$((EL/60))m" "$TOTAL_OPS" "${RATE}/s" "${GB_EST}GB"
    done
    ;;

  monitor)
    printf "\n%b   +=== Re-attach Monitor ===%b\n\n" "$C" "$NC"
    printf "  Source rows:\n"
    count_source_rows
    TOTAL=$(cat /tmp/cdc_source_total 2>/dev/null || echo "0")
    printf "\n"
    monitor "$TOTAL"
    ;;

  verify)
    printf "\n%b   +=== Verify: SQL Server vs Aurora ===%b\n\n" "$C" "$NC"

    # ── Summary by database ──
    printf "  %-15s %12s %8s    %12s %8s    %8s\n" "Database" "Src Rows" "Tables" "Sink Rows" "Tables" "Match"
    printf "  %s\n" "──────────────────────────────────────────────────────────────────────────────"
    SRC_TOTAL=0; SINK_TOTAL=0; SRC_TABLES_TOTAL=0; SINK_TABLES_TOTAL=0
    pg "ANALYZE;" 2>/dev/null
    for db in $DBS; do
      # Use DISTINCT count for no-PK tables (upsert deduplicates them)
      SR=$(sd "$db" "SET NOCOUNT ON;
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
      ST=$(sd "$db" "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped=0" \
        | tr -d ' ' | grep -E '^[0-9]+$' | head -1 || echo "0")
      KR=$(pgv "SELECT COALESCE(SUM(n_live_tup),0) FROM pg_stat_user_tables WHERE schemaname='${db}';" | tr -d '[:space:]')
      KT=$(pgv "SELECT COUNT(*) FROM pg_stat_user_tables WHERE schemaname='${db}';" | tr -d '[:space:]')
      match_icon="✗"
      [ "$SR" = "$KR" ] && [ "$ST" = "$KT" ] && match_icon="✓"
      printf "  %-15s %12s %8s    %12s %8s    %8s\n" "$db" "$SR" "$ST" "$KR" "$KT" "$match_icon"
      SRC_TOTAL=$((SRC_TOTAL + SR)); SINK_TOTAL=$((SINK_TOTAL + KR))
      SRC_TABLES_TOTAL=$((SRC_TABLES_TOTAL + ST)); SINK_TABLES_TOTAL=$((SINK_TABLES_TOTAL + KT))
    done
    printf "  %s\n" "──────────────────────────────────────────────────────────────────────────────"
    printf "  %-15s %12s %8s    %12s %8s\n" "TOTAL" "$SRC_TOTAL" "$SRC_TABLES_TOTAL" "$SINK_TOTAL" "$SINK_TABLES_TOTAL"

    # ── Overall verdict ──
    if [ "$SRC_TOTAL" -gt 0 ]; then
      DIFF=$((SRC_TOTAL - SINK_TOTAL))
      PCT=$((SINK_TOTAL * 100 / SRC_TOTAL))
      printf "\n  Rows:   %s source -> %s sink (delta: %s, coverage: %s%%)\n" "$SRC_TOTAL" "$SINK_TOTAL" "$DIFF" "$PCT"
      printf "  Tables: %s source -> %s sink\n" "$SRC_TABLES_TOTAL" "$SINK_TABLES_TOTAL"
      if [ "$DIFF" -eq 0 ] && [ "$SRC_TABLES_TOTAL" -eq "$SINK_TABLES_TOTAL" ]; then
        printf "\n  %b✓ PASS%b — All rows and tables match\n" "$G" "$NC"
      elif [ "$DIFF" -le 0 ]; then
        printf "\n  %b✓ PASS%b — Sink has all source rows\n" "$G" "$NC"
      elif [ "$PCT" -ge 99 ]; then
        printf "\n  %b~ PASS%b — >99%% coverage, remaining delta likely in-flight\n" "$G" "$NC"
      else
        printf "\n  %b✗ FAIL%b — %s rows missing (%s%%)\n" "$R" "$NC" "$DIFF" "$((100 - PCT))"
      fi
    else
      printf "\n  %bWARN%b Source is empty — nothing to verify\n" "$Y" "$NC"
    fi

    # ── Per-table mismatches ──
    mismatches=""
    for db in $DBS; do
      src_tables=""
      # Use DISTINCT count for no-PK tables
      src_tables=$(sd "$db" "SET NOCOUNT ON;
SELECT t.name + '|' + CAST(p.rows AS VARCHAR)
  FROM sys.tables t
  JOIN sys.partitions p ON t.object_id = p.object_id
  WHERE p.index_id IN (0,1) AND t.is_ms_shipped = 0
    AND EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1)
  ORDER BY t.name;
DECLARE @tname NVARCHAR(256), @sql NVARCHAR(MAX), @cnt BIGINT;
DECLARE nopk CURSOR FAST_FORWARD FOR
  SELECT t.name FROM sys.tables t
  WHERE t.is_ms_shipped = 0
    AND NOT EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1)
  ORDER BY t.name;
OPEN nopk; FETCH NEXT FROM nopk INTO @tname;
WHILE @@FETCH_STATUS = 0 BEGIN
  SET @sql = N'SELECT @c = COUNT(*) FROM (SELECT DISTINCT * FROM ' + QUOTENAME(@tname) + N') t';
  EXEC sp_executesql @sql, N'@c BIGINT OUTPUT', @c = @cnt OUTPUT;
  PRINT @tname + '|' + CAST(@cnt AS VARCHAR);
  FETCH NEXT FROM nopk INTO @tname;
END; CLOSE nopk; DEALLOCATE nopk;" \
        | tr -d ' ' | grep -E '.+\|[0-9]+' || echo "")
      [ -z "$src_tables" ] && continue
      while IFS='|' read -r tname srows; do
        [ -z "$tname" ] && continue
        krows=$(pgv "SELECT COALESCE(n_live_tup,0) FROM pg_stat_user_tables WHERE schemaname='${db}' AND relname='${tname}';" | tr -d '[:space:]')
        krows="${krows:-0}"
        if [ "$srows" != "$krows" ]; then
          mismatches="${mismatches}$(printf "    %-15s %-40s %12s %12s %+d\n" "$db" "$tname" "$srows" "$krows" "$((krows - srows))")\n"
        fi
      done <<< "$src_tables"
    done

    if [ -n "$mismatches" ]; then
      printf "\n  %bMismatched tables:%b\n" "$Y" "$NC"
      printf "    %-15s %-40s %12s %12s %8s\n" "Schema" "Table" "Source" "Sink" "Delta"
      printf "    %s\n" "────────────────────────────────────────────────────────────────────────────────"
      printf "%b" "$mismatches"
    else
      if [ "$SRC_TOTAL" -gt 0 ]; then
        printf "\n  All %s tables match row-for-row\n" "$SRC_TABLES_TOTAL"
      fi
    fi

    # ── Sink data size ──
    sink_size=$(pgv "SELECT pg_size_pretty(SUM(pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(relname)))) FROM pg_stat_user_tables WHERE schemaname IN ('financedb','retaildb','logsdb');" | tr -d '[:space:]')
    [ -n "$sink_size" ] && [ "$sink_size" != "0bytes" ] && printf "\n  Sink size: %s (Aurora)\n" "$sink_size"

    printf "\n"
    ;;

  reset)
    printf "\n%b   +=== Pipeline Reset ===%b\n\n" "$C" "$NC"
    printf "    Steps: stop Connect, delete SR subjects, delete CDC topics, delete consumer groups, clean Aurora.\n"
    read -p "    Type 'reset' to confirm: " CONFIRM
    [ "$CONFIRM" != "reset" ] && { printf "    Aborted.\n\n"; exit 0; }

    printf "\n  [1/5] Stopping Connect ...\n"
    connect_stop
    printf "    %bOK%b\n" "$G" "$NC"

    printf "\n  [2/5] Deleting SR subjects ...\n"
    delete_sr_subjects cdc

    printf "\n  [3/5] Deleting CDC topics ...\n"
    delete_cdc_topics

    printf "\n  [4/5] Deleting stale consumer groups ...\n"
    delete_connect_consumer_groups

    printf "\n  [5/5] Cleaning Aurora ...\n"
    aurora_clean

    printf "\n  %bReady for fresh start:%b\n" "$G" "$NC"
    printf "    ./scripts/seed-source-db.sh 1000     # if re-seeding needed\n"
    printf "    ./cdc.sh pipeline snapshot            # start snapshot\n\n"
    ;;

  *)
    printf "\n  ./cdc.sh pipeline <snapshot [N]|cdc <GB/day>|monitor|verify|reset>\n\n"
    ;;
esac
