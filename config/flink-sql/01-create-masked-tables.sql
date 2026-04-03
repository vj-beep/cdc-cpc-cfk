-- ================================================================
-- 01-create-masked-tables.sql
-- DDL: output tables for masked CDC streams
-- Deploy once; DML statements reference these.
-- ================================================================

-- cdcdb.dbo.customers → masked output
CREATE TABLE IF NOT EXISTS customers_masked (
  customer_id   INT       NOT NULL,
  first_name    STRING,
  last_name     STRING,
  email         STRING,
  phone         STRING,
  created_at    TIMESTAMP(3),
  updated_at    TIMESTAMP(3),
  PRIMARY KEY (customer_id) NOT ENFORCED
) WITH (
  'connector'                    = 'kafka',
  'topic'                        = 'masked.cdcdb.dbo.customers',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9071',
  'key.format'                   = 'avro-confluent',
  'key.avro-confluent.url'       = 'http://schemaregistry.confluent.svc.cluster.local:8081',
  'value.format'                 = 'avro-confluent',
  'value.avro-confluent.url'     = 'http://schemaregistry.confluent.svc.cluster.local:8081',
  'changelog.mode'               = 'upsert'
);

-- Generic bulk table template (financedb example)
CREATE TABLE IF NOT EXISTS accounts_masked (
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
  'topic'                        = 'masked.financedb.dbo.accounts',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9071',
  'key.format'                   = 'avro-confluent',
  'key.avro-confluent.url'       = 'http://schemaregistry.confluent.svc.cluster.local:8081',
  'value.format'                 = 'avro-confluent',
  'value.avro-confluent.url'     = 'http://schemaregistry.confluent.svc.cluster.local:8081',
  'changelog.mode'               = 'upsert'
);
