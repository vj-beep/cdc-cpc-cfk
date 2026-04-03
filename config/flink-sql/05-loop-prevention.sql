-- ================================================================
-- 05-loop-prevention.sql
-- Bi-directional CDC loop prevention using origin tagging.
--
-- ARCHITECTURE:
--   SQL Server ──Debezium──► Kafka ──► JDBC Sink ──► Aurora
--                                                       │
--   Aurora ──PG CDC Source──► Kafka ──► Flink ──► Kafka (reverse)
--                                       │
--                              Filter: __origin <> 'sqlserver'
--                                       │
--                              JDBC Sink ──► SQL Server (reverse)
--
-- PREREQUISITES:
--   1. Aurora sink tables have an __origin VARCHAR(20) column.
--   2. The JDBC Sink connector writing TO Aurora sets:
--        "transforms.addOrigin.type":
--          "org.apache.kafka.connect.transforms.InsertField$Value"
--        "transforms.addOrigin.static.field": "__origin"
--        "transforms.addOrigin.static.value": "sqlserver"
--   3. The PG CDC Source connector captures __origin in events.
-- ================================================================

-- Output table: only Aurora-native changes, safe to send back
CREATE TABLE IF NOT EXISTS aurora_changes_filtered (
  customer_id   INT       NOT NULL,
  first_name    STRING,
  last_name     STRING,
  email         STRING,
  phone         STRING,
  __origin      STRING,
  created_at    TIMESTAMP(3),
  updated_at    TIMESTAMP(3),
  PRIMARY KEY (customer_id) NOT ENFORCED
) WITH (
  'connector'                    = 'kafka',
  'topic'                        = 'reverse.aurora.customers',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9071',
  'key.format'                   = 'avro-confluent',
  'key.avro-confluent.url'       = 'http://schemaregistry.confluent.svc.cluster.local:8081',
  'value.format'                 = 'avro-confluent',
  'value.avro-confluent.url'     = 'http://schemaregistry.confluent.svc.cluster.local:8081',
  'changelog.mode'               = 'upsert'
);

-- Filter: pass only Aurora-native changes
-- Records tagged __origin = 'sqlserver' are echoes → drop them.
INSERT INTO aurora_changes_filtered
SELECT customer_id, first_name, last_name, email, phone,
       __origin, created_at, updated_at
FROM `sinkdb.public.customers`
WHERE __origin IS NULL
   OR __origin <> 'sqlserver';
