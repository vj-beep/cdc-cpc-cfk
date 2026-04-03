# ECR repo for custom Connect image
resource "aws_ecr_repository" "connect" {
  name                 = "${var.project_name}/cp-server-connect-custom"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "${var.project_name}-connect" }
}

resource "aws_ecr_lifecycle_policy" "connect" {
  repository = aws_ecr_repository.connect.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = {
        type = "expire"
      }
    }]
  })
}

# CFK namespace
resource "kubernetes_namespace" "confluent" {
  metadata {
    name = var.cp_namespace
  }
}

# CFK operator
resource "helm_release" "confluent_operator" {
  name             = "confluent-operator"
  namespace        = var.cp_namespace
  repository       = "https://packages.confluent.io/helm"
  chart            = "confluent-for-kubernetes"
  version          = var.cfk_chart_version
  create_namespace = false
  wait             = true
  timeout          = 600

  set {
    name  = "namespaced"
    value = "true"
  }

  depends_on = [kubernetes_namespace.confluent]
}

# gp3 StorageClass
resource "kubectl_manifest" "gp3_sc" {
  yaml_body = <<-YAML
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: gp3
    provisioner: ebs.csi.aws.com
    parameters:
      type: gp3
      fsType: ext4
    reclaimPolicy: Delete
    volumeBindingMode: WaitForFirstConsumer
    allowVolumeExpansion: true
  YAML
}

locals {
  cp_image     = "confluentinc/cp-server:${var.cp_version}"
  cp_init      = "confluentinc/confluent-init-container:${var.cfk_init_container_version}"
  connect_repo = aws_ecr_repository.connect.repository_url
}

# KRaft Controller
resource "kubectl_manifest" "kraft_controller" {
  yaml_body  = <<-YAML
    apiVersion: platform.confluent.io/v1beta1
    kind: KRaftController
    metadata:
      name: kraftcontroller
      namespace: ${var.cp_namespace}
    spec:
      replicas: ${var.kraft_replicas}
      image:
        application: ${local.cp_image}
        init: ${local.cp_init}
      dataVolumeCapacity: 50Gi
      storageClass:
        name: gp3
      configOverrides:
        server:
          - "default.replication.factor=${var.kafka_replicas}"
      podTemplate:
        resources:
          requests:
            cpu: "500m"
            memory: "2Gi"
          limits:
            cpu: "1"
            memory: "4Gi"
        topologySpreadConstraints:
          - maxSkew: 1
            topologyKey: topology.kubernetes.io/zone
            whenUnsatisfiable: DoNotSchedule
            labelSelector:
              matchLabels:
                app: kraftcontroller
  YAML
  depends_on = [helm_release.confluent_operator, kubectl_manifest.gp3_sc]
}

# Kafka
resource "kubectl_manifest" "kafka" {
  yaml_body  = <<-YAML
    apiVersion: platform.confluent.io/v1beta1
    kind: Kafka
    metadata:
      name: kafka
      namespace: ${var.cp_namespace}
    spec:
      replicas: ${var.kafka_replicas}
      image:
        application: ${local.cp_image}
        init: ${local.cp_init}
      dataVolumeCapacity: ${var.kafka_data_volume_capacity}
      storageClass:
        name: gp3
      dependencies:
        kRaftController:
          clusterRef:
            name: kraftcontroller
      configOverrides:
        server:
          - "default.replication.factor=${var.kafka_replicas}"
          - "min.insync.replicas=2"
          - "auto.create.topics.enable=true"
          - "log.retention.hours=${var.kafka_log_retention_hours}"
          - "log.retention.bytes=${var.kafka_log_retention_bytes}"
          - "log.segment.bytes=536870912"
          - "num.io.threads=16"
          - "num.network.threads=8"
      podTemplate:
        resources:
          requests:
            cpu: "1"
            memory: "4Gi"
          limits:
            cpu: "2"
            memory: "8Gi"
        topologySpreadConstraints:
          - maxSkew: 1
            topologyKey: topology.kubernetes.io/zone
            whenUnsatisfiable: ScheduleAnyway
            labelSelector:
              matchLabels:
                app: kafka
      metricReporter:
        enabled: true
  YAML
  depends_on = [kubectl_manifest.kraft_controller]
}

# Schema Registry
resource "kubectl_manifest" "schema_registry" {
  yaml_body  = <<-YAML
    apiVersion: platform.confluent.io/v1beta1
    kind: SchemaRegistry
    metadata:
      name: schemaregistry
      namespace: ${var.cp_namespace}
    spec:
      replicas: 2
      image:
        application: confluentinc/cp-schema-registry:${var.cp_version}
        init: ${local.cp_init}
      dependencies:
        kafka:
          bootstrapEndpoint: kafka.${var.cp_namespace}.svc.cluster.local:9071
      podTemplate:
        resources:
          requests:
            cpu: "250m"
            memory: "512Mi"
          limits:
            cpu: "500m"
            memory: "1Gi"
  YAML
  depends_on = [kubectl_manifest.kafka]
}

# Connect
resource "kubectl_manifest" "connect" {
  yaml_body  = <<-YAML
    apiVersion: platform.confluent.io/v1beta1
    kind: Connect
    metadata:
      name: connect
      namespace: ${var.cp_namespace}
    spec:
      replicas: ${var.connect_replicas}
      image:
        application: ${local.connect_repo}:latest
        init: ${local.cp_init}
      dependencies:
        kafka:
          bootstrapEndpoint: kafka.${var.cp_namespace}.svc.cluster.local:9071
        schemaRegistry:
          url: http://schemaregistry.${var.cp_namespace}.svc.cluster.local:8081
      configOverrides:
        server:
          - "plugin.path=/usr/share/java,/usr/share/confluent-hub-components"
          - "key.converter=io.confluent.connect.avro.AvroConverter"
          - "key.converter.schema.registry.url=http://schemaregistry.${var.cp_namespace}.svc.cluster.local:8081"
          - "value.converter=io.confluent.connect.avro.AvroConverter"
          - "value.converter.schema.registry.url=http://schemaregistry.${var.cp_namespace}.svc.cluster.local:8081"
          - "connector.client.config.override.policy=All"
      podTemplate:
        resources:
          requests:
            cpu: "2"
            memory: "6Gi"
          limits:
            cpu: "2"
            memory: "8Gi"
  YAML
  depends_on = [kubectl_manifest.kafka, kubectl_manifest.schema_registry]
}

# Control Center
resource "kubectl_manifest" "controlcenter" {
  yaml_body  = <<-YAML
    apiVersion: platform.confluent.io/v1beta1
    kind: ControlCenter
    metadata:
      name: controlcenter
      namespace: ${var.cp_namespace}
    spec:
      replicas: 1
      image:
        application: confluentinc/cp-enterprise-control-center:${var.cp_version}
        init: ${local.cp_init}
      dataVolumeCapacity: 20Gi
      storageClass:
        name: gp3
      dependencies:
        kafka:
          bootstrapEndpoint: kafka.${var.cp_namespace}.svc.cluster.local:9071
        schemaRegistry:
          url: http://schemaregistry.${var.cp_namespace}.svc.cluster.local:8081
        connect:
          - name: connect
            url: http://connect.${var.cp_namespace}.svc.cluster.local:8083
      podTemplate:
        resources:
          requests:
            cpu: "500m"
            memory: "2Gi"
          limits:
            cpu: "2"
            memory: "4Gi"
  YAML
  depends_on = [kubectl_manifest.connect]
}

# Kafka UI
resource "kubectl_manifest" "kafka_ui" {
  yaml_body  = <<-YAML
    apiVersion: v1
    kind: Pod
    metadata:
      name: kafka-ui
      namespace: ${var.cp_namespace}
      labels:
        app: kafka-ui
    spec:
      containers:
        - name: kafka-ui
          image: provectuslabs/kafka-ui:v0.7.2
          ports:
            - containerPort: 8080
          env:
            - name: KAFKA_CLUSTERS_0_NAME
              value: ${var.project_name}
            - name: KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS
              value: kafka.${var.cp_namespace}.svc.cluster.local:9071
            - name: KAFKA_CLUSTERS_0_SCHEMAREGISTRY
              value: http://schemaregistry.${var.cp_namespace}.svc.cluster.local:8081
            - name: KAFKA_CLUSTERS_0_KAFKACONNECT_0_NAME
              value: connect
            - name: KAFKA_CLUSTERS_0_KAFKACONNECT_0_ADDRESS
              value: http://connect.${var.cp_namespace}.svc.cluster.local:8083
  YAML
  depends_on = [kubectl_manifest.connect]
}

resource "kubectl_manifest" "kafka_ui_service" {
  yaml_body  = <<-YAML
    apiVersion: v1
    kind: Service
    metadata:
      name: kafka-ui
      namespace: ${var.cp_namespace}
      labels:
        app: kafka-ui
    spec:
      selector:
        app: kafka-ui
      ports:
        - port: 8080
          targetPort: 8080
  YAML
  depends_on = [kubectl_manifest.kafka_ui]
}
