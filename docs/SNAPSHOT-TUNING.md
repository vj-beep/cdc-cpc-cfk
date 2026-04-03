
# Snapshot Tuning Best Practices

Best practices implemented in this pipeline to minimize initial snapshot time for SQL Server -> Kafka -> Aurora PostgreSQL CDC.

---

## 1. Partition-Level Parallelism

Kafka can only assign one consumer per partition. If a topic has 1 partition, only 1 of N sink tasks can read from it.

| What | How |
|------|-----|
| Match partitions to worker count | `topic.creation.default.partitions` set to N at snapshot time |
| Expand existing topics | `kafka-topics --alter --partitions N` for all 300 data topics |
| Continuous expansion | Monitor loop re-expands every 60s to catch late-created topics |

**Key formula:** `effective parallelism = min(topic_partitions, sink_tasks, connect_workers * tasks_per_worker)`

---

## 2. Debezium Source Tuning

| Parameter | Value | Why |
|-----------|-------|-----|
| `snapshot.fetch.size` | 10,000 | Large row fetches reduce SQL Server round-trips |
| `max.batch.size` | 4,096 | Bigger event batches through the connector pipeline |
| `max.queue.size` | 16,384 | 4x batch size prevents backpressure stalls |
| `max.queue.size.in.bytes` | 64 MB | Memory-based queue cap |
| `tasks.max` | 10/connector | 3 connectors x 10 = 30 parallel table reads |
| `heartbeat.interval.ms` | 10,000 | Keeps connector alive during long snapshots |

---

## 3. Kafka Producer Overrides (Debezium -> Kafka)

| Parameter | Value | Default | Why |
|-----------|-------|---------|-----|
| `producer.override.batch.size` | 128 KB | 16 KB | 8x larger batches, fewer requests |
| `producer.override.linger.ms` | 100 | 0 | Allows batching before send |
| `producer.override.buffer.memory` | 64 MB | 32 MB | Large accumulation buffer |
| `producer.override.max.request.size` | 20 MB | 1 MB | Accommodates large messages/LOBs |
| `producer.override.compression.type` | lz4 | none | Fast compression reduces network I/O |

---

## 4. JDBC Sink Consumer Overrides (Kafka -> Sink)

| Parameter | Value | Default | Why |
|-----------|-------|---------|-----|
| `consumer.override.max.poll.records` | 2,000 | 500 | 4x more records per poll |
| `consumer.override.fetch.min.bytes` | 1 MB | 1 byte | Avoids tiny fetches, waits for full batches |
| `consumer.override.fetch.max.bytes` | 50 MB | 52 MB | Large fetch window |
| `consumer.override.auto.offset.reset` | earliest | latest | Always starts from beginning on reset |

---

## 5. JDBC Sink Batch Writes

| Parameter | Value | Why |
|-----------|-------|-----|
| `batch.size` | 10,000 | Large commits reduce Aurora round-trips |
| `insert.mode` | upsert | Idempotent writes, safe for restarts |
| `tasks.max` | Scaled to N | Matches snapshot worker count for full parallelism |

---

## 6. Aurora PostgreSQL Bulk Optimization

Applied automatically by `cdc.sh pipeline snapshot`:

| Optimization | When | Why |
|-------------|------|-----|
| Disable autovacuum on CDC tables | Before snapshot | Eliminates vacuum I/O contention during bulk inserts |
| Drop non-PK indexes | Before snapshot | Removes index maintenance overhead |
| Re-enable autovacuum | After snapshot | Restores normal operation |
| Rebuild indexes | After snapshot | Restores query performance |
| Periodic `ANALYZE` | Every 5 min during monitor | Keeps query planner stats fresh |

---

## 7. Kafka Broker Tuning (KRaft)

| Parameter | Value | Why |
|-----------|-------|-----|
| `num.io.threads` | 16 | High I/O parallelism for disk operations |
| `num.network.threads` | 8 | Handles concurrent producer/consumer connections |
| `log.segment.bytes` | 512 MB | Large segments reduce file handle churn |
| `min.insync.replicas` | 2 | Durability without excessive replication lag |
| Broker storage | 500 Gi each | Prevents disk throttling during snapshot |

---

## 8. Connect Worker Scaling

| Feature | Config | Why |
|---------|--------|-----|
| KEDA auto-scaling | 2-12 replicas | Scales with load automatically |
| Scale-up triggers | Task count (>8), consumer lag (>100K), CPU (>70%), memory (>75%) | Multiple signals for responsive scaling |
| Aggressive scale-up | +2 pods/60s | Stays ahead of demand |
| Gentle scale-down | -1 pod/120s | Avoids thrashing |
| Bulk profile | CPU 2/4, Mem 8Gi/16Gi | More resources per worker during snapshot |

---

## 9. NVMe-Optimized Infrastructure

| Feature | Config | Why |
|---------|--------|-----|
| Bulk-load NodePool | i3/i3en/i4i/r5d/r6id instances | NVMe local SSDs for fast Kafka/Connect I/O |
| Karpenter provisioning | ~60s node spin-up | Faster than Cluster Autoscaler |
| Dynamic CPU limits | `replicas * 4 + 16` | NodePool grows with worker count |

---

## 10. Pipeline Orchestration

| Practice | Why |
|----------|-----|
| Clean reset before snapshot | No stale offsets, partial state, or orphan consumer groups |
| Source row counting first | Establishes progress baseline |
| Connect started before partition expansion | Topics begin creating while we wait |
| 6-step automated pipeline | Eliminates manual errors and forgotten steps |

---

## 11. Monitoring and Bottleneck Detection

| Feature | Detail |
|---------|--------|
| 30-second progress sampling | Rate/min, remaining rows, percentage |
| Stall detection | Alert after 10 consecutive checks with no progress |
| Post-snapshot summary | Per-schema breakdown, top 20 tables, tuning recommendations |
| Auto-tuning recommendations | Worker utilization, schema imbalance, large table hotspots, batch size validation |
| Prometheus + Grafana | JMX metrics from all CP components via PodMonitors |

---

## Quick Tuning Reference

### For larger snapshots (>100 GB)

```bash
# More workers
./cdc.sh pipeline snapshot 8

# In terraform.tfvars — increase parallelism
debezium_task_max    = 20
jdbc_sink_batch_size = 20000
cdc_topic_partitions = 8
```

### For consumer lag

```
consumer.override.max.poll.records = 5000
consumer.override.fetch.min.bytes  = 5242880   # 5 MB
```

### For Aurora insert bottleneck

```
jdbc_sink_batch_size = 50000
jdbc_sink_task_max   = 16
```

### For Debezium backpressure

Keep queue/batch ratio >= 4:
```
max.queue.size = max.batch.size * 8
```
