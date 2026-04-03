
#!/usr/bin/env bash
set -euo pipefail

printf "\n=== EKS Node Viewer Setup ===\n\n"

# ── Install ──────────────────────────────────────────────────────────
if command -v eks-node-viewer &>/dev/null; then
  printf "  OK  eks-node-viewer already installed\n"
  eks-node-viewer --version 2>/dev/null || true
else
  printf "  Installing eks-node-viewer via Homebrew ...\n"
  brew tap aws/tap
  brew install eks-node-viewer
  printf "  OK  Installed\n"
fi
printf "\n"

# ── Verify kubectl context ──────────────────────────────────────────
CONTEXT=$(kubectl config current-context 2>/dev/null || echo "none")
printf "  kubectl context: %s\n\n" "$CONTEXT"

# ── Print usage ──────────────────────────────────────────────────────
printf "=== Quick Commands ===\n\n"

printf "  # Default view (CPU requests vs allocatable)\n"
printf "  eks-node-viewer\n\n"

printf "  # Show memory instead of CPU\n"
printf "  eks-node-viewer --resources memory\n\n"

printf "  # Show both CPU and memory\n"
printf "  eks-node-viewer --resources cpu,memory\n\n"

printf "  # Show cost per node (requires pricing API)\n"
printf "  eks-node-viewer --resources cpu,memory --extra-labels node.kubernetes.io/instance-type\n\n"

printf "  # Filter to Karpenter-managed nodes only\n"
printf "  eks-node-viewer --node-selector karpenter.sh/nodepool\n\n"

printf "  # Filter to confluent workloads\n"
printf "  eks-node-viewer --node-selector karpenter.sh/nodepool --extra-labels topology.kubernetes.io/zone\n\n"

printf "  # Show instance type + zone + price\n"
printf "  eks-node-viewer --resources cpu,memory --extra-labels node.kubernetes.io/instance-type,topology.kubernetes.io/zone\n\n"

printf "=== Launching default view ===\n\n"
eks-node-viewer --resources cpu,memory --extra-labels node.kubernetes.io/instance-type,topology.kubernetes.io/zone
