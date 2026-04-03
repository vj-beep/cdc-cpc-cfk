
#!/usr/bin/env bash
# ------------------------------------------------------------------
# env-setup.sh  -  Export DB passwords and endpoints as env vars
#
# Usage:  source env-setup.sh
#         (must use 'source' or '.' not './env-setup.sh')
# ------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf "ERROR: This script must be sourced, not executed.\n\n"
  printf "  source env-setup.sh\n"
  printf "  . env-setup.sh\n\n"
  exit 1
fi

if [ ! -f terraform.tfvars ]; then
  printf "ERROR: terraform.tfvars not found. Run from cdc-on-cpc/ directory.\n"
  return 1
fi

# ── Extract from terraform.tfvars ────────────────────────────────────
export CDC_SQL_USER=$(grep sqlserver_username terraform.tfvars | awk -F'"' '{print $2}')
export CDC_SQL_PASS=$(grep sqlserver_password terraform.tfvars | awk -F'"' '{print $2}')
export CDC_PG_USER=$(grep aurora_username terraform.tfvars | awk -F'"' '{print $2}')
export CDC_PG_PASS=$(grep aurora_password terraform.tfvars | awk -F'"' '{print $2}')
export CDC_PG_DB=$(grep aurora_db_name terraform.tfvars | awk -F'"' '{print $2}')
export CDC_PROJECT=$(grep project_name terraform.tfvars | awk -F'"' '{print $2}')
export CDC_REGION=$(grep aws_region terraform.tfvars | awk -F'"' '{print $2}')

# ── Extract from terraform outputs ──────────────────────────────────
if terraform output -raw sqlserver_endpoint &>/dev/null; then
  CDC_SQL_ENDPOINT=$(terraform output -raw sqlserver_endpoint)
  export CDC_SQL_HOST=$(echo "${CDC_SQL_ENDPOINT}" | cut -d: -f1)
  export CDC_SQL_PORT=$(echo "${CDC_SQL_ENDPOINT}" | cut -d: -f2)
  export CDC_SQL_CONN="${CDC_SQL_HOST},${CDC_SQL_PORT}"
else
  printf "WARN: terraform outputs not available. Run 'terraform apply' first.\n"
fi

if terraform output -raw aurora_pg_endpoint &>/dev/null; then
  CDC_PG_ENDPOINT=$(terraform output -raw aurora_pg_endpoint)
  export CDC_PG_HOST=$(echo "${CDC_PG_ENDPOINT}" | cut -d: -f1)
  export CDC_PG_PORT=$(echo "${CDC_PG_ENDPOINT}" | cut -d: -f2)
else
  printf "WARN: terraform outputs not available. Run 'terraform apply' first.\n"
fi

if terraform output -raw flink_state_bucket &>/dev/null; then
  export CDC_FLINK_BUCKET=$(terraform output -raw flink_state_bucket)
fi

# ── Set PGPASSWORD so psql never prompts ─────────────────────────────
export PGPASSWORD="${CDC_PG_PASS}"

# ── Print summary ────────────────────────────────────────────────────
printf "\n"
printf "CDC environment loaded:\n\n"
printf "  SQL Server:\n"
printf "    CDC_SQL_CONN   = %s\n" "${CDC_SQL_CONN:-not set}"
printf "    CDC_SQL_USER   = %s\n" "${CDC_SQL_USER}"
printf "    CDC_SQL_PASS   = %s\n" "${CDC_SQL_PASS}"
printf "\n"
printf "  Aurora PostgreSQL:\n"
printf "    CDC_PG_HOST    = %s\n" "${CDC_PG_HOST:-not set}"
printf "    CDC_PG_PORT    = %s\n" "${CDC_PG_PORT:-not set}"
printf "    CDC_PG_USER    = %s\n" "${CDC_PG_USER}"
printf "    CDC_PG_DB      = %s\n" "${CDC_PG_DB}"
printf "    CDC_PG_PASS    = %s\n" "${CDC_PG_PASS}"
printf "    PGPASSWORD     = (set, psql won't prompt)\n"
printf "\n"
printf "  Flink:\n"
printf "    CDC_FLINK_BUCKET = %s\n" "${CDC_FLINK_BUCKET:-not set}"
printf "\n"
printf "  Quick commands:\n\n"
printf "    sqlcmd -S \$CDC_SQL_CONN -U \$CDC_SQL_USER -P \$CDC_SQL_PASS -d cdcdb\n"
printf "    psql -h \$CDC_PG_HOST -p \$CDC_PG_PORT -U \$CDC_PG_USER -d \$CDC_PG_DB\n"
printf "\n"
