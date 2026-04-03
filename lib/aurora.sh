# lib/aurora.sh — Aurora PostgreSQL lifecycle helpers
# Sourced by cdc.sh — depends on lib/common.sh (pg, pgv, SINK_SCHEMAS)

aurora_ensure_schemas() {
  pg "DROP SCHEMA IF EXISTS public CASCADE;" 2>/dev/null
  printf "      dropped schema public\n"
  for s in $SINK_SCHEMAS; do
    pg "CREATE SCHEMA IF NOT EXISTS \"${s}\";" 2>/dev/null
    printf "      created schema %s\n" "$s"
  done
}

aurora_tune_bulk() {
  printf "\n    Tuning Aurora for bulk writes ...\n"
  [ -z "$PH" ] || [ -z "$PU" ] && { printf "      %bSKIP%b Aurora not found\n" "$Y" "$NC"; return; }
  aurora_ensure_schemas
  local count=0
  for s in $SINK_SCHEMAS; do
    for tbl in $(pgv "SELECT tablename FROM pg_tables WHERE schemaname='${s}';"); do
      tbl=$(echo "$tbl" | tr -d '[:space:]'); [ -z "$tbl" ] && continue
      pg "ALTER TABLE \"${s}\".\"${tbl}\" SET (autovacuum_enabled = false);" 2>/dev/null
      printf "      autovacuum off  %s.%s\n" "$s" "$tbl"
      count=$((count + 1))
    done
  done
  [ "$count" -gt 0 ] && printf "      %bOK%b autovacuum disabled on %s tables\n" "$G" "$NC" "$count"
  local idx_count=0
  for s in $SINK_SCHEMAS; do
    for idx in $(pgv "SELECT indexname FROM pg_indexes WHERE schemaname='${s}' AND indexname NOT LIKE '%_pkey' ORDER BY indexname;"); do
      idx=$(echo "$idx" | tr -d '[:space:]'); [ -z "$idx" ] && continue
      pg "DROP INDEX IF EXISTS \"${s}\".\"${idx}\";" 2>/dev/null
      printf "      dropped index %s.%s\n" "$s" "$idx"
      idx_count=$((idx_count + 1))
    done
  done
  [ "$idx_count" -gt 0 ] && printf "      %bOK%b dropped %s non-PK indexes\n" "$G" "$NC" "$idx_count"
}

aurora_tune_revert() {
  printf "\n    Reverting Aurora to safe defaults ...\n"
  [ -z "$PH" ] || [ -z "$PU" ] && { printf "      %bSKIP%b Aurora not found\n" "$Y" "$NC"; return; }
  local count=0
  for s in $SINK_SCHEMAS; do
    for tbl in $(pgv "SELECT tablename FROM pg_tables WHERE schemaname='${s}';"); do
      tbl=$(echo "$tbl" | tr -d '[:space:]'); [ -z "$tbl" ] && continue
      pg "ALTER TABLE \"${s}\".\"${tbl}\" SET (autovacuum_enabled = true);" 2>/dev/null
      printf "      autovacuum on   %s.%s\n" "$s" "$tbl"
      count=$((count + 1))
    done
  done
  [ "$count" -gt 0 ] && printf "      %bOK%b autovacuum re-enabled on %s tables\n" "$G" "$NC" "$count"
  pg "ANALYZE;" 2>/dev/null
  printf "      %bOK%b ANALYZE complete\n" "$G" "$NC"
}

aurora_clean() {
  [ -z "$PH" ] || [ -z "$PU" ] && { printf "      %bSKIP%b Aurora not found\n" "$Y" "$NC"; return; }
  for s in $SINK_SCHEMAS; do
    pg "DROP SCHEMA IF EXISTS \"${s}\" CASCADE;" 2>/dev/null
    printf "      dropped schema %s\n" "$s"
  done
  pg "DROP SCHEMA IF EXISTS public CASCADE;" 2>/dev/null
  printf "      dropped schema public\n"
  pg "ANALYZE;" 2>/dev/null
  printf "    %bOK%b Aurora schemas dropped\n" "$G" "$NC"
}
