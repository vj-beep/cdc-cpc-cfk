variable "project_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "database_subnet_group_name" {
  type = string
}

variable "eks_node_security_group_id" {
  type = string
}

variable "my_ip" {
  type = string
}

variable "mac_iam_role_arn" {
  type    = string
  default = ""
}

# SQL Server
variable "sqlserver_instance_class" {
  type = string
}

variable "sqlserver_engine_version" {
  type = string
}

variable "sqlserver_username" {
  type = string
}

variable "sqlserver_password" {
  type      = string
  sensitive = true
}

variable "sqlserver_allocated_storage" {
  type = number
}

variable "sqlserver_max_allocated_storage" {
  type = number
}

variable "sqlserver_iops" {
  type = number
}

variable "sqlserver_storage_throughput" {
  type = number
}

# Aurora PostgreSQL
variable "aurora_pg_engine_version" {
  type = string
}

variable "aurora_pg_instance_class" {
  type = string
}

variable "aurora_username" {
  type = string
}

variable "aurora_password" {
  type      = string
  sensitive = true
}

variable "aurora_db_name" {
  type = string
}
