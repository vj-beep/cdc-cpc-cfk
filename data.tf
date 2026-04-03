data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

# ECR Public auth token - API only available in us-east-1
data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.virginia
}
