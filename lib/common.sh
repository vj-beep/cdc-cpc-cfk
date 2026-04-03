# lib/common.sh — init, colors, endpoints, core helpers
# Sourced by cdc.sh — do not execute directly

NS="${CP_NAMESPACE:-confluent}"
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; W='\033[0;37m'; NC='\033[0m'

# ── Resolve endpoints (use env vars from env-setup.sh if available) ──
if [ -n "$CDC_SQL_HOST" ]; then
  SH="$CDC_SQL_HOST"; SP="$CDC_SQL_PORT"
else
  _sql_ep=$(terraform output -raw sqlserver_endpoint 2>/dev/null || echo ":")
  SH="${_sql_ep%%:*}"; SP="${_sql_ep##*:}"
fi
SU="${CDC_SQL_USER:-$(grep sqlserver_username terraform.tfvars | awk -F'"' '{print $2}')}"
SW="${CDC_SQL_PASS:-$(grep sqlserver_password terraform.tfvars | awk -F'"' '{print $2}')}"
SC="${SH},${SP}"

if [ -n "$CDC_PG_HOST" ]; then
  PH="$CDC_PG_HOST"; PP="$CDC_PG_PORT"
else
  _pg_ep=$(terraform output -raw aurora_pg_endpoint 2>/dev/null || echo ":")
  PH="${_pg_ep%%:*}"; PP="${_pg_ep##*:}"
fi
PU="${CDC_PG_USER:-$(grep aurora_username terraform.tfvars | awk -F'"' '{print $2}')}"
PW="${CDC_PG_PASS:-$(grep aurora_password terraform.tfvars | awk -F'"' '{print $2}')}"
PD="${CDC_PG_DB:-$(grep aurora_db_name terraform.tfvars | awk -F'"' '{print $2}')}"
export PGPASSWORD="${PW}"

if [ -z "$SH" ] || [ "$SH" = "" ]; then
  printf "%bERROR%b Could not resolve SQL Server endpoint from terraform output.\n" "$R" "$NC" >&2
  printf "       Run 'terraform apply' first or 'source env-setup.sh'.\n" >&2
  exit 1
fi

API="http://localhost:8083/connectors"
DBS="financedb retaildb logsdb"
ALL_CONNECTORS="debezium-financedb debezium-retaildb debezium-logsdb jdbc-sink-financedb jdbc-sink-retaildb jdbc-sink-logsdb"
SINK_SCHEMAS="financedb retaildb logsdb"

# ── Core helpers ─────────────────────────────────────

SQLCMD="${SQLCMD:-/opt/mssql-tools18/bin/sqlcmd}"
sd()  { $SQLCMD -C -S "${SC}" -U "${SU}" -P "${SW}" -Q "USE [$1]; $2" -W 2>/dev/null | grep -v '^Changed database'; }
pgv() { PGPASSWORD="${PW}" psql -h "${PH}" -p "${PP}" -U "${PU}" -d "${PD}" -t -A -c "$1" 2>/dev/null || echo "0"; }
pg()  { PGPASSWORD="${PW}" psql -h "${PH}" -p "${PP}" -U "${PU}" -d "${PD}" -c "$1" 2>/dev/null; }

kafka_exec() {
  kubectl exec kafka-0 -n "$NS" -c kafka -- "$@" 2>/dev/null
}
