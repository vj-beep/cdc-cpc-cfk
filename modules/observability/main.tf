# Prometheus + Grafana
resource "kubernetes_namespace" "monitoring" {
  metadata { name = "monitoring" }
}

resource "helm_release" "prometheus_stack" {
  name             = "kube-prometheus-stack"
  namespace        = "monitoring"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.prometheus_stack_version
  create_namespace = false
  wait             = false
  timeout          = 900
  values = [
    <<-YAML
    prometheus:
      prometheusSpec:
        serviceMonitorSelectorNilUsesHelmValues: false
        podMonitorSelectorNilUsesHelmValues: false
        retention: 7d
        storageSpec:
          volumeClaimTemplate:
            spec:
              storageClassName: gp3
              accessModes: ["ReadWriteOnce"]
              resources:
                requests:
                  storage: 50Gi
        resources:
          requests:
            cpu: 500m
            memory: 2Gi
          limits:
            cpu: "1"
            memory: 4Gi
    grafana:
      enabled: true
      adminPassword: "admin"
      service:
        type: LoadBalancer
      persistence:
        enabled: true
        storageClassName: gp3
        size: 10Gi
    alertmanager:
      enabled: true
    nodeExporter:
      enabled: true
    kubeStateMetrics:
      enabled: true
    YAML
  ]
  depends_on = [kubernetes_namespace.monitoring]
}

# External Secrets Operator
resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
  }
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  namespace        = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.eso_version
  create_namespace = false
  wait             = true
  timeout          = 300

  set {
    name  = "installCRDs"
    value = "true"
  }

  depends_on = [kubernetes_namespace.external_secrets]
}

# PodMonitors for Confluent Platform components
resource "kubectl_manifest" "podmonitor_kafka" {
  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: PodMonitor
    metadata:
      name: kafka
      namespace: ${var.cp_namespace}
      labels:
        app: kafka
    spec:
      selector:
        matchLabels:
          app: kafka
      namespaceSelector:
        matchNames:
          - ${var.cp_namespace}
      podMetricsEndpoints:
        - port: prometheus
          path: /
          interval: 15s
  YAML

  depends_on = [helm_release.prometheus_stack]
}

resource "kubectl_manifest" "podmonitor_kraft" {
  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: PodMonitor
    metadata:
      name: kraftcontroller
      namespace: ${var.cp_namespace}
      labels:
        app: kraftcontroller
    spec:
      selector:
        matchLabels:
          app: kraftcontroller
      namespaceSelector:
        matchNames:
          - ${var.cp_namespace}
      podMetricsEndpoints:
        - port: prometheus
          path: /
          interval: 15s
  YAML

  depends_on = [helm_release.prometheus_stack]
}

resource "kubectl_manifest" "podmonitor_connect" {
  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: PodMonitor
    metadata:
      name: connect
      namespace: ${var.cp_namespace}
      labels:
        app: connect
    spec:
      selector:
        matchLabels:
          app: connect
      namespaceSelector:
        matchNames:
          - ${var.cp_namespace}
      podMetricsEndpoints:
        - port: prometheus
          path: /
          interval: 15s
  YAML

  depends_on = [helm_release.prometheus_stack]
}

resource "kubectl_manifest" "podmonitor_schemaregistry" {
  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: PodMonitor
    metadata:
      name: schemaregistry
      namespace: ${var.cp_namespace}
      labels:
        app: schemaregistry
    spec:
      selector:
        matchLabels:
          app: schemaregistry
      namespaceSelector:
        matchNames:
          - ${var.cp_namespace}
      podMetricsEndpoints:
        - port: prometheus
          path: /
          interval: 15s
  YAML

  depends_on = [helm_release.prometheus_stack]
}

# KEDA
resource "kubernetes_namespace" "keda" {
  metadata { name = "keda" }
}

resource "helm_release" "keda" {
  name             = "keda"
  namespace        = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = var.keda_chart_version
  create_namespace = false
  wait             = true
  timeout          = 300
  depends_on       = [kubernetes_namespace.keda]
}

resource "kubectl_manifest" "connect_scaledobject" {
  yaml_body = <<-YAML
    apiVersion: keda.sh/v1alpha1
    kind: ScaledObject
    metadata:
      name: connect-autoscaler
      namespace: ${var.cp_namespace}
      annotations:
        autoscaling.keda.sh/paused-replicas: "0"
    spec:
      scaleTargetRef:
        kind: StatefulSet
        name: connect
      pollingInterval: 15
      cooldownPeriod: 300
      minReplicaCount: 2
      maxReplicaCount: 12
      advanced:
        horizontalPodAutoscalerConfig:
          behavior:
            scaleUp:
              stabilizationWindowSeconds: 30
              policies:
                - type: Pods
                  value: 2
                  periodSeconds: 60
            scaleDown:
              stabilizationWindowSeconds: 300
              policies:
                - type: Pods
                  value: 1
                  periodSeconds: 120
      triggers:
        - type: prometheus
          metadata:
            serverAddress: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
            metricName: connect_task_count
            query: sum(kafka_connect_connect_worker_metrics_task_count)
            threshold: "8"
            activationThreshold: "1"
        - type: prometheus
          metadata:
            serverAddress: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
            metricName: connect_consumer_lag
            query: sum(kafka_consumer_consumer_fetch_manager_metrics_records_lag{client_id=~"connector-consumer-.*"})
            threshold: "100000"
            activationThreshold: "1000"
        - type: prometheus
          metadata:
            serverAddress: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
            metricName: connect_cpu_usage
            query: avg(rate(container_cpu_usage_seconds_total{namespace="${var.cp_namespace}",pod=~"connect-.*",container="connect"}[5m])) / avg(kube_pod_container_resource_requests{namespace="${var.cp_namespace}",pod=~"connect-.*",container="connect",resource="cpu"})
            threshold: "0.7"
            activationThreshold: "0.3"
        - type: prometheus
          metadata:
            serverAddress: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
            metricName: connect_memory_usage
            query: avg(container_memory_working_set_bytes{namespace="${var.cp_namespace}",pod=~"connect-.*",container="connect"}) / avg(kube_pod_container_resource_requests{namespace="${var.cp_namespace}",pod=~"connect-.*",container="connect",resource="memory"})
            threshold: "0.75"
            activationThreshold: "0.4"
  YAML

  depends_on = [helm_release.keda, helm_release.prometheus_stack]
}
