#!/usr/bin/env bash
# ================================================================
# cdc.sh — manage CDC pipeline (Connect, Kafka, Flink, Aurora)
#
# Thin dispatcher — all logic lives in lib/*.sh modules.
# ================================================================

if [ ! -f terraform.tfvars ]; then echo "ERROR: Run from cdc-on-cpc/"; exit 1; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source library modules (order matters: common -> aurora -> kafka -> connect -> monitor)
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/aurora.sh"
source "$SCRIPT_DIR/lib/kafka.sh"
source "$SCRIPT_DIR/lib/connect.sh"
source "$SCRIPT_DIR/lib/monitor.sh"

# ── Help ──────────────────────────────────────────────

if [ $# -lt 1 ]; then
  printf "\n"
  printf "  %b━━━ cdc.sh ━━━%b\n\n" "$C" "$NC"
  printf "  %binfra%b                            Cluster health\n" "$W" "$NC"
  printf "    infra status                    Connectors + pods + errors\n"
  printf "    infra topics [clean|nuke]       List / clean / nuke Kafka topics\n"
  printf "    infra grafana                   Import Grafana CDC dashboard\n\n"
  printf "  %bconnect%b                          Manage Connect cluster\n" "$W" "$NC"
  printf "    connect cdc [N]                 CDC profile (default 2)\n"
  printf "    connect bulk [N]                Bulk profile (default 4)\n"
  printf "    connect aggressive [N]          Bulk + expand partitions (default 6)\n"
  printf "    connect stop                    Scale to 0\n"
  printf "    connect restart [name]          Restart failed tasks\n\n"
  printf "  %bpipeline%b                         Run CDC workloads\n" "$W" "$NC"
  printf "    pipeline snapshot [N]           Full snapshot (default 6 workers)\n"
  printf "    pipeline cdc <GB/day>           Steady-state DML (Ctrl+C to stop)\n"
  printf "    pipeline monitor                Re-attach Aurora progress monitor\n"
  printf "    pipeline verify                 Compare SQL Server vs Aurora\n"
  printf "    pipeline reset                  Stop + clean everything\n\n"
  printf "  %bflink%b                            CP Flink operations\n" "$W" "$NC"
  printf "    flink setup                     Create CMF env + catalog\n"
  printf "    flink sql <file>                Submit Flink SQL\n"
  printf "    flink app <file>                Submit FlinkApplication\n"
  printf "    flink status | stop | ui | logs\n\n"
  printf "  %btoxiproxy%b                        On-prem latency simulation\n" "$W" "$NC"
  printf "    toxiproxy setup                 Create proxy + default latency\n"
  printf "    toxiproxy status                Show proxy and active toxics\n"
  printf "    toxiproxy latency [ms] [jitter] Set latency (default 20ms +/- 5ms)\n"
  printf "    toxiproxy bandwidth [KB/s]      Cap bandwidth (default ~1Gbps)\n"
  printf "    toxiproxy reset                 Remove all toxics (passthrough)\n\n"
  exit 0
fi

CMD="$1"; shift

case "$CMD" in
  infra)      source "$SCRIPT_DIR/lib/cmd-infra.sh" ;;
  connect)    source "$SCRIPT_DIR/lib/cmd-connect.sh" ;;
  pipeline)   source "$SCRIPT_DIR/lib/cmd-pipeline.sh" ;;
  flink)      source "$SCRIPT_DIR/lib/cmd-flink.sh" ;;
  toxiproxy)  source "$SCRIPT_DIR/lib/cmd-toxiproxy.sh" ;;
  *)          printf "\n  Unknown: %s — run ./cdc.sh for help.\n\n" "$CMD" ;;
esac
