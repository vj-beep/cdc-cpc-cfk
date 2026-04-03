# EKS cluster + bootstrap managed node group
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = var.project_name
  cluster_version = var.eks_cluster_version

  cluster_endpoint_public_access = true

  enable_cluster_creator_admin_permissions = true

  access_entries = var.mac_iam_role_arn != "" ? {
    mac_admin = {
      principal_arn = var.mac_iam_role_arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  } : {}

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      before_compute = true
      most_recent    = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      before_compute = true
      most_recent    = true
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  vpc_id                   = var.vpc_id
  subnet_ids               = var.private_subnets
  control_plane_subnet_ids = var.intra_subnets

  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.eks_node_instance_types

      min_size     = 2
      max_size     = 4
      desired_size = 2

      labels = {
        "karpenter.sh/controller" = "true"
        "role"                    = "system"
      }

      taints = []
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = var.project_name
  }

  tags = {
    "karpenter.sh/discovery" = var.project_name
  }
}

# EBS CSI IRSA role
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.30"

  role_name             = "${var.project_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# Karpenter IAM (controller role + node role + SQS interruption queue)
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.24"

  cluster_name = module.eks.cluster_name

  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${var.project_name}-karpenter-node"

  create_pod_identity_association = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = {
    Project = var.project_name
  }
}

# Fix: iam:ListInstanceProfiles required by Karpenter but missing from module policy
resource "aws_iam_role_policy" "karpenter_list_instance_profiles" {
  name = "KarpenterListInstanceProfiles"
  role = module.karpenter.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AllowListInstanceProfiles"
      Effect   = "Allow"
      Action   = "iam:ListInstanceProfiles"
      Resource = "*"
    }]
  })
}

# Karpenter Helm release
resource "helm_release" "karpenter" {
  namespace  = "kube-system"
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  repository_username = var.ecr_public_username
  repository_password = var.ecr_public_password
  chart   = "karpenter"
  version = var.karpenter_version
  wait    = false

  values = [
    <<-YAML
    nodeSelector:
      karpenter.sh/controller: "true"
    dnsPolicy: Default
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    webhook:
      enabled: false
    YAML
  ]

  lifecycle {
    ignore_changes = [repository_password]
  }

  depends_on = [module.eks]
}

# EC2NodeClass (what nodes look like)
resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiSelectorTerms:
        - alias: al2023@latest
      role: ${var.project_name}-karpenter-node
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.project_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.project_name}
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 100Gi
            volumeType: gp3
            iops: 3000
            throughput: 125
            encrypted: true
            deleteOnTermination: true
      tags:
        karpenter.sh/discovery: ${var.project_name}
        Project: ${var.project_name}
  YAML

  depends_on = [helm_release.karpenter]
}

# NodePool — default (confluent workloads)
resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: confluent
    spec:
      template:
        metadata:
          labels:
            role: confluent
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand"]
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["m", "r"]
            - key: karpenter.k8s.aws/instance-cpu
              operator: In
              values: ["4", "8", "16"]
            - key: karpenter.k8s.aws/instance-hypervisor
              operator: In
              values: ["nitro"]
            - key: karpenter.k8s.aws/instance-generation
              operator: Gt
              values: ["4"]
      limits:
        cpu: 256
        memory: 512Gi
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 60s
      weight: 50
  YAML

  depends_on = [kubectl_manifest.karpenter_node_class]
}

# NodePool — bulk-load (NVMe instances for snapshots)
resource "kubectl_manifest" "nodepool_bulk" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: bulk-load
    spec:
      template:
        metadata:
          labels:
            workload-profile: bulk-load
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand"]
            - key: karpenter.k8s.aws/instance-hypervisor
              operator: In
              values: ["nitro"]
            - key: node.kubernetes.io/instance-type
              operator: In
              values:
                - "i3.2xlarge"
                - "i3.4xlarge"
                - "i3en.2xlarge"
                - "i3en.3xlarge"
                - "i4i.2xlarge"
                - "i4i.4xlarge"
                - "r5d.2xlarge"
                - "r5d.4xlarge"
                - "r6id.2xlarge"
                - "r6id.4xlarge"
      limits:
        cpu: 256
        memory: 1024Gi
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 120s
      weight: 10
  YAML

  depends_on = [helm_release.karpenter]
}

# NodePool — cdc-steady (balanced instances for ongoing CDC)
resource "kubectl_manifest" "nodepool_cdc" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: cdc-steady
    spec:
      template:
        metadata:
          labels:
            workload-profile: cdc-steady
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand"]
            - key: karpenter.k8s.aws/instance-hypervisor
              operator: In
              values: ["nitro"]
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["m", "r"]
            - key: karpenter.k8s.aws/instance-cpu
              operator: In
              values: ["4", "8"]
            - key: karpenter.k8s.aws/instance-generation
              operator: Gt
              values: ["4"]
      limits:
        cpu: 128
        memory: 512Gi
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 300s
      weight: 50
  YAML

  depends_on = [helm_release.karpenter]
}
