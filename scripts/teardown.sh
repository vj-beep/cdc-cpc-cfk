
#!/usr/bin/env bash
set +e

# ================================================================
# teardown.sh
# Full K8s-side cleanup before terraform destroy.
# Tears down in reverse dependency order.
#
# Usage:
#   ./teardown.sh          # interactive (prompts)
#   ./teardown.sh --force  # no prompts
# ================================================================

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; NC='\033[0m'

FORCE=false
[ "${1:-}" = "--force" ] && FORCE=true

confirm() {
  if [ "$FORCE" = true ]; then return 0; fi
  read -p "  $1 (y/N) " ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

printf "\n%b   +=== Teardown ===%b\n\n" "$R" "$NC"

if ! confirm "This will destroy all K8s workloads. Continue?"; then
  printf "  Aborted.\n\n"
  exit 0
fi

# ── 1. Kill port-forwards ──────────────────────────

printf "\n  [1/7] Killing port-forwards ...\n"
pkill -f "port-forward.*confluent" 2>/dev/null || true
pkill -f "port-forward.*flink" 2>/dev/null || true
pkill -f "port-forward.*monitoring" 2>/dev/null || true
pkill -f "port-forward.*8083" 2>/dev/null || true
pkill -f "port-forward.*8090" 2>/dev/null || true
pkill -f "port-forward.*9021" 2>/dev/null || true
pkill -f "port-forward.*3000" 2>/dev/null || true
printf "    %bOK%b\n" "$G" "$NC"

# ── 2. Flink ───────────────────────────────────────

printf "\n  [2/7] Flink ...\n"
if kubectl get ns flink > /dev/null 2>&1; then
  # Delete all FlinkDeployments first (so FKO cleans up pods)
  kubectl delete flinkdeployments --all -n flink --timeout=60s 2>/dev/null || true
  printf "    FlinkDeployments deleted\n"

  # Uninstall Helm releases
  helm uninstall cmf -n flink 2>/dev/null && printf "    CMF uninstalled\n" || true
  helm uninstall cp-flink-kubernetes-operator -n flink 2>/dev/null && printf "    FKO uninstalled\n" || true

  # Clean up Flink CRDs
  for crd in flinkapplications.platform.confluent.io flinkdeployments.flink.apache.org \
             flinkenvironments.platform.confluent.io flinksessionjobs.flink.apache.org \
             flinkstatesnapshots.flink.apache.org; do
    kubectl delete crd "$crd" 2>/dev/null || true
  done
  printf "    Flink CRDs cleaned\n"

  # Force-delete any stuck pods and PVCs
  kubectl delete pods --all -n flink --force --grace-period=0 2>/dev/null || true
  kubectl delete pvc --all -n flink --timeout=30s 2>/dev/null || true
  # Remove PVC finalizers if still stuck
  for pvc in $(kubectl get pvc -n flink -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl patch pvc "$pvc" -n flink --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  done

  # Delete namespace
  if ! kubectl delete ns flink --timeout=60s 2>/dev/null; then
    # Remove finalizer if namespace is stuck Terminating
    kubectl get ns flink -o json 2>/dev/null \
      | python3 -c "import sys,json; ns=json.load(sys.stdin); ns['spec']['finalizers']=[]; json.dump(ns,sys.stdout)" \
      | kubectl replace --raw /api/v1/namespaces/flink/finalize -f - 2>/dev/null || true
    printf "    flink namespace finalizer removed\n"
  fi
  printf "    flink namespace deleted\n"
else
  printf "    %bSKIP%b flink namespace not found\n" "$Y" "$NC"
fi

# ── 3. cert-manager ───────────────────────────────

printf "\n  [3/7] cert-manager ...\n"
if kubectl get ns cert-manager > /dev/null 2>&1; then
  helm uninstall cert-manager -n cert-manager 2>/dev/null && printf "    cert-manager uninstalled\n" || true
  # Clean up CRDs kept by resource policy
  for crd in certificaterequests certificates challenges clusterissuers issuers orders; do
    kubectl delete crd "${crd}.cert-manager.io" 2>/dev/null || true
    kubectl delete crd "${crd}.acme.cert-manager.io" 2>/dev/null || true
  done
  printf "    cert-manager CRDs cleaned\n"
  kubectl delete pods --all -n cert-manager --force --grace-period=0 2>/dev/null || true
  if ! kubectl delete ns cert-manager --timeout=60s 2>/dev/null; then
    kubectl get ns cert-manager -o json 2>/dev/null \
      | python3 -c "import sys,json; ns=json.load(sys.stdin); ns['spec']['finalizers']=[]; json.dump(ns,sys.stdout)" \
      | kubectl replace --raw /api/v1/namespaces/cert-manager/finalize -f - 2>/dev/null || true
    printf "    cert-manager namespace finalizer removed\n"
  fi
else
  printf "    %bSKIP%b not found\n" "$Y" "$NC"
fi

# ── 4. Connectors + Connect ───────────────────────

printf "\n  [4/7] Connectors + Connect ...\n"
if kubectl get ns confluent > /dev/null 2>&1; then
  # Delete Connector CRs first
  kubectl delete connectors --all -n confluent --timeout=60s 2>/dev/null && printf "    Connector CRs deleted\n" || true

  # Scale Connect to 0 — pause KEDA first to prevent fight loop
  kubectl annotate scaledobject connect-autoscaler -n confluent \
    autoscaling.keda.sh/paused-replicas="0" --overwrite 2>/dev/null || true
  kubectl patch connect connect -n confluent --type merge -p '{"spec":{"replicas":0}}' 2>/dev/null || true
  kubectl delete pods -n confluent -l app=connect --force --grace-period=0 2>/dev/null || true
  printf "    Connect scaled to 0\n"
fi

# ── 5. Confluent Platform ─────────────────────────

printf "\n  [5/7] Confluent Platform ...\n"
if kubectl get ns confluent > /dev/null 2>&1; then
  # Delete CP CRs in dependency order
  for kind in Connect KsqlDB ControlCenter SchemaRegistry KafkaRestProxy Kafka KRaftController Zookeeper; do
    FOUND=$(kubectl get "$kind" -n confluent --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    if [ "$FOUND" -gt 0 ] 2>/dev/null; then
      kubectl delete "$kind" --all -n confluent --timeout=120s 2>/dev/null || true
      printf "    %s deleted\n" "$kind"
    fi
  done

  # Delete PVCs (Kafka data, ZK data, etc.)
  kubectl delete pvc --all -n confluent --timeout=60s 2>/dev/null && printf "    PVCs deleted\n" || true

  # Uninstall CFK operator
  helm uninstall confluent-operator -n confluent 2>/dev/null && printf "    CFK operator uninstalled\n" || true
  helm uninstall confluent-for-kubernetes -n confluent 2>/dev/null || true

  # Force-delete any stuck pods
  kubectl delete pods --all -n confluent --force --grace-period=0 2>/dev/null || true

  # Delete namespace
  if ! kubectl delete ns confluent --timeout=120s 2>/dev/null; then
    kubectl get ns confluent -o json 2>/dev/null \
      | python3 -c "import sys,json; ns=json.load(sys.stdin); ns['spec']['finalizers']=[]; json.dump(ns,sys.stdout)" \
      | kubectl replace --raw /api/v1/namespaces/confluent/finalize -f - 2>/dev/null || true
    printf "    confluent namespace finalizer removed\n"
  fi
  printf "    confluent namespace deleted\n"
else
  printf "    %bSKIP%b confluent namespace not found\n" "$Y" "$NC"
fi

# ── 6. Monitoring ──────────────────────────────────

printf "\n  [6/7] Monitoring ...\n"
if kubectl get ns monitoring > /dev/null 2>&1; then
  helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null && printf "    Prometheus stack uninstalled\n" || true

  # CRDs left behind by prometheus-operator
  for crd in alertmanagerconfigs alertmanagers podmonitors probes prometheusagents \
             prometheuses prometheusrules scrapeconfigs servicemonitors thanosrulers; do
    kubectl delete crd "${crd}.monitoring.coreos.com" 2>/dev/null || true
  done
  printf "    Prometheus CRDs cleaned\n"

  kubectl delete ns monitoring --timeout=60s 2>/dev/null && printf "    monitoring namespace deleted\n" || true
else
  printf "    %bSKIP%b monitoring namespace not found\n" "$Y" "$NC"
fi

# ── 7. Karpenter + KEDA ───────────────────────────

printf "\n  [7/7] Karpenter + KEDA ...\n"

# Delete NodePools and EC2NodeClasses (Karpenter CRs)
kubectl delete nodepools --all 2>/dev/null && printf "    NodePools deleted\n" || true
kubectl delete ec2nodeclasses --all 2>/dev/null && printf "    EC2NodeClasses deleted\n" || true

# KEDA
if kubectl get ns keda > /dev/null 2>&1; then
  helm uninstall keda -n keda 2>/dev/null && printf "    KEDA uninstalled\n" || true
  kubectl delete ns keda --timeout=60s 2>/dev/null || true
fi

# ── Summary ────────────────────────────────────────

printf "\n"
printf "  ════════════════════════════════════════════════════════\n"
printf "  Teardown complete.\n"
printf "\n"
printf "  Namespaces removed:\n"
printf "    flink, cert-manager, confluent, monitoring, keda\n"
printf "\n"
printf "  Remaining K8s resources (managed by Terraform):\n"
kubectl get ns --no-headers 2>/dev/null | while read -r line; do
  ns=$(echo "$line" | awk '{print $1}')
  printf "    %s\n" "$ns"
done
printf "\n"
printf "  Next:\n"
printf "    terraform destroy    # removes EKS, RDS, Aurora, VPC, IAM\n"
printf "  ════════════════════════════════════════════════════════\n\n"
