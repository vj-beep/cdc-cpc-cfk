# ── EKS ──────────────────────────────────────────────────────────────
output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API endpoint"
  value       = module.eks.cluster_endpoint
}

output "configure_kubectl" {
  description = "Run this to configure kubectl"
  value       = "aws eks --region ${var.aws_region} update-kubeconfig --name ${module.eks.cluster_name}"
}

# ── RDS SQL Server ───────────────────────────────────────────────────
output "sqlserver_endpoint" {
  description = "SQL Server endpoint (host:port)"
  value       = "${module.databases.sqlserver_address}:${module.databases.sqlserver_port}"
}

output "sqlserver_connection_command" {
  description = "Connect via sqlcmd"
  value       = "sqlcmd -S ${module.databases.sqlserver_address},${module.databases.sqlserver_port} -U ${var.sqlserver_username} -P '<password>'"
}

# ── Aurora PostgreSQL ────────────────────────────────────────────────
output "aurora_pg_endpoint" {
  description = "Aurora PostgreSQL writer endpoint"
  value       = "${module.databases.aurora_endpoint}:${module.databases.aurora_port}"
}

output "aurora_pg_reader_endpoint" {
  description = "Aurora PostgreSQL reader endpoint"
  value       = "${module.databases.aurora_reader_endpoint}:${module.databases.aurora_port}"
}

output "aurora_connection_command" {
  description = "Connect via psql"
  value       = "psql -h ${module.databases.aurora_endpoint} -p ${module.databases.aurora_port} -U ${var.aurora_username} -d ${var.aurora_db_name}"
}

# ── ECR ──────────────────────────────────────────────────────────────
output "connect_image_repo" {
  description = "ECR repo for custom Connect image"
  value       = module.confluent_platform.ecr_repository_url
}

# ── Flink ────────────────────────────────────────────────────────────
output "flink_namespace" {
  description = "Namespace where CP Flink components run"
  value       = module.flink.flink_namespace_name
}

output "cmf_service" {
  description = "CMF in-cluster service endpoint"
  value       = "cmf-service.${var.flink_namespace}.svc.cluster.local:80"
}

output "flink_state_bucket" {
  description = "S3 bucket for Flink checkpoints and savepoints"
  value       = module.flink.flink_state_bucket
}

# ── Quick Reference ──────────────────────────────────────────────────
output "quick_reference" {
  description = "Post-apply quick reference"
  value       = <<-EOT

    ════════════════════════════════════════════════════════════════
     CDC on CPC — Quick Reference
    ════════════════════════════════════════════════════════════════

     EKS
       Cluster:    ${module.eks.cluster_name}
       Region:     ${var.aws_region}
       kubectl:    aws eks --region ${var.aws_region} update-kubeconfig --name ${module.eks.cluster_name}

     SQL Server (CDC source)
       Endpoint:   ${module.databases.sqlserver_address}:${module.databases.sqlserver_port}
       User:       ${var.sqlserver_username}
       sqlcmd:     sqlcmd -S ${module.databases.sqlserver_address},${module.databases.sqlserver_port} -U ${var.sqlserver_username} -P '<password>'

     Aurora PostgreSQL (CDC sink)
       Writer:     ${module.databases.aurora_endpoint}:${module.databases.aurora_port}
       Reader:     ${module.databases.aurora_reader_endpoint}:${module.databases.aurora_port}
       User/DB:    ${var.aurora_username} / ${var.aurora_db_name}
       psql:       psql -h ${module.databases.aurora_endpoint} -p ${module.databases.aurora_port} -U ${var.aurora_username} -d ${var.aurora_db_name}

     Connect Image
       ECR:        ${module.confluent_platform.ecr_repository_url}

     Flink
       Namespace:  ${var.flink_namespace}
       S3 Bucket:  ${module.flink.flink_state_bucket}

     Toxiproxy (on-prem latency)
       Enabled:    ${var.toxiproxy_enabled}${var.toxiproxy_enabled ? "\n       Latency:    ${var.toxiproxy_latency_ms}ms ± ${var.toxiproxy_jitter_ms}ms\n       Setup:      ./cdc.sh toxiproxy setup" : ""}

     Next Steps
       1. ./scripts/build-connect-image.sh     # build & push Connect image
       2. ./scripts/seed-source-db.sh 1000     # seed SQL Server
       3. ./cdc.sh connect cdc 2               # start Connect workers
       4. ./cdc.sh pipeline snapshot 6         # full snapshot
       5. ./cdc.sh pipeline verify             # verify replication
       6. ./cdc.sh pipeline cdc 300            # steady-state CDC

     Port Forwards (Mac)
       ./scripts/mac-setup.sh > mac-connect.sh  # generate Mac script
       Control Center:   http://localhost:9021
       Schema Registry:  http://localhost:8081
       Connect REST:     http://localhost:8083
       Grafana:          http://localhost:3000  (admin/admin)
       Flink CMF:        http://localhost:8090

    ════════════════════════════════════════════════════════════════
  EOT
}
