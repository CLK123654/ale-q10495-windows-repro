\set ON_ERROR_STOP on
WITH p AS (SELECT * FROM notify.retention_policy_runtime)
SELECT c.tenant_id,
  sum(c.reported_rows) FILTER (WHERE c.month_start<p.detach_before) AS archived_rows,
  sum(c.reported_rows) FILTER (WHERE c.month_start>=p.detach_before AND c.month_start<p.retain_to_exclusive) AS retained_rows,
  sum(c.reported_failed_rows) FILTER (WHERE c.month_start>=p.detach_before AND c.month_start<p.retain_to_exclusive) AS retained_failed_rows,
  to_char(max(c.month_start) FILTER (WHERE c.month_start>=p.detach_before AND c.month_start<p.retain_to_exclusive),'YYYY-MM') AS last_retained_month
FROM notify.notification_tenant_monthly_capacity c CROSS JOIN p
GROUP BY c.tenant_id ORDER BY c.tenant_id;
