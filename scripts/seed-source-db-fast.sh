
#!/usr/bin/env bash
set -euo pipefail

# ================================================================
# seed-source-db-fast.sh  (fast — bcp bulk import, ~1TB/hr)
# Seeds 3 databases × 100 tables each (300 total) in SQL Server.
# Requires bcp (/opt/mssql-tools18/bin/bcp) and Python 3.
# For smaller instances without large storage, use seed-source-db.sh.
# Usage:
#   ./seed-source-db-fast.sh [--clean] <SIZE>
#   SIZE     100MB, 1GB, 10GB, 1000GB (MB or GB suffix required)
#   --clean  Drop all 3 SQL Server DBs + all Aurora tables first
# ================================================================

usage() {
  cat <<'EOF'
Usage: ./seed-source-db-fast.sh [--clean] <SIZE>

  SIZE      Target data volume across 300 tables (3 DBs x 100 tables)
            Must include MB or GB suffix (e.g. 100MB, 1GB, 1000GB)

  --clean   Drop all 3 SQL Server DBs + all Aurora tables before seeding

Examples:
  ./seed-source-db-fast.sh 100MB              # quick test (~1 min)
  ./seed-source-db-fast.sh --clean 1GB        # clean + seed 1 GB
  ./seed-source-db-fast.sh 100GB              # seed 100 GB (~6 min)
  ./seed-source-db-fast.sh --clean 1000GB     # full 1 TB seed (~1 hr)

  NOTE: MB or GB suffix is required (bare numbers are not accepted).

Requires:
  bcp       /opt/mssql-tools18/bin/bcp (ODBC bulk copy)
  python3   For inline TSV data generation

Environment:
  PARALLEL_JOBS=N   parallel bcp workers (default: 32)
EOF
  exit 0
}

[ $# -eq 0 ] && usage
[[ "${1:-}" =~ ^(-h|--help|help)$ ]] && usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

if [ ! -f terraform.tfvars ]; then echo "ERROR: Run from cdc-on-cpc/"; exit 1; fi

# Use ODBC sqlcmd and bcp, not the Go-based ones
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"
BCP="/opt/mssql-tools18/bin/bcp"
if [ ! -x "$SQLCMD" ]; then
  echo "ERROR: ODBC sqlcmd not found at $SQLCMD"
  echo "       Install: sudo ACCEPT_EULA=Y dnf install -y mssql-tools18"
  exit 1
fi
if [ ! -x "$BCP" ]; then
  echo "ERROR: bcp not found at $BCP"
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

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; NC='\033[0m'

sql()  { $SQLCMD -C -S "${SC}" -U "${SU}" -P "${SW}" -Q "$1" -W &>/dev/null; }
dql()  { $SQLCMD -C -S "${SC}" -U "${SU}" -P "${SW}" -Q "USE [$1]; SET NOCOUNT ON; $2" -W &>/dev/null; }
dval() { $SQLCMD -C -S "${SC}" -U "${SU}" -P "${SW}" -h -1 -Q "USE [$1]; SET NOCOUNT ON; $2" -W 2>/dev/null | grep -v '^Changed database' | tr -d ' \r\n' | grep -oE '^[0-9]+' || echo "0"; }
dfile(){ $SQLCMD -C -S "${SC}" -U "${SU}" -P "${SW}" -Q "USE [$1]" -W &>/dev/null && $SQLCMD -C -S "${SC}" -U "${SU}" -P "${SW}" -Q "USE [$1]; $(cat "$2")" -W &>/dev/null; }
pgv()  { PGPASSWORD="${PW}" psql -h "${PH}" -p "${PP}" -U "${PU}" -d "${PD}" -t -A -c "$1" 2>/dev/null || echo "0"; }
pg()   { PGPASSWORD="${PW}" psql -h "${PH}" -p "${PP}" -U "${PU}" -d "${PD}" -c "$1" &>/dev/null; }

CLEAN=false
[ "${1:-}" = "--clean" ] && { CLEAN=true; shift; }
if [ -z "${1:-}" ]; then echo "ERROR: SIZE required. Run with --help for usage."; exit 1; fi
SIZE_ARG="$1"

# Parse size: MB or GB suffix required
parse_size_bytes() {
  local input="${1^^}"
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

if [ "$TARGET_BYTES" -ge 1073741824 ]; then
  TARGET_LABEL="$((TARGET_BYTES / 1073741824)) GB"
else
  TARGET_LABEL="$((TARGET_BYTES / 1048576)) MB"
fi

DBS="financedb retaildb logsdb"
TABLES_TOTAL=300
PARALLEL_JOBS="${PARALLEL_JOBS:-32}"
BCP_BATCH=100000
CHUNK_ROWS=500000

# Weighted average bytes/row across all table types: ~614
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
  local bpr
  bpr=$(bytes_per_type "$1")
  echo $((TARGET_BYTES / TABLES_TOTAL / bpr))
}

# ================================================================
# Table lists per DB (5 special + 25 A + 20 B + 20 C + 15 D + 15 E = 100)
# ================================================================
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
# DDL generators — CREATE TABLE (no CDC, no base rows)
# ================================================================
ddl_for_type() {
  local t="$1" typ="$2"
  case "$typ" in
    standard)  echo "CREATE TABLE dbo.${t}(id BIGINT IDENTITY(1,1) PRIMARY KEY,ref_id INT NOT NULL,name NVARCHAR(200) NOT NULL,category NVARCHAR(100) NOT NULL,amount DECIMAL(12,2) NOT NULL,status NVARCHAR(20) NOT NULL,description NVARCHAR(500) NOT NULL,metadata NVARCHAR(MAX) NOT NULL,created_at DATETIME2 NOT NULL,updated_at DATETIME2 NOT NULL,padding CHAR(200) NOT NULL);" ;;
    medium)    echo "CREATE TABLE dbo.${t}(id BIGINT IDENTITY(1,1) PRIMARY KEY,external_id NVARCHAR(50) NOT NULL,source_system NVARCHAR(50) NOT NULL,entity_type NVARCHAR(30) NOT NULL,entity_id BIGINT NOT NULL,parent_id BIGINT NULL,code NVARCHAR(20) NOT NULL,label NVARCHAR(200) NOT NULL,quantity INT NOT NULL,unit_price DECIMAL(10,2) NOT NULL,total_amount DECIMAL(12,2) NOT NULL,currency NVARCHAR(3) NOT NULL,tax_rate DECIMAL(5,4) NOT NULL,discount_pct DECIMAL(5,2) NOT NULL,status NVARCHAR(20) NOT NULL,priority INT NOT NULL,created_at DATETIME2 NOT NULL,updated_at DATETIME2 NOT NULL);" ;;
    reference) echo "CREATE TABLE dbo.${t}(id INT IDENTITY(1,1) PRIMARY KEY,code NVARCHAR(20) NOT NULL,display_name NVARCHAR(100) NOT NULL,is_active BIT NOT NULL,sort_order INT NOT NULL);" ;;
    junction)  echo "CREATE TABLE dbo.${t}(id BIGINT IDENTITY(1,1) PRIMARY KEY,left_id BIGINT NOT NULL,right_id BIGINT NOT NULL,relationship_type NVARCHAR(30) NOT NULL,effective_date DATE NOT NULL,created_at DATETIME2 NOT NULL);" ;;
    event)     echo "CREATE TABLE dbo.${t}(id BIGINT IDENTITY(1,1) PRIMARY KEY,event_type NVARCHAR(50) NOT NULL,event_source NVARCHAR(100) NOT NULL,correlation_id NVARCHAR(50) NOT NULL,payload NVARCHAR(2000) NOT NULL,severity NVARCHAR(10) NOT NULL,tags NVARCHAR(500) NOT NULL,host NVARCHAR(100) NOT NULL,pid INT NOT NULL,event_ts DATETIME2 NOT NULL,ingested_ts DATETIME2 NOT NULL,processed BIT NOT NULL);" ;;
    wide)      echo "CREATE TABLE dbo.${t}(id BIGINT IDENTITY(1,1) PRIMARY KEY,s1 NVARCHAR(100) NOT NULL,s2 NVARCHAR(100) NOT NULL,s3 NVARCHAR(100) NOT NULL,s4 NVARCHAR(100) NOT NULL,s5 NVARCHAR(100) NOT NULL,s6 NVARCHAR(100) NOT NULL,s7 NVARCHAR(100) NOT NULL,s8 NVARCHAR(100) NOT NULL,s9 NVARCHAR(100) NOT NULL,s10 NVARCHAR(100) NOT NULL,i1 INT NOT NULL,i2 INT NOT NULL,i3 INT NOT NULL,i4 INT NOT NULL,i5 INT NOT NULL,i6 INT NOT NULL,i7 INT NOT NULL,i8 INT NOT NULL,i9 INT NOT NULL,i10 INT NOT NULL,d1 DECIMAL(12,2) NOT NULL,d2 DECIMAL(12,2) NOT NULL,d3 DECIMAL(12,2) NOT NULL,d4 DECIMAL(12,2) NOT NULL,d5 DECIMAL(12,2) NOT NULL,d6 DECIMAL(12,2) NOT NULL,d7 DECIMAL(12,2) NOT NULL,d8 DECIMAL(12,2) NOT NULL,d9 DECIMAL(12,2) NOT NULL,d10 DECIMAL(12,2) NOT NULL,f1 BIT NOT NULL,f2 BIT NOT NULL,f3 BIT NOT NULL,f4 BIT NOT NULL,f5 BIT NOT NULL,n1 NVARCHAR(200) NOT NULL,n2 NVARCHAR(200) NOT NULL,n3 NVARCHAR(200) NOT NULL,n4 NVARCHAR(200) NOT NULL,n5 NVARCHAR(200) NOT NULL,dt1 DATETIME2 NOT NULL,dt2 DATETIME2 NOT NULL,dt3 DATETIME2 NOT NULL,dt4 DATETIME2 NOT NULL,dt5 DATETIME2 NOT NULL,dt6 DATETIME2 NOT NULL,dt7 DATETIME2 NOT NULL,dt8 DATETIME2 NOT NULL,dt9 DATETIME2 NOT NULL,dt10 DATETIME2 NOT NULL,created_at DATETIME2 NOT NULL);" ;;
    narrow)    echo "CREATE TABLE dbo.${t}(id INT IDENTITY(1,1) PRIMARY KEY,code NVARCHAR(10) NOT NULL,value NVARCHAR(50) NOT NULL);" ;;
    lob)       echo "CREATE TABLE dbo.${t}(id BIGINT IDENTITY(1,1) PRIMARY KEY,doc_title NVARCHAR(200) NOT NULL,doc_body NVARCHAR(MAX) NOT NULL,doc_binary VARBINARY(MAX) NULL,doc_size INT NOT NULL,mime_type NVARCHAR(100) NOT NULL,created_at DATETIME2 NOT NULL,updated_at DATETIME2 NOT NULL);" ;;
    nopk)      echo "CREATE TABLE dbo.${t}(event_ts DATETIME2 NOT NULL,source_id NVARCHAR(50) NOT NULL,event_type NVARCHAR(50) NOT NULL,event_data NVARCHAR(2000) NOT NULL,severity NVARCHAR(10) NOT NULL,host NVARCHAR(100) NOT NULL,processed BIT NOT NULL);" ;;
    pii)       echo "CREATE TABLE dbo.${t}(id BIGINT IDENTITY(1,1) PRIMARY KEY,first_name NVARCHAR(100) NOT NULL,last_name NVARCHAR(100) NOT NULL,ssn NVARCHAR(11) NOT NULL,date_of_birth DATE NOT NULL,email NVARCHAR(255) NOT NULL,phone NVARCHAR(20) NOT NULL,address_line1 NVARCHAR(200) NOT NULL,city NVARCHAR(100) NOT NULL,state_code NVARCHAR(2) NOT NULL,zip_code NVARCHAR(10) NOT NULL,country NVARCHAR(2) NOT NULL,created_at DATETIME2 NOT NULL,updated_at DATETIME2 NOT NULL);" ;;
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
# generate_ddl_script — CREATE TABLE only (no CDC, no base rows)
# ================================================================
generate_ddl_script() {
  local db="$1" outfile="$2"
  get_db_lists "$db"
  echo "SET NOCOUNT ON;" > "$outfile"
  local pairs=""
  for entry in $DBSP; do pairs="$pairs ${entry%%:*}:${entry##*:}"; done
  for t in $A; do pairs="$pairs ${t}:standard"; done
  for t in $B; do pairs="$pairs ${t}:medium"; done
  for t in $C; do pairs="$pairs ${t}:reference"; done
  for t in $D; do pairs="$pairs ${t}:junction"; done
  for t in $E; do pairs="$pairs ${t}:event"; done
  for pair in $pairs; do
    local t="${pair%%:*}" typ="${pair##*:}"
    ddl_for_type "$t" "$typ" >> "$outfile"
    echo "GO" >> "$outfile"
  done
}

# ================================================================
# generate_cdc_script — enable CDC on all tables
# ================================================================
generate_cdc_script() {
  local db="$1" outfile="$2"
  get_db_lists "$db"
  echo "SET NOCOUNT ON;" > "$outfile"
  local pairs=""
  for entry in $DBSP; do pairs="$pairs ${entry%%:*}:${entry##*:}"; done
  for t in $A; do pairs="$pairs ${t}:standard"; done
  for t in $B; do pairs="$pairs ${t}:medium"; done
  for t in $C; do pairs="$pairs ${t}:reference"; done
  for t in $D; do pairs="$pairs ${t}:junction"; done
  for t in $E; do pairs="$pairs ${t}:event"; done
  for pair in $pairs; do
    local t="${pair%%:*}" typ="${pair##*:}"
    if [ "$typ" = "nopk" ]; then
      echo "BEGIN TRY EXEC sys.sp_cdc_enable_table @source_schema=N'dbo',@source_name=N'${t}',@role_name=NULL,@supports_net_changes=0; END TRY BEGIN CATCH END CATCH" >> "$outfile"
    else
      echo "BEGIN TRY EXEC sys.sp_cdc_enable_table @source_schema=N'dbo',@source_name=N'${t}',@role_name=NULL,@supports_net_changes=1; END TRY BEGIN CATCH END CATCH" >> "$outfile"
    fi
    echo "GO" >> "$outfile"
  done
}

# ================================================================
# Python data generator — writes CSV to stdout for bcp
# Generates CHUNK_ROWS rows per call, bcp reads via file.
# IDENTITY columns are skipped (bcp -E is NOT used).
# ================================================================
generate_csv() {
  local typ="$1" num_rows="$2" outfile="$3"
  python3 - "$typ" "$num_rows" "$outfile" <<'PYEOF'
import sys, random, string, uuid, os
from datetime import datetime, timedelta

typ = sys.argv[1]
num_rows = int(sys.argv[2])
outfile = sys.argv[3]

rng = random.Random(42)
SEP = '\t'
now_str = '2025-06-15 12:00:00.0000000'
date_str = '1990-01-01'
pad200 = 'X' * 200

def rstr(n):
    return ''.join(rng.choices(string.ascii_lowercase, k=n))

def rint(lo, hi):
    return rng.randint(lo, hi)

def ruuid():
    return str(uuid.UUID(int=rng.getrandbits(128)))

def rdec(lo, hi, prec=2):
    return f"{rng.uniform(lo, hi):.{prec}f}"

with open(outfile, 'w', buffering=1048576) as f:
    for i in range(num_rows):
        rid = str(i + 1)  # identity column value
        if typ == 'standard':
            f.write(SEP.join([
                rid, str(rint(1,999999)), rstr(20), rstr(10), rdec(1,10000),
                'active', rstr(50), '{}', now_str, now_str, pad200
            ]) + '\n')
        elif typ == 'medium':
            f.write(SEP.join([
                rid, ruuid(), 'SYS', rstr(5), str(rint(1,100000)), str(rint(1,100000)),
                rstr(5), rstr(20), str(rint(1,1000)), rdec(1,500), rdec(1,50000),
                'USD', '0.0825', '0.00', 'pending', str(rint(1,5)), now_str, now_str
            ]) + '\n')
        elif typ == 'reference':
            f.write(SEP.join([
                rid, rstr(8), rstr(20), '1', str(rint(1,100))
            ]) + '\n')
        elif typ == 'junction':
            f.write(SEP.join([
                rid, str(rint(1,100000)), str(rint(1,100000)), 'default', date_str, now_str
            ]) + '\n')
        elif typ == 'event':
            f.write(SEP.join([
                rid, rstr(10), rstr(15), ruuid(), rstr(100), 'INFO',
                rstr(20), rstr(10), str(rint(1,65535)), now_str, now_str, '0'
            ]) + '\n')
        elif typ == 'wide':
            cols = [rid] + [rstr(20)] * 10
            cols += [str(rint(1,10000))] * 10
            cols += [rdec(1,1000)] * 10
            cols += ['0'] * 5
            cols += [rstr(40)] * 5
            cols += [now_str] * 11
            f.write(SEP.join(cols) + '\n')
        elif typ == 'narrow':
            f.write(SEP.join([rid, rstr(8), rstr(20)]) + '\n')
        elif typ == 'lob':
            f.write(SEP.join([
                rid, rstr(30), rstr(500), '', str(rint(100,50000)),
                'text/plain', now_str, now_str
            ]) + '\n')
        elif typ == 'nopk':
            f.write(SEP.join([
                now_str, rstr(10), rstr(10), rstr(100), 'INFO', rstr(10), '0'
            ]) + '\n')
        elif typ == 'pii':
            f.write(SEP.join([
                rid, rstr(8), rstr(10), f'{rint(100,999)}-{rint(10,99)}-{rint(1000,9999)}',
                date_str, f'{rstr(6)}@test.com', f'555-{rint(100,999)}-{rint(1000,9999)}',
                f'{rint(1,9999)} {rstr(8)} St', rstr(8), 'TX', str(rint(10000,99999)), 'US',
                now_str, now_str
            ]) + '\n')
PYEOF
}

# ================================================================
# bcp_load_table — generate CSV and bcp it in, chunked
# ================================================================
bcp_load_table() {
  local db="$1" table="$2" typ="$3" target="$4" tmpdir="$5"
  local datafile="${tmpdir}/${db}_${table}.tsv"
  local loaded=0 chunk

  # Check current row count (for resume)
  local current
  current=$(dval "$db" "SELECT COUNT(*) FROM dbo.${table}")
  [ "$current" -ge "$target" ] && return 0
  local remaining=$((target - current))

  while [ "$remaining" -gt 0 ]; do
    chunk=$remaining
    [ "$chunk" -gt "$CHUNK_ROWS" ] && chunk=$CHUNK_ROWS

    # Generate data
    generate_csv "$typ" "$chunk" "$datafile"

    # bcp in with TABLOCK for faster loading (-E keeps identity values, skip for nopk)
    local bcp_flags=(-S "$SC" -U "$SU" -P "$SW" -c -t '\t' -C 65001 -u -b "$BCP_BATCH" -h "TABLOCK")
    [ "$typ" != "nopk" ] && bcp_flags+=(-E)
    $BCP "${db}.dbo.${table}" in "$datafile" "${bcp_flags[@]}" &>/dev/null

    rm -f "$datafile"
    loaded=$((loaded + chunk))
    remaining=$((remaining - chunk))
  done
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
    for s in financedb retaildb logsdb; do
      PGPASSWORD="$PW" psql -h "$PH" -p "$PP" -U "$PU" -d "$PD" -c "DROP SCHEMA IF EXISTS \"${s}\" CASCADE;" &>/dev/null || true
    done
    PGPASSWORD="$PW" psql -h "$PH" -p "$PP" -U "$PU" -d "$PD" -c "ANALYZE;" &>/dev/null || true
    printf "    %bOK%b Aurora schemas dropped\n" "$G" "$NC"
  else
    printf "    %bSKIP%b Aurora (no endpoint)\n" "$Y" "$NC"
  fi
fi

SEED_START=$(date +%s)
printf "\n%b   +=== Seed: %s across 300 tables (bcp bulk) ===%b\n" "$C" "$TARGET_LABEL" "$NC"
printf "  Target rows/table: ~%s (avg)\n" "$PTR"
printf "  Parallel jobs: %s\n" "$PARALLEL_JOBS"
printf "  Batch size: %s\n\n" "$BCP_BATCH"

# ================================================================
# Phase 1: Create DBs
# ================================================================
printf "  [1/4] Databases ...\n"
for db in $DBS; do
  EXISTS=$(dval master "SELECT CASE WHEN DB_ID('${db}') IS NOT NULL THEN 1 ELSE 0 END")
  if [ "$EXISTS" = "1" ]; then
    printf "    %bOK%b %s exists\n" "$G" "$NC" "$db"
  else
    sql "CREATE DATABASE [${db}]"
    printf "    %bOK%b %s created\n" "$G" "$NC" "$db"
  fi
done

# ================================================================
# Phase 2: Create tables (no CDC — added after loading)
# ================================================================
printf "\n  [2/4] Creating tables (3 DBs in parallel) ...\n"

TMPDIR_SEED=$(mktemp -d)
trap "rm -rf $TMPDIR_SEED" EXIT

for db in $DBS; do
  generate_ddl_script "$db" "${TMPDIR_SEED}/${db}_ddl.sql"
done

PHASE2_PIDS=""
for db in $DBS; do
  (
    dfile "$db" "${TMPDIR_SEED}/${db}_ddl.sql" 2>/dev/null
    TCOUNT=$(dval "$db" "SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped=0")
    printf "    %bOK%b %s: %s tables\n" "$G" "$NC" "$db" "$TCOUNT"
  ) &
  PHASE2_PIDS="$PHASE2_PIDS $!"
done
for pid in $PHASE2_PIDS; do wait "$pid" || true; done

# ================================================================
# Phase 3: bcp bulk load (parallel across all 300 tables)
# ================================================================
printf "\n  [3/4] Loading data via bcp (parallel=%s) ...\n\n" "$PARALLEL_JOBS"

# Export functions and variables for subshells
export -f bcp_load_table generate_csv dval dql
export SC SU SW SQLCMD BCP BCP_BATCH CHUNK_ROWS

FAIL_LOG=$(mktemp)
export FAIL_LOG
trap "rm -rf $TMPDIR_SEED $FAIL_LOG" EXIT

# Build work list
WORK_FILE=$(mktemp)
for db in $DBS; do
  get_db_lists "$db"
  for entry in $DBSP; do
    t="${entry%%:*}"; typ="${entry##*:}"
    echo "${db}:${t}:${typ}:$(target_rows_for_type "$typ")"
  done
  for t in $A; do echo "${db}:${t}:standard:$(target_rows_for_type standard)"; done
  for t in $B; do echo "${db}:${t}:medium:$(target_rows_for_type medium)"; done
  for t in $C; do echo "${db}:${t}:reference:$(target_rows_for_type reference)"; done
  for t in $D; do echo "${db}:${t}:junction:$(target_rows_for_type junction)"; done
  for t in $E; do echo "${db}:${t}:event:$(target_rows_for_type event)"; done
done >> "$WORK_FILE"

TOTAL_WORK=$(wc -l < "$WORK_FILE" | tr -d '[:space:]')
DONE=0
DB_FAILS=0
BCP_START=$(date +%s)

printf "  Loading %s tables ...\n" "$TOTAL_WORK"

while IFS= read -r line; do
  d="${line%%:*}"; rest="${line#*:}"
  t="${rest%%:*}"; rest="${rest#*:}"
  typ="${rest%%:*}"; tgt="${rest##*:}"
  (
    bcp_load_table "$d" "$t" "$typ" "$tgt" "$TMPDIR_SEED" || {
      echo "${d}.${t}:ERR:bcp failed" >> "$FAIL_LOG"
    }
  ) </dev/null &
  DONE=$((DONE + 1))
  if [ $((DONE % PARALLEL_JOBS)) -eq 0 ]; then
    for pid in $(jobs -p); do
      wait "$pid" || DB_FAILS=$((DB_FAILS + 1))
    done
    ELAPSED=$(( $(date +%s) - BCP_START ))
    # Calculate loaded data estimate
    LOADED_GB=$(( DONE * TARGET_BYTES / TABLES_TOTAL / 1073741824 ))
    RATE_MB=0
    [ "$ELAPSED" -gt 0 ] && RATE_MB=$(( LOADED_GB * 1024 / ELAPSED ))
    printf "    %s/%s tables  (%ds, ~%s GB, ~%s MB/s)\n" "$DONE" "$TOTAL_WORK" "$ELAPSED" "$LOADED_GB" "$RATE_MB"
  fi
done < "$WORK_FILE"

# Wait for remaining jobs
for pid in $(jobs -p); do
  wait "$pid" || DB_FAILS=$((DB_FAILS + 1))
done

BCP_END=$(date +%s)
BCP_SECS=$((BCP_END - BCP_START))
printf "    %s/%s tables  (%ds)\n" "$TOTAL_WORK" "$TOTAL_WORK" "$BCP_SECS"

rm -f "$WORK_FILE"

if [ -s "$FAIL_LOG" ]; then
  FCOUNT=$(wc -l < "$FAIL_LOG" | tr -d '[:space:]')
  printf "\n  %bWARN%b %s tables had issues:\n" "$Y" "$NC" "$FCOUNT"
  while IFS= read -r line; do printf "    %s\n" "$line"; done < "$FAIL_LOG"
fi

# ================================================================
# Phase 4: Enable CDC on all tables
# ================================================================
printf "\n  [4/4] Enabling CDC (3 DBs in parallel) ...\n"

for db in $DBS; do
  # Enable CDC at DB level first
  sql "USE master; EXEC msdb.dbo.rds_cdc_enable_db '${db}'" &>/dev/null || true
  generate_cdc_script "$db" "${TMPDIR_SEED}/${db}_cdc.sql"
done

CDC_PIDS=""
for db in $DBS; do
  (
    dfile "$db" "${TMPDIR_SEED}/${db}_cdc.sql" 2>/dev/null
    CDC_COUNT=$(dval "$db" "SELECT COUNT(*) FROM sys.tables t WHERE t.is_tracked_by_cdc=1")
    printf "    %bOK%b %s: CDC enabled on %s tables\n" "$G" "$NC" "$db" "$CDC_COUNT"
  ) &
  CDC_PIDS="$CDC_PIDS $!"
done
for pid in $CDC_PIDS; do wait "$pid" || true; done

# ================================================================
# Summary
# ================================================================
SEED_END=$(date +%s)
SEED_SECS=$((SEED_END - SEED_START))
SEED_H=$((SEED_SECS / 3600))
SEED_M=$(((SEED_SECS % 3600) / 60))
SEED_S=$((SEED_SECS % 60))

printf "\n  %b══════════════════════════════════════════════════════════%b\n" "$G" "$NC"
printf "  %b   Seed Complete%b\n" "$G" "$NC"
printf "  %b══════════════════════════════════════════════════════════%b\n\n" "$G" "$NC"
printf "  Wall time:  %dh %dm %ds (%d seconds)\n" "$SEED_H" "$SEED_M" "$SEED_S" "$SEED_SECS"
printf "  bcp phase:  %ds\n" "$BCP_SECS"

printf "\n  %-15s %8s %12s %10s\n" "Database" "Tables" "Rows" "Size"
printf "  %s\n" "──────────────────────────────────────────────────"
TOTAL_ROWS=0; TOTAL_TABLES=0; TOTAL_SIZE=0
for db in $DBS; do
  ROWS=$(dval "$db" "SELECT COALESCE(SUM(p.rows),0) FROM sys.tables t JOIN sys.partitions p ON t.object_id=p.object_id WHERE p.index_id IN (0,1) AND t.is_ms_shipped=0")
  TBLS=$(dval "$db" "SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped=0")
  SIZE=$($SQLCMD -C -S "$SC" -U "$SU" -P "$SW" -h -1 -Q "USE [$db]; SET NOCOUNT ON; SELECT CAST(SUM(a.total_pages)*8.0/1024 AS DECIMAL(10,1)) FROM sys.tables t JOIN sys.indexes i ON t.object_id=i.object_id JOIN sys.partitions p ON i.object_id=p.object_id AND i.index_id=p.index_id JOIN sys.allocation_units a ON p.partition_id=a.container_id WHERE t.is_ms_shipped=0" -W 2>/dev/null | grep -v '^Changed database' | tr -d ' \r\n' | grep -oE '[0-9.]+' || echo "0")
  printf "  %-15s %8s %12s %8s MB\n" "$db" "$TBLS" "$ROWS" "$SIZE"
  TOTAL_ROWS=$((TOTAL_ROWS + ROWS))
  TOTAL_TABLES=$((TOTAL_TABLES + TBLS))
  TOTAL_SIZE=$(python3 -c "print(f'{${TOTAL_SIZE:-0}+${SIZE:-0}:.1f}')")
done
printf "  %s\n" "──────────────────────────────────────────────────"
printf "  %-15s %8s %12s %8s MB\n" "TOTAL" "$TOTAL_TABLES" "$TOTAL_ROWS" "$TOTAL_SIZE"

if [ "$SEED_SECS" -gt 0 ] && [ "$TOTAL_ROWS" -gt 0 ]; then
  RATE=$((TOTAL_ROWS * 60 / SEED_SECS))
  THROUGHPUT=$((TOTAL_ROWS * BYTES_PER_ROW / SEED_SECS / 1048576))
  printf "\n  Throughput: %s rows/min, ~%s MB/s\n" "$RATE" "$THROUGHPUT"
fi
printf "\n"
