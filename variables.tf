# ── General ──────────────────────────────────────────────────────────
variable "project_name" {
  description = "Prefix for all AWS resource names"
  type        = string
  default     = "cdc-on-cpc"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment label (dev/staging/prod)"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

# ── Mac Connectivity ─────────────────────────────────────────────────
variable "my_ip" {
  description = "Your Mac public IP in CIDR (e.g. 203.0.113.42/32)"
  type        = string
}

variable "mac_iam_role_arn" {
  description = "IAM role ARN for Mac SSO user to grant EKS cluster admin access"
  type        = string
  default     = ""
}

# ── EKS ──────────────────────────────────────────────────────────────
variable "eks_cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.31"
}

variable "eks_node_instance_types" {
  description = "Instance types for the bootstrap managed node group"
  type        = list(string)
  default     = ["m5.xlarge"]
}

variable "karpenter_version" {
  description = "Karpenter Helm chart version"
  type        = string
  default     = "1.9.0"
}

# ── RDS SQL Server (source) ─────────────────────────────────────────
variable "sqlserver_instance_class" {
  description = "Instance class for RDS SQL Server"
  type        = string
  default     = "db.r6i.8xlarge"
}

variable "sqlserver_engine_version" {
  description = "RDS SQL Server SE 2019 engine version"
  type        = string
  default     = "15.00.4415.2.v1"
}

variable "sqlserver_username" {
  description = "Master username for SQL Server"
  type        = string
  default     = "cdcadmin"
}

variable "sqlserver_password" {
  description = "Master password for SQL Server"
  type        = string
  sensitive   = true
}

variable "sqlserver_allocated_storage" {
  description = "Allocated storage in GB"
  type        = number
  default     = 1000
}

variable "sqlserver_max_allocated_storage" {
  description = "Max autoscaled storage in GB"
  type        = number
  default     = 2000
}

variable "sqlserver_iops" {
  description = "Provisioned IOPS for gp3 (baseline 3000, max 16000)"
  type        = number
  default     = 12000
}

variable "sqlserver_storage_throughput" {
  description = "Provisioned throughput MB/s for gp3 (baseline 125, max 1000)"
  type        = number
  default     = 500
}

# ── Aurora PostgreSQL (sink) ─────────────────────────────────────────
variable "aurora_pg_engine_version" {
  description = "Aurora PostgreSQL engine version"
  type        = string
  default     = "16.8"
}

variable "aurora_pg_instance_class" {
  description = "Instance class for Aurora PostgreSQL"
  type        = string
  default     = "db.r6i.2xlarge"
}

variable "aurora_username" {
  description = "Master username for Aurora PostgreSQL"
  type        = string
  default     = "postgres"
}

variable "aurora_password" {
  description = "Master password for Aurora PostgreSQL"
  type        = string
  sensitive   = true
}

variable "aurora_db_name" {
  description = "Default database name in Aurora"
  type        = string
  default     = "sinkdb"
}

# ── Confluent Platform ───────────────────────────────────────────────
variable "cp_namespace" {
  description = "Kubernetes namespace for Confluent Platform"
  type        = string
  default     = "confluent"
}

variable "cp_version" {
  description = "Confluent Platform image tag (8.2.0 = Kafka 4.2)"
  type        = string
  default     = "7.9.0"
}

variable "cfk_chart_version" {
  description = "CFK Helm chart version (maps to CFK 3.2.0)"
  type        = string
  default     = "0.1514.1"
}

variable "cfk_init_container_version" {
  description = "CFK init container image tag"
  type        = string
  default     = "3.2.0"
}

variable "kafka_replicas" {
  description = "Number of Kafka broker replicas"
  type        = number
  default     = 3
}

variable "kafka_data_volume_capacity" {
  description = "Storage per Kafka broker (must hold snapshot data × RF / brokers + headroom)"
  type        = string
  default     = "500Gi"
}

variable "kafka_log_retention_hours" {
  description = "Topic log retention in hours (168 = 7 days)"
  type        = number
  default     = 72
}

variable "kafka_log_retention_bytes" {
  description = "Per-partition retention cap in bytes (-1 = unlimited). Prevents disk exhaustion."
  type        = number
  default     = 5368709120 # 5 GB per partition
}

variable "kraft_replicas" {
  description = "Number of KRaft controller replicas (must be odd >= 3)"
  type        = number
  default     = 3
}

# ── Connect image ────────────────────────────────────────────────────
variable "debezium_task_max" {
  description = "Max tasks per Debezium source connector. Higher values parallelize snapshot reads across tables."
  type        = number
  default     = 10
}

variable "jdbc_sink_task_max" {
  description = "Max tasks per JDBC sink connector. Match to topic partitions for full parallelism."
  type        = number
  default     = 6
}

variable "jdbc_sink_batch_size" {
  description = "JDBC sink batch size. Use 10000+ for bulk snapshot, 3000 for steady-state CDC."
  type        = number
  default     = 10000
}

variable "cdc_topic_partitions" {
  description = "Partition count for CDC data topics. Match to sink tasks for parallel writes."
  type        = number
  default     = 6
}

# ── Monitoring ───────────────────────────────────────────────────────
variable "prometheus_stack_version" {
  description = "kube-prometheus-stack Helm chart version"
  type        = string
  default     = "58.4.0"
}

variable "eso_version" {
  description = "External Secrets Operator Helm chart version"
  type        = string
  default     = "0.9.16"
}

variable "keda_chart_version" {
  description = "KEDA Helm chart version"
  type        = string
  default     = "2.14.0"
}
# ------------------------------------------------------------------
#   CP Flink
# ------------------------------------------------------------------

variable "flink_namespace" {
  description = "Kubernetes namespace for CP Flink (CMF + FKO)"
  type        = string
  default     = "flink"
}

variable "cert_manager_version" {
  description = "cert-manager Helm chart version"
  type        = string
  default     = "v1.18.2"
}

variable "flink_operator_version" {
  description = "Confluent Flink Kubernetes Operator chart version"
  type        = string
  default     = "1.130.2"
}

variable "cmf_version" {
  description = "Confluent Manager for Apache Flink chart version"
  type        = string
  default     = "2.2.0"
}

# ------------------------------------------------------------------
#   Toxiproxy (on-prem latency simulation)
# ------------------------------------------------------------------

variable "toxiproxy_enabled" {
  description = "Deploy Toxiproxy to simulate on-prem SQL Server latency. Debezium connects via proxy instead of direct RDS."
  type        = bool
  default     = false
}

variable "toxiproxy_latency_ms" {
  description = "Simulated network latency in ms (typical on-prem: 10-30 same metro, 30-80 cross-country)"
  type        = number
  default     = 20
}

variable "toxiproxy_jitter_ms" {
  description = "Latency jitter in ms"
  type        = number
  default     = 5
}

# ------------------------------------------------------------------
#   Connect Cluster (starts at 0 — scale up after seeding)
# ------------------------------------------------------------------

variable "connect_replicas" {
  description = "Initial Connect worker count. Set to 0 so Connect does not start until databases are seeded. Scale up with: ./cdc.sh connect cdc 2"
  type        = number
  default     = 0
}
