\set ON_ERROR_STOP on
WITH p AS (SELECT * FROM notify.retention_policy_runtime),
source_rows AS (
  SELECT jsonb_object_agg(source_name,loaded_rows ORDER BY source_name) AS value
  FROM notify.notification_load_receipt
),
partition_summary AS (
  SELECT jsonb_build_object(
    'archived_partitions',(SELECT count(*) FROM notify.notification_archive_manifest),
    'retained_partitions',(SELECT count(*) FROM notify.notification_partition_inventory i,p WHERE i.month_start>=p.detach_before AND i.month_start<p.retain_to_exclusive),
    'archived_reported_rows',(SELECT coalesce(sum(reported_rows),0) FROM notify.notification_archive_manifest),
    'retained_reported_rows',(SELECT coalesce(sum(i.reported_rows),0) FROM notify.notification_partition_inventory i,p WHERE i.month_start>=p.detach_before AND i.month_start<p.retain_to_exclusive),
    'retained_failed_rows',(SELECT coalesce(sum(i.reported_failed_rows),0) FROM notify.notification_partition_inventory i,p WHERE i.month_start>=p.detach_before AND i.month_start<p.retain_to_exclusive)
  ) AS value
),
index_summary AS (
  SELECT jsonb_build_object(
    'parent_index','notification_events_delivery_state_idx',
    'parent_index_valid',coalesce((SELECT idx.indisvalid FROM pg_index idx WHERE idx.indexrelid=to_regclass('notify.notification_events_delivery_state_idx')),false),
    'child_indexes_attached',(SELECT count(*) FROM pg_inherits WHERE inhparent=to_regclass('notify.notification_events_delivery_state_idx')),
    'legacy_indexes_removed',(SELECT count(*) FROM notify.notification_index_cutover_log WHERE old_index_name<>'' AND old_index_issue<>'equivalent' AND to_regclass('notify.'||old_index_name) IS NULL)
  ) AS value
)
SELECT jsonb_pretty(jsonb_build_object(
  'database_version',current_setting('server_version'),
  'change_window',jsonb_build_object('starts_at',p.change_window_starts_at,'ends_at',p.change_window_ends_at,'write_handling',p.write_handling,'lock_timeout_ms',p.lock_timeout_ms,'statement_timeout_ms',p.statement_timeout_ms),
  'source_rows',source_rows.value,
  'partition_summary',partition_summary.value,
  'index_summary',index_summary.value,
  'delivery_rows',jsonb_build_object(
    'partition_action_plan',(SELECT count(*)+1 FROM notify.notification_partition_inventory),
    'index_handover',(SELECT count(*)+1 FROM notify.notification_partition_inventory i,p WHERE i.month_start>=p.detach_before AND i.month_start<p.retain_to_exclusive),
    'tenant_retention_audit',(SELECT count(DISTINCT tenant_id) FROM notify.notification_tenant_monthly_capacity)
  )
)) FROM p,source_rows,partition_summary,index_summary;
