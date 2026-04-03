variable "project_name" {
  type = string
}

variable "eks_cluster_version" {
  type = string
}

variable "eks_node_instance_types" {
  type = list(string)
}

variable "karpenter_version" {
  type = string
}

variable "mac_iam_role_arn" {
  type    = string
  default = ""
}

variable "vpc_id" {
  type = string
}

variable "private_subnets" {
  type = list(string)
}

variable "intra_subnets" {
  type = list(string)
}

variable "ecr_public_username" {
  type = string
}

variable "ecr_public_password" {
  type      = string
  sensitive = true
}
