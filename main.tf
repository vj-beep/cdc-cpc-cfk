module "networking" {
  source = "./modules/networking"

  project_name = var.project_name
  vpc_cidr     = var.vpc_cidr
}

module "eks" {
  source = "./modules/eks"

  project_name            = var.project_name
  eks_cluster_version     = var.eks_cluster_version
  eks_node_instance_types = var.eks_node_instance_types
  karpenter_version       = var.karpenter_version
  mac_iam_role_arn        = var.mac_iam_role_arn
  ecr_public_username     = data.aws_ecrpublic_authorization_token.token.user_name
  ecr_public_password     = data.aws_ecrpublic_authorization_token.token.password
  vpc_id                  = module.networking.vpc_id
  private_subnets         = module.networking.private_subnets
  intra_subnets           = module.networking.intra_subnets
}

module "databases" {
  source = "./modules/databases"

  project_name               = var.project_name
  vpc_id                     = module.networking.vpc_id
  database_subnet_group_name = module.networking.database_subnet_group_name
  eks_node_security_group_id = module.eks.node_security_group_id
  my_ip                      = var.my_ip
  mac_iam_role_arn           = var.mac_iam_role_arn

  sqlserver_instance_class        = var.sqlserver_instance_class
  sqlserver_engine_version        = var.sqlserver_engine_version
  sqlserver_username              = var.sqlserver_username
  sqlserver_password              = var.sqlserver_password
  sqlserver_allocated_storage     = var.sqlserver_allocated_storage
  sqlserver_max_allocated_storage = var.sqlserver_max_allocated_storage
  sqlserver_iops                  = var.sqlserver_iops
  sqlserver_storage_throughput    = var.sqlserver_storage_throughput

  aurora_pg_engine_version = var.aurora_pg_engine_version
  aurora_pg_instance_class = var.aurora_pg_instance_class
  aurora_username          = var.aurora_username
  aurora_password          = var.aurora_password
  aurora_db_name           = var.aurora_db_name
}

module "confluent_platform" {
  source = "./modules/confluent-platform"

  project_name               = var.project_name
  cp_namespace               = var.cp_namespace
  cp_version                 = var.cp_version
  cfk_chart_version          = var.cfk_chart_version
  cfk_init_container_version = var.cfk_init_container_version
  kafka_replicas             = var.kafka_replicas
  kafka_data_volume_capacity = var.kafka_data_volume_capacity
  kafka_log_retention_hours  = var.kafka_log_retention_hours
  kafka_log_retention_bytes  = var.kafka_log_retention_bytes
  kraft_replicas             = var.kraft_replicas
  connect_replicas           = var.connect_replicas

  depends_on = [module.eks]
}

module "connectors" {
  source = "./modules/connectors"

  cp_namespace         = var.cp_namespace
  sqlserver_address    = module.databases.sqlserver_address
  sqlserver_username   = var.sqlserver_username
  sqlserver_password   = var.sqlserver_password
  aurora_endpoint      = module.databases.aurora_endpoint
  aurora_db_name       = var.aurora_db_name
  aurora_username      = var.aurora_username
  aurora_password      = var.aurora_password
  debezium_task_max    = var.debezium_task_max
  jdbc_sink_task_max   = var.jdbc_sink_task_max
  jdbc_sink_batch_size = var.jdbc_sink_batch_size
  cdc_topic_partitions = var.cdc_topic_partitions
  toxiproxy_enabled    = var.toxiproxy_enabled
  toxiproxy_latency_ms = var.toxiproxy_latency_ms
  toxiproxy_jitter_ms  = var.toxiproxy_jitter_ms

  depends_on = [module.confluent_platform]
}

module "observability" {
  source = "./modules/observability"

  cp_namespace             = var.cp_namespace
  prometheus_stack_version = var.prometheus_stack_version
  eso_version              = var.eso_version
  keda_chart_version       = var.keda_chart_version

  depends_on = [module.confluent_platform]
}

module "flink" {
  source = "./modules/flink"

  project_name                 = var.project_name
  environment                  = var.environment
  flink_namespace              = var.flink_namespace
  cert_manager_version         = var.cert_manager_version
  flink_operator_version       = var.flink_operator_version
  cmf_version                  = var.cmf_version
  aws_account_id               = data.aws_caller_identity.current.account_id
  karpenter_node_iam_role_name = module.eks.karpenter_node_iam_role_name

  depends_on = [module.eks]
}
