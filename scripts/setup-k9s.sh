#!/usr/bin/env bash
# -----------------------------------------------------------------
# setup-k9s.sh  -  Install k9s on Mac and configure for cdc-on-cpc
# -----------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "============================================================"
echo " k9s Setup for CDC-on-CPC"
echo "============================================================"
echo ""

# ── 1. Install k9s via Homebrew ──────────────────────────────────────
echo ">>> [1/4] Installing k9s ..."
if command -v k9s &> /dev/null; then
  CURRENT_VERSION=$(k9s version --short 2>/dev/null | head -1 || echo "unknown")
  echo "    k9s already installed: ${CURRENT_VERSION}"
  echo "    Upgrading to latest ..."
  brew upgrade derailed/k9s/k9s 2>/dev/null || brew install derailed/k9s/k9s
else
  echo "    Installing via Homebrew ..."
  brew install derailed/k9s/k9s
fi
echo "    Installed: $(k9s version --short 2>/dev/null | head -1)"
echo ""

# ── 2. Ensure kubeconfig points to EKS cluster ──────────────────────
echo ">>> [2/4] Configuring kubectl context ..."
AWS_REGION="${AWS_REGION:-us-east-1}"

# Try terraform output first, fall back to tfvars project_name, then default
if command -v terraform &> /dev/null && terraform output -raw eks_cluster_name &> /dev/null; then
  CLUSTER_NAME=$(terraform output -raw eks_cluster_name)
elif [ -f terraform.tfvars ] && grep -q project_name terraform.tfvars; then
  CLUSTER_NAME=$(grep project_name terraform.tfvars | awk -F'"' '{print $2}')
else
  CLUSTER_NAME="${CDC_CLUSTER_NAME:-cdc-on-cpc}"
fi

echo "    Cluster: ${CLUSTER_NAME}"

if kubectl config current-context 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
  echo "    Already pointing to ${CLUSTER_NAME}"
else
  echo "    Updating kubeconfig for ${CLUSTER_NAME} ..."
  aws eks --region "${AWS_REGION}" update-kubeconfig --name "${CLUSTER_NAME}"
fi
echo ""

# ── 3. Create k9s config with useful defaults ───────────────────────
echo ">>> [3/4] Writing k9s config ..."
K9S_CONFIG_DIR="${HOME}/.config/k9s"
mkdir -p "${K9S_CONFIG_DIR}"

cat <<'K9SCONFIG' > "${K9S_CONFIG_DIR}/config.yaml"
k9s:
  refreshRate: 2
  maxConnRetry: 5
  readOnly: false
  noExitOnCtrlC: false
  ui:
    enableMouse: false
    headless: false
    logoless: false
    crumbsless: false
    noIcons: false
    skin: ""
  skipLatestRevCheck: false
  disablePodCounting: false
  shellPod:
    image: busybox:1.36
    namespace: default
    limits:
      cpu: 100m
      memory: 100Mi
  logger:
    tail: 200
    buffer: 5000
    sinceSeconds: -1
    textWrap: false
    showTime: true
  currentContext: ""
  currentCluster: ""
  clusters: {}
K9SCONFIG

echo "    Config written to ${K9S_CONFIG_DIR}/config.yaml"
echo ""

# ── 4. Create k9s aliases for CDC-on-CPC resources ──────────────────
echo ">>> [4/4] Writing k9s aliases + hotkeys ..."

cat <<'K9SALIASES' > "${K9S_CONFIG_DIR}/aliases.yaml"
aliases:
  # Confluent Platform CRDs
  kf:     kafka.platform.confluent.io
  kraft:  kraftcontrollers.platform.confluent.io
  conn:   connects.platform.confluent.io
  ctr:    connectors.platform.confluent.io
  sr:     schemaregistries.platform.confluent.io
  cc:     controlcenters.platform.confluent.io

  # Karpenter
  np:     nodepools.karpenter.sh
  nc:     ec2nodeclasses.karpenter.k8s.aws
  ncl:    nodeclaims.karpenter.sh

  # Monitoring
  sm:     servicemonitors.monitoring.coreos.com
  pm:     podmonitors.monitoring.coreos.com
  prom:   prometheuses.monitoring.coreos.com

  # External Secrets
  es:     externalsecrets.external-secrets.io
  ss:     secretstores.external-secrets.io
K9SALIASES

echo "    Aliases written to ${K9S_CONFIG_DIR}/aliases.yaml"

cat <<'K9SHOTKEYS' > "${K9S_CONFIG_DIR}/hotkeys.yaml"
hotKeys:
  # Shift-1: Jump to Confluent namespace pods
  shift-1:
    shortCut: Shift-1
    description: Confluent pods
    command: pods
    namespace: confluent

  # Shift-2: Jump to Kafka brokers
  shift-2:
    shortCut: Shift-2
    description: Kafka brokers
    command: kafka.platform.confluent.io
    namespace: confluent

  # Shift-3: Jump to Connectors
  shift-3:
    shortCut: Shift-3
    description: Connectors
    command: connectors.platform.confluent.io
    namespace: confluent

  # Shift-4: Jump to Karpenter NodePools
  shift-4:
    shortCut: Shift-4
    description: Karpenter NodePools
    command: nodepools.karpenter.sh
    namespace: all

  # Shift-5: Jump to monitoring namespace
  shift-5:
    shortCut: Shift-5
    description: Monitoring pods
    command: pods
    namespace: monitoring

  # Shift-L: Logs for selected pod
  shift-l:
    shortCut: Shift-L
    description: Pod logs
    command: logs
    namespace: confluent
K9SHOTKEYS

echo "    Hotkeys written to ${K9S_CONFIG_DIR}/hotkeys.yaml"
echo ""

# ── Print cheat sheet ────────────────────────────────────────────────
echo "============================================================"
echo " k9s is ready. Quick reference:"
echo "============================================================"
echo ""
echo " Launch:          k9s"
echo " Launch in ns:    k9s -n confluent"
echo " Launch readonly: k9s --readonly"
echo ""
echo " ── Navigation ──────────────────────────────────────────────"
echo " :pods            List pods (any namespace with :pods -A)"
echo " :svc             Services"
echo " :pv / :pvc       Persistent volumes"
echo " :no              Nodes"
echo " :events          Cluster events"
echo ""
echo " ── CDC-on-CPC Aliases (type : then alias) ─────────────────"
echo " :kf              Kafka clusters"
echo " :kraft           KRaft controllers"
echo " :conn            Connect clusters"
echo " :ctr             Connectors (Debezium, JDBC sink)"
echo " :sr              Schema Registry"
echo " :cc              Control Center"
echo " :np              Karpenter NodePools"
echo " :nc              Karpenter EC2NodeClasses"
echo " :ncl             Karpenter NodeClaims"
echo ""
echo " ── Hotkeys ─────────────────────────────────────────────────"
echo " Shift-1          Confluent pods"
echo " Shift-2          Kafka brokers"
echo " Shift-3          Connectors"
echo " Shift-4          Karpenter NodePools"
echo " Shift-5          Monitoring pods"
echo ""
echo " ── Inside a resource ───────────────────────────────────────"
echo " Enter             Describe / drill in"
echo " l                 View logs"
echo " s                 Shell into pod"
echo " d                 Delete resource"
echo " Ctrl-d            Delete resource (force)"
echo " y                 YAML view"
echo " Esc               Back"
echo " Ctrl-c            Quit"
echo "============================================================"
