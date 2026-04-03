variable "project_name" {
  type = string
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "flink_namespace" {
  type = string
}

variable "cert_manager_version" {
  type = string
}

variable "flink_operator_version" {
  type = string
}

variable "cmf_version" {
  type = string
}

variable "aws_account_id" {
  type = string
}

variable "karpenter_node_iam_role_name" {
  type = string
}
