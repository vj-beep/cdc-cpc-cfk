-- ================================================================
-- 02-masking-dml.sql
-- DML: continuous masking jobs
-- Each INSERT INTO runs as a long-lived Flink statement.
-- ================================================================

-- --- cdcdb.dbo.customers masking ---
INSERT INTO customers_masked
SELECT
  customer_id,
  first_name,
  -- Last name: keep first char
  CONCAT(SUBSTRING(last_name, 1, 1), '***')                     AS last_name,
  -- Email: hash local part, keep domain
  CASE
    WHEN email IS NOT NULL AND POSITION('@' IN email) > 1
      THEN CONCAT(
        SUBSTRING(MD5(CAST(SUBSTRING(email, 1, POSITION('@' IN email) - 1) AS STRING)), 1, 8),
        SUBSTRING(email, POSITION('@' IN email))
      )
    ELSE 'redacted@unknown'
  END                                                             AS email,
  -- Phone: keep last 4
  CASE
    WHEN phone IS NOT NULL AND CHAR_LENGTH(phone) >= 4
      THEN CONCAT('***-', SUBSTRING(phone, CHAR_LENGTH(phone) - 3))
    ELSE '***'
  END                                                             AS phone,
  created_at,
  updated_at
FROM `cdcdb.cdcdb.dbo.customers`;

-- --- financedb.dbo.accounts masking ---
INSERT INTO accounts_masked
SELECT
  id,
  ref_id,
  CONCAT(SUBSTRING(name, 1, 3), '***')  AS name,
  category,
  amount,
  status,
  'REDACTED'                             AS description,
  metadata,
  created_at,
  updated_at
FROM `financedb.financedb.dbo.accounts`;
