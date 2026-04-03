#!/usr/bin/env bash
# migrate-state.sh — Move terraform state from flat files into modules.
# Run once after converting numbered .tf files to module structure.
#
# Usage: ./scripts/migrate-state.sh [--dry-run]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

DRY_RUN=""
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN="echo [DRY-RUN]"

echo "=== Backing up state ==="
terraform state pull > terraform.tfstate.backup
echo "Backup saved to terraform.tfstate.backup"

move() {
  echo "  $1 → $2"
  ${DRY_RUN} terraform state mv "$1" "$2" 2>/dev/null || echo "  SKIP (not in state): $1"
}

echo ""
echo "=== Networking ==="
move 'module.vpc' 'module.networking.module.vpc'

echo ""
echo "=== EKS ==="
move 'module.eks' 'module.eks.module.eks'
move 'module.ebs_csi_irsa' 'module.eks.module.ebs_csi_irsa'
move 'module.karpenter' 'module.eks.module.karpenter'
move 'aws_iam_role_policy.karpenter_list_instance_profiles' 'module.eks.aws_iam_role_policy.karpenter_list_instance_profiles'
move 'helm_release.karpenter' 'module.eks.helm_release.karpenter'
move 'kubectl_manifest.karpenter_node_class' 'module.eks.kubectl_manifest.karpenter_node_class'
move 'kubectl_manifest.karpenter_node_pool' 'module.eks.kubectl_manifest.karpenter_node_pool'
move 'kubectl_manifest.nodepool_bulk' 'module.eks.kubectl_manifest.nodepool_bulk'
move 'kubectl_manifest.nodepool_cdc' 'module.eks.kubectl_manifest.nodepool_cdc'

echo ""
echo "=== Databases ==="
move 'aws_security_group.sqlserver' 'module.databases.aws_security_group.sqlserver'
move 'aws_security_group_rule.sqlserver_from_eks' 'module.databases.aws_security_group_rule.sqlserver_from_eks'
move 'aws_security_group_rule.sqlserver_from_mac' 'module.databases.aws_security_group_rule.sqlserver_from_mac'
move 'aws_security_group_rule.sqlserver_from_cloud9' 'module.databases.aws_security_group_rule.sqlserver_from_cloud9'
move 'aws_security_group_rule.sqlserver_egress' 'module.databases.aws_security_group_rule.sqlserver_egress'
move 'aws_security_group.aurora_pg' 'module.databases.aws_security_group.aurora_pg'
move 'aws_security_group_rule.aurora_from_eks' 'module.databases.aws_security_group_rule.aurora_from_eks'
move 'aws_security_group_rule.aurora_from_mac' 'module.databases.aws_security_group_rule.aurora_from_mac'
move 'aws_security_group_rule.aurora_from_cloud9' 'module.databases.aws_security_group_rule.aurora_from_cloud9'
move 'aws_security_group_rule.aurora_egress' 'module.databases.aws_security_group_rule.aurora_egress'
move 'aws_db_option_group.sqlserver' 'module.databases.aws_db_option_group.sqlserver'
move 'aws_db_parameter_group.sqlserver' 'module.databases.aws_db_parameter_group.sqlserver'
move 'aws_db_instance.sqlserver' 'module.databases.aws_db_instance.sqlserver'
move 'aws_rds_cluster_parameter_group.aurora_pg' 'module.databases.aws_rds_cluster_parameter_group.aurora_pg'
move 'aws_db_parameter_group.aurora_pg' 'module.databases.aws_db_parameter_group.aurora_pg'
move 'aws_rds_cluster.aurora_pg' 'module.databases.aws_rds_cluster.aurora_pg'
move 'aws_rds_cluster_instance.aurora_pg_writer' 'module.databases.aws_rds_cluster_instance.aurora_pg_writer'
move 'aws_rds_cluster_instance.aurora_pg_reader' 'module.databases.aws_rds_cluster_instance.aurora_pg_reader'

echo ""
echo "=== Confluent Platform ==="
move 'aws_ecr_repository.connect' 'module.confluent_platform.aws_ecr_repository.connect'
move 'aws_ecr_lifecycle_policy.connect' 'module.confluent_platform.aws_ecr_lifecycle_policy.connect'
move 'kubernetes_namespace.confluent' 'module.confluent_platform.kubernetes_namespace.confluent'
move 'helm_release.confluent_operator' 'module.confluent_platform.helm_release.confluent_operator'
move 'kubectl_manifest.gp3_sc' 'module.confluent_platform.kubectl_manifest.gp3_sc'
move 'kubectl_manifest.kraft_controller' 'module.confluent_platform.kubectl_manifest.kraft_controller'
move 'kubectl_manifest.kafka' 'module.confluent_platform.kubectl_manifest.kafka'
move 'kubectl_manifest.schema_registry' 'module.confluent_platform.kubectl_manifest.schema_registry'
move 'kubectl_manifest.connect' 'module.confluent_platform.kubectl_manifest.connect'
move 'kubectl_manifest.controlcenter' 'module.confluent_platform.kubectl_manifest.controlcenter'
move 'kubectl_manifest.kafka_ui' 'module.confluent_platform.kubectl_manifest.kafka_ui'
move 'kubectl_manifest.kafka_ui_service' 'module.confluent_platform.kubectl_manifest.kafka_ui_service'

echo ""
echo "=== Connectors ==="
move 'kubectl_manifest.debezium_bulk["financedb"]' 'module.connectors.kubectl_manifest.debezium_bulk["financedb"]'
move 'kubectl_manifest.debezium_bulk["retaildb"]' 'module.connectors.kubectl_manifest.debezium_bulk["retaildb"]'
move 'kubectl_manifest.debezium_bulk["logsdb"]' 'module.connectors.kubectl_manifest.debezium_bulk["logsdb"]'
move 'kubectl_manifest.jdbc_sink_standard["financedb"]' 'module.connectors.kubectl_manifest.jdbc_sink_standard["financedb"]'
move 'kubectl_manifest.jdbc_sink_standard["retaildb"]' 'module.connectors.kubectl_manifest.jdbc_sink_standard["retaildb"]'
move 'kubectl_manifest.jdbc_sink_standard["logsdb"]' 'module.connectors.kubectl_manifest.jdbc_sink_standard["logsdb"]'
move 'kubectl_manifest.toxiproxy_deployment[0]' 'module.connectors.kubectl_manifest.toxiproxy_deployment[0]'
move 'kubectl_manifest.toxiproxy_service[0]' 'module.connectors.kubectl_manifest.toxiproxy_service[0]'
move 'kubectl_manifest.toxiproxy_config[0]' 'module.connectors.kubectl_manifest.toxiproxy_config[0]'

echo ""
echo "=== Observability ==="
move 'kubernetes_namespace.monitoring' 'module.observability.kubernetes_namespace.monitoring'
move 'helm_release.prometheus_stack' 'module.observability.helm_release.prometheus_stack'
move 'kubernetes_namespace.external_secrets' 'module.observability.kubernetes_namespace.external_secrets'
move 'helm_release.external_secrets' 'module.observability.helm_release.external_secrets'
move 'kubectl_manifest.podmonitor_kafka' 'module.observability.kubectl_manifest.podmonitor_kafka'
move 'kubectl_manifest.podmonitor_kraft' 'module.observability.kubectl_manifest.podmonitor_kraft'
move 'kubectl_manifest.podmonitor_connect' 'module.observability.kubectl_manifest.podmonitor_connect'
move 'kubectl_manifest.podmonitor_schemaregistry' 'module.observability.kubectl_manifest.podmonitor_schemaregistry'
move 'kubernetes_namespace.keda' 'module.observability.kubernetes_namespace.keda'
move 'helm_release.keda' 'module.observability.helm_release.keda'
move 'kubectl_manifest.connect_scaledobject' 'module.observability.kubectl_manifest.connect_scaledobject'

echo ""
echo "=== Flink ==="
move 'aws_s3_bucket.flink_state' 'module.flink.aws_s3_bucket.flink_state'
move 'aws_s3_bucket_server_side_encryption_configuration.flink_state' 'module.flink.aws_s3_bucket_server_side_encryption_configuration.flink_state'
move 'aws_s3_bucket_versioning.flink_state' 'module.flink.aws_s3_bucket_versioning.flink_state'
move 'aws_s3_bucket_public_access_block.flink_state' 'module.flink.aws_s3_bucket_public_access_block.flink_state'
move 'aws_iam_policy.flink_s3' 'module.flink.aws_iam_policy.flink_s3'
move 'aws_iam_role_policy_attachment.flink_s3' 'module.flink.aws_iam_role_policy_attachment.flink_s3'
move 'kubernetes_namespace.cert_manager' 'module.flink.kubernetes_namespace.cert_manager'
move 'helm_release.cert_manager' 'module.flink.helm_release.cert_manager'
move 'kubernetes_namespace.flink' 'module.flink.kubernetes_namespace.flink'
move 'helm_release.flink_kubernetes_operator' 'module.flink.helm_release.flink_kubernetes_operator'
move 'helm_release.cmf' 'module.flink.helm_release.cmf'

echo ""
echo "=== Done ==="
echo "Run 'terraform plan' to verify zero changes."
