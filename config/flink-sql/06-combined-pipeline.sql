-- ================================================================
-- 06-combined-pipeline.sql
-- Single Flink job: Dedup → Mask → Loop-filter → Clean topic
--
-- This is the recommended pattern for the Experian POC:
-- one job, one set of clean output topics, JDBC sinks switch
-- their topics.regex to 'clean.<db>.*'
-- ================================================================

-- Clean output table
CREATE TABLE IF NOT EXISTS customers_clean (
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
  'topic'                        = 'clean.cdcdb.dbo.customers',
  'properties.bootstrap.servers' = 'kafka.confluent.svc.cluster.local:9071',
  'key.format'                   = 'avro-confluent',
  'key.avro-confluent.url'       = 'http://schemaregistry.confluent.svc.cluster.local:8081',
  'value.format'                 = 'avro-confluent',
  'value.avro-confluent.url'     = 'http://schemaregistry.confluent.svc.cluster.local:8081',
  'changelog.mode'               = 'upsert'
);

-- Combined: dedup + mask + loop-filter
INSERT INTO customers_clean
SELECT
  customer_id,
  first_name,
  CONCAT(SUBSTRING(last_name, 1, 1), '***')  AS last_name,
  CONCAT(
    SUBSTRING(MD5(CAST(SUBSTRING(email, 1, POSITION('@' IN email) - 1) AS STRING)), 1, 8),
    SUBSTRING(email, POSITION('@' IN email))
  )                                            AS email,
  CASE
    WHEN phone IS NOT NULL AND CHAR_LENGTH(phone) >= 4
      THEN CONCAT('***-', SUBSTRING(phone, CHAR_LENGTH(phone) - 3))
    ELSE '***'
  END                                          AS phone,
  created_at,
  updated_at
FROM (
  SELECT *,
    ROW_NUMBER() OVER (
      PARTITION BY customer_id
      ORDER BY $rowtime DESC
    ) AS rn
  FROM `cdcdb.cdcdb.dbo.customers`
)
WHERE rn = 1
  AND (__origin IS NULL OR __origin <> 'aurora');
