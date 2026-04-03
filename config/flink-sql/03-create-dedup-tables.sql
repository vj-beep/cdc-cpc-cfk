-- ================================================================
-- 03-create-dedup-tables.sql
-- DDL: output tables for deduplicated CDC streams
-- ================================================================

CREATE TABLE IF NOT EXISTS accounts_deduped (
  id          BIGINT    NOT NULL,
  ref_id      INT,
  name        STRING,
  category    STRING,
  amount      DECIMAL(12,2),
  status      STRING,
  description STRING,
  metadata    STRING,
  created_at  TIMESTAMP(3),
  updated_at  TIMESTAMP(3),
  PRIMARY KEY (id) NOT ENFORCED
) WITH (
  'connector'                    = 'kafka',
  'topic'                        = 'deduped.financedb.dbo.accounts',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9071',
  'key.format'                   = 'avro-confluent',
  'key.avro-confluent.url'       = 'http://schemaregistry.confluent.svc.cluster.local:8081',
  'value.format'                 = 'avro-confluent',
  'value.avro-confluent.url'     = 'http://schemaregistry.confluent.svc.cluster.local:8081',
  'changelog.mode'               = 'upsert'
);

-- Repeat for retaildb / logsdb tables as needed.
-- Pattern: topic = 'deduped.<db>.dbo.<table>'
