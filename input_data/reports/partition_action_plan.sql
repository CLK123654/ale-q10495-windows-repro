\set ON_ERROR_STOP on
WITH p AS (SELECT * FROM notify.retention_policy_runtime), monthly AS (
  SELECT i.partition_name,to_char(i.month_start,'YYYY-MM-DD') AS month_start,
    to_char(i.month_end,'YYYY-MM-DD') AS month_end,
    CASE WHEN i.month_start<p.detach_before THEN 'detach_archive' ELSE 'retain_index_attach' END AS action,
    i.reported_rows,
    CASE WHEN i.month_start<p.detach_before THEN 'detached' ELSE 'attached' END AS expected_parent_status,
    CASE WHEN inh.inhrelid IS NULL THEN 'detached' ELSE 'attached' END AS actual_parent_status,
    COALESCE(m.archive_bucket,'') AS archive_bucket
  FROM notify.notification_partition_inventory i CROSS JOIN p
  JOIN pg_class child ON child.relname=i.partition_name
  JOIN pg_namespace ns ON ns.oid=child.relnamespace AND ns.nspname='notify'
  LEFT JOIN pg_inherits inh ON inh.inhrelid=child.oid
  LEFT JOIN notify.notification_archive_manifest m ON m.partition_name=i.partition_name
), default_row AS (
  SELECT 'notification_events_default'::text AS partition_name,''::text AS month_start,
    ''::text AS month_end,'retain_default_route'::text AS action,0::bigint AS reported_rows,
    'attached'::text AS expected_parent_status,
    CASE WHEN inh.inhrelid IS NULL THEN 'detached' ELSE 'attached' END AS actual_parent_status,
    ''::text AS archive_bucket
  FROM pg_class child
  JOIN pg_namespace ns ON ns.oid=child.relnamespace AND ns.nspname='notify'
  LEFT JOIN pg_inherits inh ON inh.inhrelid=child.oid
  WHERE child.relname='notification_events_default'
)
SELECT * FROM monthly UNION ALL SELECT * FROM default_row ORDER BY partition_name;
