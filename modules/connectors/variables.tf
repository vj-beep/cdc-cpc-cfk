variable "cp_namespace" {
  type = string
}

variable "sqlserver_address" {
  type = string
}

variable "sqlserver_username" {
  type = string
}

variable "sqlserver_password" {
  type      = string
  sensitive = true
}

variable "aurora_endpoint" {
  type = string
}

variable "aurora_db_name" {
  type = string
}

variable "aurora_username" {
  type = string
}

variable "aurora_password" {
  type      = string
  sensitive = true
}

variable "debezium_task_max" {
  type = number
}

variable "jdbc_sink_task_max" {
  type = number
}

variable "jdbc_sink_batch_size" {
  type = number
}

variable "cdc_topic_partitions" {
  type = number
}

variable "toxiproxy_enabled" {
  type    = bool
  default = false
}

variable "toxiproxy_latency_ms" {
  type    = number
  default = 20
}

variable "toxiproxy_jitter_ms" {
  type    = number
  default = 5
}
