-- ================================================================
-- 04-dedup-dml.sql
-- DML: continuous deduplication
--
-- Pattern: ROW_NUMBER() partitioned by PK, ordered by event time
-- descending → keep only rownum = 1 → latest event wins.
--
-- The output table uses upsert mode + log compaction on the
-- backing topic, so downstream consumers only see final state.
-- ================================================================

INSERT INTO accounts_deduped
SELECT id, ref_id, name, category, amount, status,
       description, metadata, created_at, updated_at
FROM (
  SELECT *,
    ROW_NUMBER() OVER (
      PARTITION BY id
      ORDER BY $rowtime DESC
    ) AS rownum
  FROM `financedb.financedb.dbo.accounts`
)
WHERE rownum = 1;
