\set ON_ERROR_STOP on
SELECT set_config('lock_timeout',lock_timeout_ms::text || 'ms',false),
       set_config('statement_timeout',statement_timeout_ms::text || 'ms',false)
FROM notify.retention_policy_runtime;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM notify.notification_events_default) THEN
    RAISE EXCEPTION 'default partition contains notification events';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS notify.notification_archive_manifest (
  partition_name text PRIMARY KEY,
  month_start date NOT NULL,
  month_end date NOT NULL,
  archive_bucket text NOT NULL,
  reported_rows bigint NOT NULL,
  detached_at date NOT NULL
);

CREATE TABLE IF NOT EXISTS notify.notification_index_cutover_log (
  partition_name text PRIMARY KEY,
  new_index_name text NOT NULL,
  old_index_name text NOT NULL,
  old_index_issue text NOT NULL,
  old_index_action text NOT NULL
);

INSERT INTO notify.notification_archive_manifest
  (partition_name,month_start,month_end,archive_bucket,reported_rows,detached_at)
SELECT i.partition_name,i.month_start,i.month_end,
       p.archive_bucket_prefix || '/' || to_char(i.month_start,'MM'),
       i.reported_rows,p.run_date
FROM notify.notification_partition_inventory i
CROSS JOIN notify.retention_policy_runtime p
WHERE i.month_start<p.detach_before
ON CONFLICT(partition_name) DO UPDATE SET
  month_start=EXCLUDED.month_start,
  month_end=EXCLUDED.month_end,
  archive_bucket=EXCLUDED.archive_bucket,
  reported_rows=EXCLUDED.reported_rows,
  detached_at=EXCLUDED.detached_at;

SELECT 'ALTER TABLE notify.notification_events DETACH PARTITION notify.notification_events_default;'
WHERE EXISTS (
  SELECT 1
  FROM notify.notification_partition_inventory i
  CROSS JOIN notify.retention_policy_runtime p
  JOIN pg_class child ON child.relname=i.partition_name
  JOIN pg_namespace ns ON ns.oid=child.relnamespace AND ns.nspname='notify'
  JOIN pg_inherits inh ON inh.inhrelid=child.oid
  WHERE i.month_start<p.detach_before
)
AND EXISTS (
  SELECT 1 FROM pg_class child
  JOIN pg_namespace ns ON ns.oid=child.relnamespace AND ns.nspname='notify'
  JOIN pg_inherits inh ON inh.inhrelid=child.oid
  WHERE child.relname='notification_events_default'
) \gexec

SELECT format(
  'ALTER TABLE notify.notification_events DETACH PARTITION notify.%I CONCURRENTLY;',
  i.partition_name
)
FROM notify.notification_partition_inventory i
CROSS JOIN notify.retention_policy_runtime p
JOIN pg_class child ON child.relname=i.partition_name
JOIN pg_namespace ns ON ns.oid=child.relnamespace AND ns.nspname='notify'
JOIN pg_inherits inh ON inh.inhrelid=child.oid
WHERE i.month_start<p.detach_before
ORDER BY i.month_start \gexec

SELECT 'ALTER TABLE notify.notification_events ATTACH PARTITION notify.notification_events_default DEFAULT;'
WHERE NOT EXISTS (
  SELECT 1 FROM pg_class child
  JOIN pg_namespace ns ON ns.oid=child.relnamespace AND ns.nspname='notify'
  JOIN pg_inherits inh ON inh.inhrelid=child.oid
  WHERE child.relname='notification_events_default'
) \gexec

SELECT format(
  'CREATE INDEX CONCURRENTLY IF NOT EXISTS %I ON notify.%I (%s) WHERE delivery_state IN (%s);',
  i.partition_name || '_delivery_state_idx',i.partition_name,
  array_to_string(p.index_columns,', '),
  (SELECT string_agg(quote_literal(state),',' ORDER BY ordinal)
   FROM unnest(p.index_states) WITH ORDINALITY states(state,ordinal))
)
FROM notify.notification_partition_inventory i
CROSS JOIN notify.retention_policy_runtime p
WHERE i.month_start>=p.detach_before AND i.month_start<p.retain_to_exclusive
ORDER BY i.month_start \gexec

SELECT format(
  'CREATE INDEX CONCURRENTLY IF NOT EXISTS notification_events_default_delivery_state_idx ON notify.notification_events_default (%s) WHERE delivery_state IN (%s);',
  array_to_string(p.index_columns,', '),
  (SELECT string_agg(quote_literal(state),',' ORDER BY ordinal)
   FROM unnest(p.index_states) WITH ORDINALITY states(state,ordinal))
)
FROM notify.retention_policy_runtime p \gexec

INSERT INTO notify.notification_index_cutover_log
  (partition_name,new_index_name,old_index_name,old_index_issue,old_index_action)
SELECT i.partition_name,
       i.partition_name || '_delivery_state_idx',
       i.old_index_name,
       issue.old_index_issue,
       CASE
         WHEN issue.old_index_issue='equivalent' THEN 'retain_equivalent'
         WHEN issue.old_index_issue IN ('missing','missing_from_catalog') THEN 'create_missing'
         ELSE 'replace_catalog_mismatch'
       END
FROM notify.notification_partition_inventory i
CROSS JOIN notify.retention_policy_runtime p
LEFT JOIN pg_index old ON old.indexrelid=to_regclass('notify.'||nullif(i.old_index_name,''))
JOIN pg_index fresh ON fresh.indexrelid=to_regclass('notify.'||i.partition_name||'_delivery_state_idx')
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN i.old_index_name='' THEN 'missing'
    WHEN old.indexrelid IS NULL THEN 'missing_from_catalog'
    WHEN old.indkey::text<>fresh.indkey::text OR old.indoption::text<>fresh.indoption::text THEN 'wrong_column_order'
    WHEN old.indpred IS NULL THEN 'unfiltered'
    WHEN old.indpred::text<>fresh.indpred::text THEN 'state_scope_mismatch'
    ELSE 'equivalent'
  END AS old_index_issue
) issue
WHERE i.month_start>=p.detach_before AND i.month_start<p.retain_to_exclusive
ON CONFLICT(partition_name) DO UPDATE SET
  new_index_name=EXCLUDED.new_index_name,
  old_index_name=EXCLUDED.old_index_name,
  old_index_issue=EXCLUDED.old_index_issue,
  old_index_action=EXCLUDED.old_index_action;

SELECT format(
  'CREATE INDEX IF NOT EXISTS notification_events_delivery_state_idx ON ONLY notify.notification_events (%s) WHERE delivery_state IN (%s);',
  array_to_string(p.index_columns,', '),
  (SELECT string_agg(quote_literal(state),',' ORDER BY ordinal)
   FROM unnest(p.index_states) WITH ORDINALITY states(state,ordinal))
)
FROM notify.retention_policy_runtime p \gexec

WITH expected AS (
  SELECT i.partition_name,i.partition_name || '_delivery_state_idx' AS index_name
  FROM notify.notification_partition_inventory i
  CROSS JOIN notify.retention_policy_runtime p
  WHERE i.month_start>=p.detach_before AND i.month_start<p.retain_to_exclusive
  UNION ALL
  SELECT 'notification_events_default','notification_events_default_delivery_state_idx'
)
SELECT format(
  'ALTER INDEX notify.notification_events_delivery_state_idx ATTACH PARTITION notify.%I;',
  e.index_name
)
FROM expected e
JOIN pg_class child_idx ON child_idx.relname=e.index_name
JOIN pg_namespace ns ON ns.oid=child_idx.relnamespace AND ns.nspname='notify'
WHERE NOT EXISTS (SELECT 1 FROM pg_inherits inh WHERE inh.inhrelid=child_idx.oid)
ORDER BY e.partition_name \gexec

SELECT format('DROP INDEX CONCURRENTLY IF EXISTS notify.%I;',l.old_index_name)
FROM notify.notification_index_cutover_log l
JOIN pg_class parent_idx ON parent_idx.relname='notification_events_delivery_state_idx'
JOIN pg_namespace parent_ns ON parent_ns.oid=parent_idx.relnamespace AND parent_ns.nspname='notify'
JOIN pg_index parent_state ON parent_state.indexrelid=parent_idx.oid AND parent_state.indisvalid
WHERE l.old_index_name<>''
  AND l.old_index_issue<>'equivalent'
  AND NOT EXISTS (
    SELECT 1 FROM (
      SELECT i.partition_name FROM notify.notification_partition_inventory i
      CROSS JOIN notify.retention_policy_runtime p
      WHERE i.month_start>=p.detach_before AND i.month_start<p.retain_to_exclusive
      UNION ALL SELECT 'notification_events_default'
    ) expected
    LEFT JOIN pg_class child_idx ON child_idx.relname=expected.partition_name || '_delivery_state_idx'
    LEFT JOIN pg_namespace child_ns ON child_ns.oid=child_idx.relnamespace AND child_ns.nspname='notify'
    LEFT JOIN pg_index child_state ON child_state.indexrelid=child_idx.oid
    LEFT JOIN pg_inherits inh ON inh.inhrelid=child_idx.oid AND inh.inhparent=parent_idx.oid
    WHERE child_state.indisvalid IS DISTINCT FROM true OR inh.inhrelid IS NULL
  )
ORDER BY l.partition_name \gexec
