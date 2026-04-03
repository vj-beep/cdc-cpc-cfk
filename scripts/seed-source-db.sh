
#!/usr/bin/env bash
set -euo pipefail

# ================================================================
# seed-source-db.sh  (standard — INSERT...SELECT doubling)
# Seeds 3 databases × 100 tables each (300 total) in SQL Server.
# Works on any instance size. For faster loads on large instances
# with storage, use seed-source-db-fast.sh (bcp bulk import).
# Usage:
#   ./seed-source-db.sh [--clean] <SIZE>
#   SIZE     100MB, 1GB, 10GB, 1000GB (MB or GB suffix required)
#   --clean  Drop all 3 SQL Server DBs + all Aurora tables first
# ================================================================

usage() {
  cat <<'EOF'
Usage: ./seed-source-db.sh [--clean] <SIZE>

  SIZE      Target data volume across 300 tables (3 DBs x 100 tables)
            Must include MB or GB suffix (e.g. 100MB, 1GB, 1000GB)

  --clean   Drop all 3 SQL Server DBs + all Aurora tables before seeding

Examples:
  ./seed-source-db.sh 100MB              # quick test
  ./seed-source-db.sh --clean 1GB        # clean + seed 1 GB
  ./seed-source-db.sh 100GB              # resume/grow to 100 GB
  ./seed-source-db.sh --clean 1000GB     # full 1 TB seed

Environment:
  PARALLEL_JOBS=N   parallel doubling workers (default: 16)
EOF
  exit 0
}

[ $# -eq 0 ] && usage
[[ "${1:-}" =~ ^(-h|--help|help)$ ]] && usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

if [ ! -f terraform.tfvars ]; then echo "ERROR: Run from cdc-on-cpc/"; exit 1; fi

# Use ODBC sqlcmd, not the Go-based one
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"
if [ ! -x "$SQLCMD" ]; then
  echo "ERROR: ODBC sqlcmd not found at $SQLCMD"
  echo "       Install: sudo ACCEPT_EULA=Y dnf install -y mssql-tools18"
  exit 1
fi

SH=$(terraform output -raw sqlserver_endpoint 2>/dev/null | cut -d: -f1)
SP=$(terraform output -raw sqlserver_endpoint 2>/dev/null | cut -d: -f2)
SU=$(grep sqlserver_username terraform.tfvars | awk -F'"' '{print $2}')
SW=$(grep sqlserver_password terraform.tfvars | awk -F'"' '{print $2}')

if [ -z "$SH" ] || [ -z "$SP" ] || [ -z "$SU" ] || [ -z "$SW" ]; then
  echo "ERROR: Could not resolve SQL Server connection details."
  echo "       Ensure 'terraform apply' has been run and terraform.tfvars has credentials."
  exit 1
fi
SC="${SH},${SP}"

PH=$(terraform output -raw aurora_pg_endpoint 2>/dev/null | cut -d: -f1 || echo "")
PP=$(terraform output -raw aurora_pg_endpoint 2>/dev/null | cut -d: -f2 || echo "5432")
PU=$(grep aurora_username terraform.tfvars 2>/dev/null | awk -F'"' '{print $2}' || echo "")
PW=$(grep aurora_password terraform.tfvars 2>/dev/null | awk -F'"' '{print $2}' || echo "")
PD=$(grep aurora_db_name terraform.tfvars 2>/dev/null | awk -F'"' '{print $2}' || echo "sinkdb")
export PGPASSWORD="${PW}"

G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; NC='\033[0m'

sql()  { $SQLCMD -C -S "${SC}" -U "${SU}" -P "${SW}" -Q "$1" -W &>/dev/null; }
dql()  { $SQLCMD -C -S "${SC}" -U "${SU}" -P "${SW}" -Q "USE [$1]; SET NOCOUNT ON; $2" -W &>/dev/null; }
dval() { $SQLCMD -C -S "${SC}" -U "${SU}" -P "${SW}" -h -1 -Q "USE [$1]; SET NOCOUNT ON; $2" -W 2>/dev/null | grep -v '^Changed database' | tr -d ' \r\n' | grep -oE '^[0-9]+' || echo "0"; }
# Run a .sql file against a database
dfile() { $SQLCMD -C -S "${SC}" -U "${SU}" -P "${SW}" -Q "USE [$1]; $(cat "$2")" -W &>/dev/null; }
pgv()  { PGPASSWORD="${PW}" psql -h "${PH}" -p "${PP}" -U "${PU}" -d "${PD}" -t -A -c "$1" 2>/dev/null || echo "0"; }
pg()   { PGPASSWORD="${PW}" psql -h "${PH}" -p "${PP}" -U "${PU}" -d "${PD}" -c "$1" &>/dev/null; }

CLEAN=false
[ "${1:-}" = "--clean" ] && { CLEAN=true; shift; }
if [ -z "${1:-}" ]; then echo "ERROR: SIZE required. Run with --help for usage."; exit 1; fi
SIZE_ARG="$1"

# Parse size: MB or GB suffix required
parse_size_bytes() {
  local input="${1^^}"  # uppercase
  if [[ "$input" =~ ^([0-9]+)MB$ ]]; then
    echo $(( ${BASH_REMATCH[1]} * 1048576 ))
  elif [[ "$input" =~ ^([0-9]+)GB$ ]]; then
    echo $(( ${BASH_REMATCH[1]} * 1073741824 ))
  else
    echo "ERROR: Invalid size '$1'. Must include MB or GB suffix (e.g. 100MB, 1GB, 1000GB)" >&2
    exit 1
  fi
}

TARGET_BYTES=$(parse_size_bytes "$SIZE_ARG")

# Human-readable label for display
if [ "$TARGET_BYTES" -ge 1073741824 ]; then
  TARGET_LABEL="$((TARGET_BYTES / 1073741824)) GB"
else
  TARGET_LABEL="$((TARGET_BYTES / 1048576)) MB"
fi

DBS="financedb retaildb logsdb"
TABLES_TOTAL=300
MAX_DOUBLES=30
PARALLEL_JOBS="${PARALLEL_JOBS:-16}"

# Weighted average bytes/row across all table types:
#   25 standard(600) + 20 medium(1000) + 20 reference(200) + 15 junction(300)
#   + 15 event(800) + 1 wide(3000) + 1 narrow(50) + 1 lob(5000) + 1 nopk(800) + 1 pii(900)
# = (25*600 + 20*1000 + 20*200 + 15*300 + 15*800 + 3000 + 50 + 5000 + 800 + 900) / 100 = 614
BYTES_PER_ROW=614
PTR=$((TARGET_BYTES / TABLES_TOTAL / BYTES_PER_ROW))

# Per-type row targets (adjust for actual row sizes)
bytes_per_type() {
  case "$1" in
    standard)  echo 600  ;;
    medium)    echo 1000 ;;
    reference) echo 200  ;;
    junction)  echo 300  ;;
    event)     echo 800  ;;
    wide)      echo 3000 ;;
    narrow)    echo 50   ;;
    lob)       echo 5000 ;;
    nopk)      echo 800  ;;
    pii)       echo 900  ;;
    *)         echo 650  ;;
  esac
}

target_rows_for_type() {
  local typ="$1"
  local bpr
  bpr=$(bytes_per_type "$typ")
  echo $((TARGET_BYTES / TABLES_TOTAL / bpr))
}

# ================================================================
# Table lists per DB
# ================================================================
# 5 special + 25 A + 20 B + 20 C + 15 D + 15 E = 100 per DB

SPECIALS_FIN="fin_claims_wide:wide fin_currency_codes:narrow fin_document_store:lob fin_legacy_journal:nopk fin_customer_pii:pii"
SPECIALS_RET="ret_product_catalog_wide:wide ret_status_codes:narrow ret_media_assets:lob ret_clickstream:nopk ret_customer_profiles:pii"
SPECIALS_LOG="log_telemetry_wide:wide log_severity_codes:narrow log_crash_dumps:lob log_raw_events:nopk log_user_activity:pii"

STD_A_FIN="accounts transactions ledger invoices payments vendors budgets forecasts credit_lines credit_scores gl_entries gl_periods gl_accounts ap_invoices ap_payments ar_invoices ar_receipts bank_accounts bank_txns bank_recon cost_centers expense_reports fixed_assets asset_deprec payroll_runs"
STD_A_RET="products orders order_items inventory shipments returns reviews promotions categories suppliers warehouses shelf_locations pick_lists pack_slips delivery_routes store_locations register_txns gift_cards loyalty_points price_rules coupons bundles markdown_events purchase_orders po_lines"
STD_A_LOG="app_events api_calls user_sessions error_logs metrics alerts notifications jobs task_queue system_audit deployment_logs config_changes health_checks service_deps latency_samples throughput_samples resource_usage connection_pools thread_dumps gc_events heap_snapshots cpu_profiles disk_io_samples network_io_samples cache_stats"

STD_B_FIN="journal_entries journal_lines loan_applications loan_payments loan_schedules investment_positions investment_txns insurance_policies insurance_claims compliance_checks risk_assessments risk_scores fx_rates fx_txns wire_transfers portfolio_holdings fund_transfers tax_filings tax_rates settlement_batches"
STD_B_RET="cart_items cart_sessions wishlist_items product_variants sku_master vendor_catalogs vendor_orders vendor_invoices vendor_payments vendor_returns fulfillment_orders fulfillment_lines shipping_labels tracking_events carrier_rates demand_forecasts replenishment_orders allocation_rules markdown_rules seasonal_plans"
STD_B_LOG="request_traces span_details trace_annotations error_details exception_stacks slow_queries query_plans index_usage table_stats lock_waits replication_lag consumer_lag producer_metrics broker_metrics topic_metrics connector_metrics task_metrics worker_metrics cluster_metrics partition_metrics"

STD_C_FIN="currency_ref country_ref state_ref account_types txn_types status_codes priority_codes department_ref branch_ref region_ref product_types fee_schedules rate_tables tax_codes approval_levels payment_methods entity_types doc_categories risk_levels gl_categories"
STD_C_RET="color_ref size_ref brand_ref material_ref season_ref channel_ref store_type_ref region_ref country_ref currency_ref unit_of_measure_ref tax_class_ref shipping_method_ref return_reason_ref payment_type_ref promo_type_ref discount_type_ref category_tree_ref vendor_tier_ref quality_grade_ref"
STD_C_LOG="log_level_ref source_ref component_ref env_ref region_ref service_ref version_ref host_type_ref alert_type_ref metric_type_ref action_type_ref status_ref priority_ref category_ref tag_ref channel_ref format_ref encoding_ref protocol_ref auth_type_ref"

STD_D_FIN="account_contacts account_products customer_segments user_roles entity_relationships product_fees account_flags customer_tags portfolio_assets fund_allocations approval_chains dept_budgets vendor_contracts contract_terms cost_allocations"
STD_D_RET="product_categories product_tags product_images order_discounts order_payments order_shipments customer_addresses customer_preferences store_products store_promotions vendor_products vendor_regions campaign_products promo_conditions bundle_items"
STD_D_LOG="service_dependencies alert_recipients metric_tags host_labels deployment_targets config_overrides health_check_targets service_owners on_call_schedules escalation_paths runbook_links dashboard_panels alert_conditions notification_channels retention_policies"

STD_E_FIN="account_events balance_snapshots txn_audit rate_changes reconciliation_log settlement_events wire_events compliance_events approval_events notification_log payment_events limit_changes valuation_events fee_events position_changes"
STD_E_RET="inventory_snapshots price_changes stock_movements order_events shipment_events return_events review_events promo_events cart_events search_events page_views session_events restock_events markdown_log allocation_events"
STD_E_LOG="metric_events alert_events deployment_events scaling_events failover_events recovery_events incident_events change_events access_events auth_events cert_events dns_events backup_events restore_events rotation_events"

# ================================================================
# DDL generators — return SQL text (no sqlcmd calls)
# ================================================================
ddl_for_type() {
  local t="$1" typ="$2"
  case "$typ" in
    standard)  echo "CREATE TABLE dbo.${t}(id BIGINT IDENTITY(1,1) PRIMARY KEY,ref_id INT DEFAULT ABS(CHECKSUM(NEWID()))%1000000,name NVARCHAR(200) DEFAULT N'x',category NVARCHAR(100) DEFAULT N'c',amount DECIMAL(12,2) DEFAULT 1.00,status NVARCHAR(20) DEFAULT N'active',description NVARCHAR(500) DEFAULT N'd',metadata NVARCHAR(MAX) DEFAULT N'{}',created_at DATETIME2 DEFAULT SYSUTCDATETIME(),updated_at DATETIME2 DEFAULT SYSUTCDATETIME(),padding CHAR(200) DEFAULT REPLICATE('X',200));" ;;
    medium)    echo "CREATE TABLE dbo.${t}(id BIGINT IDENTITY(1,1) PRIMARY KEY,external_id NVARCHAR(50) DEFAULT NEWID(),source_system NVARCHAR(50) DEFAULT N'SYS',entity_type NVARCHAR(30) DEFAULT N'a',entity_id BIGINT DEFAULT 1,parent_id BIGINT NULL,code NVARCHAR(20) DEFAULT N'C',label NVARCHAR(200) DEFAULT N'l',quantity INT DEFAULT 1,unit_price DECIMAL(10,2) DEFAULT 1.00,total_amount DECIMAL(12,2) DEFAULT 1.00,currency NVARCHAR(3) DEFAULT N'USD',tax_rate DECIMAL(5,4) DEFAULT 0.0825,discount_pct DECIMAL(5,2) DEFAULT 0.00,status NVARCHAR(20) DEFAULT N'pending',priority INT DEFAULT 1,created_at DATETIME2 DEFAULT SYSUTCDATETIME(),updated_at DATETIME2 DEFAULT SYSUTCDATETIME());" ;;
    reference) echo "CREATE TABLE dbo.${t}(id INT IDENTITY(1,1) PRIMARY KEY,code NVARCHAR(20) NOT NULL DEFAULT N'R',display_name NVARCHAR(100) NOT NULL DEFAULT N'd',is_active BIT DEFAULT 1,sort_order INT DEFAULT 0);" ;;
    junction)  echo "CREATE TABLE dbo.${t}(id BIGINT IDENTITY(1,1) PRIMARY KEY,left_id BIGINT NOT NULL DEFAULT 1,right_id BIGINT NOT NULL DEFAULT 1,relationship_type NVARCHAR(30) DEFAULT N'default',effective_date DATE DEFAULT CAST(SYSUTCDATETIME() AS DATE),created_at DATETIME2 DEFAULT SYSUTCDATETIME());" ;;
    event)     echo "CREATE TABLE dbo.${t}(id BIGINT IDENTITY(1,1) PRIMARY KEY,event_type NVARCHAR(50) DEFAULT N'e',event_source NVARCHAR(100) DEFAULT N's',correlation_id NVARCHAR(50) DEFAULT NEWID(),payload NVARCHAR(2000) DEFAULT REPLICATE(N'd',100),severity NVARCHAR(10) DEFAULT N'INFO',tags NVARCHAR(500) DEFAULT N't',host NVARCHAR(100) DEFAULT N'h',pid INT DEFAULT 1,event_ts DATETIME2 DEFAULT SYSUTCDATETIME(),ingested_ts DATETIME2 DEFAULT SYSUTCDATETIME(),processed BIT DEFAULT 0);" ;;
    wide)      echo "CREATE TABLE dbo.${t}(id BIGINT IDENTITY(1,1) PRIMARY KEY,s1 NVARCHAR(100) DEFAULT N'v',s2 NVARCHAR(100) DEFAULT N'v',s3 NVARCHAR(100) DEFAULT N'v',s4 NVARCHAR(100) DEFAULT N'v',s5 NVARCHAR(100) DEFAULT N'v',s6 NVARCHAR(100) DEFAULT N'v',s7 NVARCHAR(100) DEFAULT N'v',s8 NVARCHAR(100) DEFAULT N'v',s9 NVARCHAR(100) DEFAULT N'v',s10 NVARCHAR(100) DEFAULT N'v',i1 INT DEFAULT 1,i2 INT DEFAULT 2,i3 INT DEFAULT 3,i4 INT DEFAULT 4,i5 INT DEFAULT 5,i6 INT DEFAULT 6,i7 INT DEFAULT 7,i8 INT DEFAULT 8,i9 INT DEFAULT 9,i10 INT DEFAULT 10,d1 DECIMAL(12,2) DEFAULT 1.1,d2 DECIMAL(12,2) DEFAULT 2.2,d3 DECIMAL(12,2) DEFAULT 3.3,d4 DECIMAL(12,2) DEFAULT 4.4,d5 DECIMAL(12,2) DEFAULT 5.5,d6 DECIMAL(12,2) DEFAULT 6.6,d7 DECIMAL(12,2) DEFAULT 7.7,d8 DECIMAL(12,2) DEFAULT 8.8,d9 DECIMAL(12,2) DEFAULT 9.9,d10 DECIMAL(12,2) DEFAULT 10.0,f1 BIT DEFAULT 0,f2 BIT DEFAULT 0,f3 BIT DEFAULT 0,f4 BIT DEFAULT 0,f5 BIT DEFAULT 0,n1 NVARCHAR(200) DEFAULT N'n',n2 NVARCHAR(200) DEFAULT N'n',n3 NVARCHAR(200) DEFAULT N'n',n4 NVARCHAR(200) DEFAULT N'n',n5 NVARCHAR(200) DEFAULT N'n',dt1 DATETIME2 DEFAULT SYSUTCDATETIME(),dt2 DATETIME2 DEFAULT SYSUTCDATETIME(),dt3 DATETIME2 DEFAULT SYSUTCDATETIME(),dt4 DATETIME2 DEFAULT SYSUTCDATETIME(),dt5 DATETIME2 DEFAULT SYSUTCDATETIME(),dt6 DATETIME2 DEFAULT SYSUTCDATETIME(),dt7 DATETIME2 DEFAULT SYSUTCDATETIME(),dt8 DATETIME2 DEFAULT SYSUTCDATETIME(),dt9 DATETIME2 DEFAULT SYSUTCDATETIME(),dt10 DATETIME2 DEFAULT SYSUTCDATETIME(),created_at DATETIME2 DEFAULT SYSUTCDATETIME());" ;;
    narrow)    echo "CREATE TABLE dbo.${t}(id INT IDENTITY(1,1) PRIMARY KEY,code NVARCHAR(10) NOT NULL DEFAULT N'N',value NVARCHAR(50) NOT NULL DEFAULT N'v');" ;;
    lob)       echo "CREATE TABLE dbo.${t}(id BIGINT IDENTITY(1,1) PRIMARY KEY,doc_title NVARCHAR(200) NOT NULL DEFAULT N't',doc_body NVARCHAR(MAX) DEFAULT N'b',doc_binary VARBINARY(MAX) NULL,doc_size INT DEFAULT 0,mime_type NVARCHAR(100) DEFAULT N'text/plain',created_at DATETIME2 DEFAULT SYSUTCDATETIME(),updated_at DATETIME2 DEFAULT SYSUTCDATETIME());" ;;
    nopk)      echo "CREATE TABLE dbo.${t}(event_ts DATETIME2 DEFAULT SYSUTCDATETIME(),source_id NVARCHAR(50) NOT NULL DEFAULT N's',event_type NVARCHAR(50) NOT NULL DEFAULT N'e',event_data NVARCHAR(2000) DEFAULT N'{}',severity NVARCHAR(10) DEFAULT N'INFO',host NVARCHAR(100) DEFAULT N'h',processed BIT DEFAULT 0);" ;;
    pii)       echo "CREATE TABLE dbo.${t}(id BIGINT IDENTITY(1,1) PRIMARY KEY,first_name NVARCHAR(100) NOT NULL DEFAULT N'F',last_name NVARCHAR(100) NOT NULL DEFAULT N'L',ssn NVARCHAR(11) DEFAULT N'000-00-0000',date_of_birth DATE DEFAULT '1990-01-01',email NVARCHAR(255) DEFAULT N'a@b.com',phone NVARCHAR(20) DEFAULT N'555-000-0000',address_line1 NVARCHAR(200) DEFAULT N'123 St',city NVARCHAR(100) DEFAULT N'Town',state_code NVARCHAR(2) DEFAULT N'TX',zip_code NVARCHAR(10) DEFAULT N'75001',country NVARCHAR(2) DEFAULT N'US',created_at DATETIME2 DEFAULT SYSUTCDATETIME(),updated_at DATETIME2 DEFAULT SYSUTCDATETIME());" ;;
  esac
}

# ================================================================
# double_sql — return INSERT...SELECT SQL for doubling (no sqlcmd)
# ================================================================
double_sql() {
  local t="$1" typ="$2"
  case "$typ" in
    standard)  echo "INSERT INTO dbo.${t}(ref_id,name,category,amount,status,description,metadata,padding) SELECT ref_id,name,category,amount,status,description,metadata,padding FROM dbo.${t};" ;;
    medium)    echo "INSERT INTO dbo.${t}(external_id,source_system,entity_type,entity_id,parent_id,code,label,quantity,unit_price,total_amount,currency,tax_rate,discount_pct,status,priority) SELECT CAST(NEWID() AS NVARCHAR(50)),source_system,entity_type,entity_id,parent_id,code,label,quantity,unit_price,total_amount,currency,tax_rate,discount_pct,status,priority FROM dbo.${t};" ;;
    reference) echo "INSERT INTO dbo.${t}(code,display_name,is_active,sort_order) SELECT LEFT(CONCAT(code,LEFT(CAST(NEWID() AS NVARCHAR(36)),4)),20),display_name,is_active,sort_order FROM dbo.${t};" ;;
    junction)  echo "INSERT INTO dbo.${t}(left_id,right_id,relationship_type,effective_date) SELECT left_id,right_id,relationship_type,effective_date FROM dbo.${t};" ;;
    event)     echo "INSERT INTO dbo.${t}(event_type,event_source,correlation_id,payload,severity,tags,host,pid) SELECT event_type,event_source,CAST(NEWID() AS NVARCHAR(50)),payload,severity,tags,host,pid FROM dbo.${t};" ;;
    wide)      echo "INSERT INTO dbo.${t}(s1,s2,s3,s4,s5,s6,s7,s8,s9,s10,i1,i2,i3,i4,i5,i6,i7,i8,i9,i10) SELECT s1,s2,s3,s4,s5,s6,s7,s8,s9,s10,i1,i2,i3,i4,i5,i6,i7,i8,i9,i10 FROM dbo.${t};" ;;
    narrow)    echo "INSERT INTO dbo.${t}(code,value) SELECT LEFT(CONCAT(code,LEFT(CAST(NEWID() AS NVARCHAR(36)),3)),10),value FROM dbo.${t};" ;;
    lob)       echo "INSERT INTO dbo.${t}(doc_title,doc_body,doc_size,mime_type) SELECT doc_title,doc_body,doc_size,mime_type FROM dbo.${t};" ;;
    nopk)      echo "INSERT INTO dbo.${t}(source_id,event_type,event_data,severity,host) SELECT source_id,event_type,event_data,severity,host FROM dbo.${t};" ;;
    pii)       echo "INSERT INTO dbo.${t}(first_name,last_name,ssn,date_of_birth,email,phone,address_line1,city,state_code,zip_code,country) SELECT first_name,last_name,ssn,date_of_birth,CONCAT('d-',email),phone,address_line1,city,state_code,zip_code,country FROM dbo.${t};" ;;
  esac
}

# ================================================================
# get_db_lists — set DBSP, A, B, C, D, E for a given DB name
# ================================================================
get_db_lists() {
  case "$1" in
    financedb) DBSP="$SPECIALS_FIN"; A="$STD_A_FIN"; B="$STD_B_FIN"; C="$STD_C_FIN"; D="$STD_D_FIN"; E="$STD_E_FIN" ;;
    retaildb)  DBSP="$SPECIALS_RET"; A="$STD_A_RET"; B="$STD_B_RET"; C="$STD_C_RET"; D="$STD_D_RET"; E="$STD_E_RET" ;;
    logsdb)    DBSP="$SPECIALS_LOG"; A="$STD_A_LOG"; B="$STD_B_LOG"; C="$STD_C_LOG"; D="$STD_D_LOG"; E="$STD_E_LOG" ;;
  esac
}

# ================================================================
# generate_db_script — build a single .sql file for one DB
# that creates all 100 tables, enables CDC, and seeds base rows
# ================================================================
generate_db_script() {
  local db="$1" outfile="$2"
  get_db_lists "$db"

  echo "SET NOCOUNT ON;" > "$outfile"

  # Collect all table:type pairs
  local pairs=""
  for entry in $DBSP; do
    pairs="$pairs ${entry%%:*}:${entry##*:}"
  done
  for t in $A; do pairs="$pairs ${t}:standard"; done
  for t in $B; do pairs="$pairs ${t}:medium"; done
  for t in $C; do pairs="$pairs ${t}:reference"; done
  for t in $D; do pairs="$pairs ${t}:junction"; done
  for t in $E; do pairs="$pairs ${t}:event"; done

  for pair in $pairs; do
    local t="${pair%%:*}" typ="${pair##*:}"

    # GO separates batches — sqlcmd continues on error within a batch,
    # so CREATE TABLE failing (already exists) won't stop the script.

    # Create table (harmless error if exists)
    ddl_for_type "$t" "$typ" >> "$outfile"
    echo "GO" >> "$outfile"

    # Enable CDC (wrapped in TRY/CATCH in case already enabled)
    if [ "$typ" = "nopk" ]; then
      echo "BEGIN TRY EXEC sys.sp_cdc_enable_table @source_schema=N'dbo',@source_name=N'${t}',@role_name=NULL,@supports_net_changes=0; END TRY BEGIN CATCH END CATCH" >> "$outfile"
    else
      echo "BEGIN TRY EXEC sys.sp_cdc_enable_table @source_schema=N'dbo',@source_name=N'${t}',@role_name=NULL,@supports_net_changes=1; END TRY BEGIN CATCH END CATCH" >> "$outfile"
    fi
    echo "GO" >> "$outfile"

    # Seed 500 rows if table is empty/short (each GO batch gets its own scope)
    cat >> "$outfile" <<EOF
IF (SELECT COUNT(*) FROM dbo.${t}) < 500
BEGIN
  DECLARE @n INT = 500 - (SELECT COUNT(*) FROM dbo.${t});
  WHILE @n > 0 BEGIN INSERT INTO dbo.${t} DEFAULT VALUES; SET @n = @n - 1; END
END
GO
EOF
  done
}

# ================================================================
# grow_table — double until target, with safety break
# ================================================================
grow_table() {
  local db="$1" t="$2" typ="$3" target="$4"
  local rows before attempts=0 retries=0 max_retries=5
  rows=$(dval "$db" "SELECT COUNT(*) FROM dbo.${t}")
  [ "$rows" -ge "$target" ] && return 0
  while [ "$rows" -lt "$target" ] && [ "$attempts" -lt "$MAX_DOUBLES" ]; do
    before=$rows
    if ! dql "$db" "$(double_sql "$t" "$typ")"; then
      retries=$((retries + 1))
      if [ "$retries" -ge "$max_retries" ]; then
        echo "${db}.${t}:ERR:double failed after ${max_retries} retries (at ${rows} rows)" >> "$FAIL_LOG"
        return 1
      fi
      sleep $((retries * 2))
      continue
    fi
    rows=$(dval "$db" "SELECT COUNT(*) FROM dbo.${t}")
    attempts=$((attempts + 1))
    retries=0
    if [ "$rows" -le "$before" ]; then
      # Retry once more with a fresh connection before giving up
      sleep 2
      dql "$db" "$(double_sql "$t" "$typ")"
      rows=$(dval "$db" "SELECT COUNT(*) FROM dbo.${t}")
      if [ "$rows" -le "$before" ]; then
        echo "${db}.${t}:STALL:stuck at ${rows} rows" >> "$FAIL_LOG"
        return 1
      fi
    fi
  done
  return 0
}

# ================================================================
# CLEAN
# ================================================================
if [ "$CLEAN" = true ]; then
  printf "\n%b   +=== CLEAN ===%b\n" "$Y" "$NC"

  for db in $DBS; do
    sql "USE master; EXEC msdb.dbo.rds_cdc_disable_db '${db}'" &>/dev/null || true
    sql "IF DB_ID('${db}') IS NOT NULL DROP DATABASE [${db}]" &>/dev/null || true
    printf "    %bOK%b dropped SQL Server %s\n" "$G" "$NC" "$db"
  done

  if [ -n "$PH" ] && [ -n "$PU" ]; then
    printf "    Cleaning Aurora ...\n"
    TABLES=$(pgv "SELECT tablename FROM pg_tables WHERE schemaname='public';" | tr '\n' ' ')
    for tbl in $TABLES; do
      tbl=$(echo "$tbl" | tr -d '[:space:]')
      [ -z "$tbl" ] && continue
      pg "DROP TABLE IF EXISTS public.\"${tbl}\" CASCADE;" 2>/dev/null
    done
    pg "ANALYZE;" 2>/dev/null
    printf "    %bOK%b Aurora tables dropped\n" "$G" "$NC"
  else
    printf "    %bSKIP%b Aurora (no endpoint)\n" "$Y" "$NC"
  fi
fi

printf "\n%b   +=== Seed: %s across 300 tables ===%b\n" "$C" "$TARGET_LABEL" "$NC"
printf "  Target rows/table: %s\n\n" "$PTR"

# ================================================================
# Phase 1: Create DBs (parallel)
# ================================================================
printf "  [1/3] Databases ...\n"
for db in $DBS; do
  EXISTS=$(dval master "SELECT CASE WHEN DB_ID('${db}') IS NOT NULL THEN 1 ELSE 0 END")
  if [ "$EXISTS" = "1" ]; then
    printf "    %bOK%b %s exists\n" "$G" "$NC" "$db"
  else
    sql "CREATE DATABASE [${db}]"
    sql "USE master; EXEC msdb.dbo.rds_cdc_enable_db '${db}'"
    printf "    %bOK%b %s created\n" "$G" "$NC" "$db"
  fi
done

# ================================================================
# Phase 2: Create tables + CDC + seed base rows (batched per DB, parallel across DBs)
# Generates one .sql script per DB and runs all 3 concurrently.
# ================================================================
printf "\n  [2/3] Tables + CDC + base rows (3 DBs in parallel) ...\n"

TMPDIR_SEED=$(mktemp -d)
trap "rm -rf $TMPDIR_SEED" EXIT

# Generate SQL scripts (fast, local-only)
for db in $DBS; do
  generate_db_script "$db" "${TMPDIR_SEED}/${db}.sql"
done

# Run all 3 in parallel
PHASE2_PIDS=""
for db in $DBS; do
  (
    dfile "$db" "${TMPDIR_SEED}/${db}.sql" 2>/dev/null
    TCOUNT=$(dval "$db" "SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped=0")
    printf "    %bOK%b %s: %s tables created + seeded\n" "$G" "$NC" "$db" "$TCOUNT"
  ) &
  PHASE2_PIDS="$PHASE2_PIDS $!"
done
PHASE2_FAIL=0
for pid in $PHASE2_PIDS; do
  wait "$pid" || PHASE2_FAIL=$((PHASE2_FAIL + 1))
done
if [ "$PHASE2_FAIL" -gt 0 ]; then
  printf "    %bWARN%b %s DBs had errors in table creation\n" "$Y" "$NC" "$PHASE2_FAIL"
fi

# ================================================================
# Phase 3: Double to target (parallel workers across all DBs)
# Validate Phase 2 results
for db in $DBS; do
  TCOUNT=$(dval "$db" "SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped=0")
  EMPTY=$(dval "$db" "SELECT COUNT(*) FROM sys.tables t JOIN sys.partitions p ON t.object_id=p.object_id WHERE p.index_id IN (0,1) AND t.is_ms_shipped=0 AND p.rows=0")
  if [ "$EMPTY" -gt 0 ]; then
    printf "    %bWARN%b %s: %s tables, %s empty — reseeding ...\n" "$Y" "$NC" "$db" "$TCOUNT" "$EMPTY"
    # Reseed empty tables individually
    for t in $(dval "$db" "SELECT STRING_AGG(t.name,',') FROM sys.tables t JOIN sys.partitions p ON t.object_id=p.object_id WHERE p.index_id IN (0,1) AND t.is_ms_shipped=0 AND p.rows=0" | tr ',' ' '); do
      dql "$db" "DECLARE @n INT=500; WHILE @n>0 BEGIN INSERT INTO dbo.${t} DEFAULT VALUES; SET @n=@n-1; END"
    done
  else
    printf "    %bOK%b %s: %s tables, all seeded\n" "$G" "$NC" "$db" "$TCOUNT"
  fi
done

# ================================================================
printf "\n  [3/3] Doubling to target (parallel=%s) ...\n\n" "$PARALLEL_JOBS"

# Export functions and variables for subshells
export -f grow_table double_sql dql dval dfile sql
export SC SU SW MAX_DOUBLES SQLCMD

FAIL_COUNT=0
WORK_FILE=$(mktemp)
FAIL_LOG=$(mktemp)
export FAIL_LOG
trap "rm -rf $TMPDIR_SEED $WORK_FILE $FAIL_LOG" EXIT

# Build work list for ALL databases at once (enables better parallelism)
for db in $DBS; do
  get_db_lists "$db"
  for entry in $DBSP; do
    t="${entry%%:*}"; typ="${entry##*:}"
    TGT=$(target_rows_for_type "$typ")
    echo "${db}:${t}:${typ}:${TGT}" >> "$WORK_FILE"
  done
  for t in $A; do echo "${db}:${t}:standard:$(target_rows_for_type standard)" >> "$WORK_FILE"; done
  for t in $B; do echo "${db}:${t}:medium:$(target_rows_for_type medium)" >> "$WORK_FILE"; done
  for t in $C; do echo "${db}:${t}:reference:$(target_rows_for_type reference)" >> "$WORK_FILE"; done
  for t in $D; do echo "${db}:${t}:junction:$(target_rows_for_type junction)" >> "$WORK_FILE"; done
  for t in $E; do echo "${db}:${t}:event:$(target_rows_for_type event)" >> "$WORK_FILE"; done
done

TOTAL_WORK=$(wc -l < "$WORK_FILE" | tr -d '[:space:]')
DONE=0
DB_FAILS=0
GROW_START=$(date +%s)

printf "  Growing %s tables across all DBs ...\n" "$TOTAL_WORK"

# Process all 300 tables in parallel batches (spread across all 3 DBs)
while IFS= read -r line; do
  d="${line%%:*}"; rest="${line#*:}"
  t="${rest%%:*}"; rest="${rest#*:}"
  typ="${rest%%:*}"; tgt="${rest##*:}"
  (
    grow_table "$d" "$t" "$typ" "$tgt"
  ) </dev/null &
  DONE=$((DONE + 1))
  if [ $((DONE % PARALLEL_JOBS)) -eq 0 ]; then
    for pid in $(jobs -p); do
      wait "$pid" || DB_FAILS=$((DB_FAILS + 1))
    done
    ELAPSED=$(( $(date +%s) - GROW_START ))
    printf "    %s/%s tables (%ds)\n" "$DONE" "$TOTAL_WORK" "$ELAPSED"
  fi
done < "$WORK_FILE"
# Wait for remaining jobs
for pid in $(jobs -p); do
  wait "$pid" || DB_FAILS=$((DB_FAILS + 1))
done

GROW_END=$(date +%s)
printf "    %s/%s tables (%ds)\n" "$TOTAL_WORK" "$TOTAL_WORK" "$((GROW_END - GROW_START))"

rm -f "$WORK_FILE"

if [ -s "$FAIL_LOG" ]; then
  FCOUNT=$(wc -l < "$FAIL_LOG" | tr -d '[:space:]')
  printf "\n  %bWARN%b %s tables had issues:\n" "$Y" "$NC" "$FCOUNT"
  while IFS= read -r line; do
    printf "    %s\n" "$line"
  done < "$FAIL_LOG"
  printf "  Re-run without --clean to retry.\n"
fi

# ================================================================
# Summary
# ================================================================
printf "\n  Row counts:\n"
for db in $DBS; do
  ROWS=$(dval "$db" "SELECT SUM(p.rows) FROM sys.tables t JOIN sys.partitions p ON t.object_id=p.object_id WHERE p.index_id IN (0,1) AND t.is_ms_shipped=0")
  printf "    %s: %s rows\n" "$db" "$ROWS"
done

printf "\n  DB sizes:\n"
sql "SELECT d.name, SUM(mf.size)*8.0/1024/1024 AS size_gb FROM sys.databases d JOIN sys.master_files mf ON d.database_id = mf.database_id WHERE d.name IN ('financedb','retaildb','logsdb') GROUP BY d.name ORDER BY size_gb DESC"

printf "\n  Next:\n"
printf "    ./cdc.sh connect cdc        # start Connect\n"
printf "    ./cdc.sh infra status       # verify connectors\n\n"
