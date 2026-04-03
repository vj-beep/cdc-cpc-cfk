output "flink_namespace_name" {
  value = kubernetes_namespace.flink.metadata[0].name
}

output "flink_state_bucket" {
  value = aws_s3_bucket.flink_state.bucket
}
