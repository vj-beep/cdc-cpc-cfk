# S3 bucket for Flink checkpoints / savepoints
resource "aws_s3_bucket" "flink_state" {
  bucket        = "${var.project_name}-flink-state-${var.aws_account_id}"
  force_destroy = false

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Component   = "flink"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flink_state" {
  bucket = aws_s3_bucket.flink_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "flink_state" {
  bucket = aws_s3_bucket.flink_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "flink_state" {
  bucket = aws_s3_bucket.flink_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM policy granting Flink pods read/write to the state bucket
resource "aws_iam_policy" "flink_s3" {
  name        = "${var.project_name}-flink-s3"
  description = "Allow Flink pods to read/write checkpoint and savepoint state"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.flink_state.arn,
          "${aws_s3_bucket.flink_state.arn}/*"
        ]
      }
    ]
  })
}

# Attach the S3 policy to Karpenter node role so Flink pods inherit it
resource "aws_iam_role_policy_attachment" "flink_s3" {
  role       = var.karpenter_node_iam_role_name
  policy_arn = aws_iam_policy.flink_s3.arn
}

# cert-manager (required by FKO for webhook TLS)
resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "project"                      = var.project_name
    }
  }

  lifecycle {
    ignore_changes = [metadata[0].labels]
  }
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = kubernetes_namespace.cert_manager.metadata[0].name
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  create_namespace = false

  set {
    name  = "installCRDs"
    value = "true"
  }
}

# Flink namespace
resource "kubernetes_namespace" "flink" {
  metadata {
    name = var.flink_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "project"                      = var.project_name
    }
  }
}

# Flink Kubernetes Operator (Confluent fork)
resource "helm_release" "flink_kubernetes_operator" {
  name       = "cp-flink-kubernetes-operator"
  namespace  = kubernetes_namespace.flink.metadata[0].name
  repository = "https://packages.confluent.io/helm"
  chart      = "flink-kubernetes-operator"
  version    = var.flink_operator_version

  set {
    name  = "watchNamespaces"
    value = "{${var.flink_namespace}}"
  }

  depends_on = [
    helm_release.cert_manager,
    kubernetes_namespace.flink,
  ]
}

# Confluent Manager for Apache Flink (CMF)
resource "helm_release" "cmf" {
  name       = "cmf"
  namespace  = kubernetes_namespace.flink.metadata[0].name
  repository = "https://packages.confluent.io/helm"
  chart      = "confluent-manager-for-apache-flink"
  version    = var.cmf_version

  set {
    name  = "cmf.sql.production"
    value = "false"
  }

  set {
    name  = "persistence.storageClassName"
    value = "gp3"
  }

  depends_on = [
    helm_release.flink_kubernetes_operator,
  ]
}
