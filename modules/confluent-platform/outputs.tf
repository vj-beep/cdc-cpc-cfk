output "ecr_repository_url" {
  value = aws_ecr_repository.connect.repository_url
}

output "confluent_namespace" {
  value = kubernetes_namespace.confluent.metadata[0].name
}
