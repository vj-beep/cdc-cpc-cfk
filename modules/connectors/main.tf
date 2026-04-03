locals {
  kafka_bootstrap = "kafka.${var.cp_namespace}.svc.cluster.local:9071"
  sr_url          = "http://schemaregistry.${var.cp_namespace}.svc.cluster.local:8081"
  aurora_jdbc     = "jdbc:postgresql://${var.aurora_endpoint}/${var.aurora_db_name}"

  bulk_dbs = ["financedb", "retaildb", "logsdb"]

  # When toxiproxy is enabled, Debezium connects via the proxy service
  debezium_db_host = var.toxiproxy_enabled ? "toxiproxy.${var.cp_namespace}.svc.cluster.local" : var.sqlserver_address

  nopk_keys = {
    financedb = "financedb.dbo.fin_legacy_journal:source_id,event_type,event_ts"
    retaildb  = "retaildb.dbo.ret_clickstream:source_id,event_type,event_ts"
    logsdb    = "logsdb.dbo.log_raw_events:source_id,event_type,event_ts"
  }
}

# Debezium SQL Server Source (3)
resource "kubectl_manifest" "debezium_bulk" {
  for_each = toset(local.bulk_dbs)

  yaml_body = <<-YAML
    apiVersion: platform.confluent.io/v1beta1
    kind: Connector
    metadata:
      name: debezium-${each.key}
      namespace: ${var.cp_namespace}
    spec:
      class: io.debezium.connector.sqlserver.SqlServerConnector
      taskMax: ${var.debezium_task_max}
      connectClusterRef:
        name: connect
      configs:
        database.hostname: "${local.debezium_db_host}"
        database.port: "1433"
        database.user: "${var.sqlserver_username}"
        database.password: "${var.sqlserver_password}"
        database.names: "${each.key}"
        topic.prefix: "${each.key}"
        database.encrypt: "false"
        schema.history.internal.kafka.bootstrap.servers: "${local.kafka_bootstrap}"
        schema.history.internal.kafka.topic: "_sh_${each.key}"
        snapshot.mode: "initial"
        snapshot.fetch.size: "10000"
        message.key.columns: "${local.nopk_keys[each.key]}"
        binary.handling.mode: "bytes"
        column.propagate.source.type: ".*"
        max.batch.size: "4096"
        max.queue.size: "16384"
        max.queue.size.in.bytes: "67108864"
        producer.override.max.request.size: "20971520"
        producer.override.buffer.memory: "67108864"
        producer.override.batch.size: "131072"
        producer.override.linger.ms: "100"
        producer.override.compression.type: "lz4"
        heartbeat.interval.ms: "10000"
        topic.creation.default.replication.factor: "3"
        topic.creation.default.partitions: "${var.cdc_topic_partitions}"
        tombstones.on.delete: "true"
        provide.transaction.metadata: "false"
        key.converter: "io.confluent.connect.avro.AvroConverter"
        key.converter.schema.registry.url: "${local.sr_url}"
        value.converter: "io.confluent.connect.avro.AvroConverter"
        value.converter.schema.registry.url: "${local.sr_url}"
  YAML
}

# JDBC Sink — Standard (3)
resource "kubectl_manifest" "jdbc_sink_standard" {
  for_each = toset(local.bulk_dbs)

  yaml_body = <<-YAML
    apiVersion: platform.confluent.io/v1beta1
    kind: Connector
    metadata:
      name: jdbc-sink-${each.key}
      namespace: ${var.cp_namespace}
    spec:
      class: io.confluent.connect.jdbc.JdbcSinkConnector
      taskMax: ${var.jdbc_sink_task_max}
      connectClusterRef:
        name: connect
      configs:
        connection.url: "${local.aurora_jdbc}"
        connection.user: "${var.aurora_username}"
        connection.password: "${var.aurora_password}"
        topics.regex: "${each.key}[.]${each.key}[.]dbo[.].*"
        insert.mode: "upsert"
        delete.enabled: "true"
        pk.mode: "record_key"
        pk.fields: ""
        auto.create: "true"
        auto.evolve: "true"
        batch.size: "${var.jdbc_sink_batch_size}"
        key.converter: "io.confluent.connect.avro.AvroConverter"
        key.converter.schema.registry.url: "${local.sr_url}"
        value.converter: "io.confluent.connect.avro.AvroConverter"
        value.converter.schema.registry.url: "${local.sr_url}"
        transforms: "unwrap,route"
        transforms.unwrap.type: "io.debezium.transforms.ExtractNewRecordState"
        transforms.unwrap.drop.tombstones: "false"
        transforms.unwrap.delete.handling.mode: "rewrite"
        transforms.route.type: "org.apache.kafka.connect.transforms.RegexRouter"
        transforms.route.regex: "[^.]+[.](.*)[.](.*)"
        transforms.route.replacement: "$2"
        table.name.format: "${each.key}.$${topic}"
        consumer.override.auto.offset.reset: "earliest"
        consumer.override.max.poll.records: "2000"
        consumer.override.fetch.min.bytes: "1048576"
        consumer.override.fetch.max.bytes: "52428800"
  YAML
}

# Toxiproxy — on-prem latency simulation
resource "kubectl_manifest" "toxiproxy_deployment" {
  count = var.toxiproxy_enabled ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: toxiproxy
      namespace: ${var.cp_namespace}
      labels:
        app: toxiproxy
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: toxiproxy
      template:
        metadata:
          labels:
            app: toxiproxy
        spec:
          containers:
            - name: toxiproxy
              image: ghcr.io/shopify/toxiproxy:2.9.0
              ports:
                - containerPort: 8474
                  name: api
                - containerPort: 1433
                  name: mssql
              resources:
                requests:
                  cpu: "250m"
                  memory: "128Mi"
                limits:
                  cpu: "500m"
                  memory: "256Mi"
              readinessProbe:
                httpGet:
                  path: /version
                  port: 8474
                initialDelaySeconds: 3
                periodSeconds: 5
  YAML
}

resource "kubectl_manifest" "toxiproxy_service" {
  count = var.toxiproxy_enabled ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: v1
    kind: Service
    metadata:
      name: toxiproxy
      namespace: ${var.cp_namespace}
      labels:
        app: toxiproxy
    spec:
      selector:
        app: toxiproxy
      ports:
        - name: mssql
          port: 1433
          targetPort: 1433
        - name: api
          port: 8474
          targetPort: 8474
  YAML

  depends_on = [kubectl_manifest.toxiproxy_deployment]
}

resource "kubectl_manifest" "toxiproxy_config" {
  count = var.toxiproxy_enabled ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: toxiproxy-config
      namespace: ${var.cp_namespace}
    data:
      sqlserver-host: "${var.sqlserver_address}"
      sqlserver-port: "1433"
      default-latency-ms: "${var.toxiproxy_latency_ms}"
      default-jitter-ms: "${var.toxiproxy_jitter_ms}"
  YAML

  depends_on = [kubectl_manifest.toxiproxy_deployment]
}
