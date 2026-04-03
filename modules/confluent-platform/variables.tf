variable "project_name" {
  type = string
}

variable "cp_namespace" {
  type = string
}

variable "cp_version" {
  type = string
}

variable "cfk_chart_version" {
  type = string
}

variable "cfk_init_container_version" {
  type = string
}

variable "kafka_replicas" {
  type = number
}

variable "kafka_data_volume_capacity" {
  type = string
}

variable "kafka_log_retention_hours" {
  type = number
}

variable "kafka_log_retention_bytes" {
  type = number
}

variable "kraft_replicas" {
  type = number
}

variable "connect_replicas" {
  type = number
}
