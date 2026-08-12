\set ON_ERROR_STOP on
WITH expected AS (
  SELECT i.partition_name,i.partition_name || '_delivery_state_idx' AS new_index_name,i.old_index_name
  FROM notify.notification_partition_inventory i CROSS JOIN notify.retention_policy_runtime p
  WHERE i.month_start>=p.detach_before AND i.month_start<p.retain_to_exclusive
  UNION ALL SELECT 'notification_events_default','notification_events_default_delivery_state_idx',''
), parent AS (
  SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='notify' AND c.relname='notification_events_delivery_state_idx'
)
SELECT e.partition_name,e.new_index_name,p.lock_timeout_ms,p.statement_timeout_ms,
  COALESCE(idx.indisvalid,false) AS index_valid,
  EXISTS(SELECT 1 FROM pg_inherits inh,parent WHERE inh.inhrelid=index_rel.oid AND inh.inhparent=parent.oid) AS parent_attached,
  COALESCE(pg_get_indexdef(idx.indexrelid),'') AS index_definition,
  COALESCE(pg_get_expr(idx.indpred,idx.indrelid),'') AS predicate_expression,
  e.old_index_name,
  COALESCE(log.old_index_issue,CASE WHEN e.old_index_name='' THEN 'missing' ELSE '' END) AS old_index_issue,
  COALESCE(log.old_index_action,CASE WHEN e.old_index_name='' THEN 'create_missing' ELSE '' END) AS old_index_action,
  CASE WHEN e.old_index_name='' THEN false ELSE to_regclass('notify.'||e.old_index_name) IS NOT NULL END AS old_index_present_after
FROM expected e
CROSS JOIN notify.retention_policy_runtime p
LEFT JOIN pg_class index_rel ON index_rel.oid=to_regclass('notify.'||e.new_index_name)
LEFT JOIN pg_index idx ON idx.indexrelid=index_rel.oid
LEFT JOIN notify.notification_index_cutover_log log ON log.partition_name=e.partition_name
ORDER BY e.partition_name;
