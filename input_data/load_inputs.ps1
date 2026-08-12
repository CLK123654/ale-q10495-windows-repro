$ErrorActionPreference = 'Stop'
if (-not $env:NOTIFY_DATABASE_URL) { throw 'NOTIFY_DATABASE_URL未设置' }
$root = $PSScriptRoot
& psql.exe $env:NOTIFY_DATABASE_URL -X -v ON_ERROR_STOP=1 -f (Join-Path $root 'database/schema.sql')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$inventory = (Join-Path $root 'partition_inventory.csv').Replace('\','/')
$capacity = (Join-Path $root 'tenant_monthly_capacity.csv').Replace('\','/')
$events = (Join-Path $root 'notification_events.csv').Replace('\','/')
$loadSql = Join-Path $env:TEMP ('notify-load-' + [guid]::NewGuid().ToString('N') + '.sql')
@"
\set ON_ERROR_STOP on
\copy notify.notification_partition_inventory FROM '$inventory' WITH (FORMAT csv,HEADER true)
\copy notify.notification_tenant_monthly_capacity FROM '$capacity' WITH (FORMAT csv,HEADER true)
SELECT format('CREATE TABLE notify.%I PARTITION OF notify.notification_events FOR VALUES FROM (%L) TO (%L);',partition_name,month_start,month_end) FROM notify.notification_partition_inventory ORDER BY month_start \gexec
CREATE TABLE notify.notification_events_default PARTITION OF notify.notification_events DEFAULT;
\copy notify.notification_events FROM '$events' WITH (FORMAT csv,HEADER true)
INSERT INTO notify.notification_load_receipt(source_name,loaded_rows) VALUES
  ('partition_inventory',(SELECT count(*) FROM notify.notification_partition_inventory)),
  ('tenant_monthly_capacity',(SELECT count(*) FROM notify.notification_tenant_monthly_capacity)),
  ('notification_events',(SELECT count(*) FROM notify.notification_events));
CREATE INDEX notification_events_2026_04_delivery_old_idx ON notify.notification_events_2026_04 (tenant_id,sent_at DESC);
CREATE INDEX notification_events_2026_05_delivery_old_idx ON notify.notification_events_2026_05 (tenant_id,sent_at DESC) WHERE delivery_state='sent';
CREATE INDEX notification_events_2026_06_delivery_old_idx ON notify.notification_events_2026_06 (sent_at DESC,tenant_id) WHERE delivery_state IN ('sent','failed');
"@ | Set-Content -LiteralPath $loadSql -Encoding utf8
try {
  & psql.exe $env:NOTIFY_DATABASE_URL -X -v ON_ERROR_STOP=1 -f $loadSql
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  Remove-Item -LiteralPath $loadSql -Force -ErrorAction SilentlyContinue
}
