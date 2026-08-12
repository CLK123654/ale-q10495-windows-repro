$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$output = Join-Path (Split-Path $root -Parent) 'output'
Remove-Item -LiteralPath $output -Recurse -Force -ErrorAction SilentlyContinue
if (-not $env:NOTIFY_DATABASE_URL) { throw 'NOTIFY_DATABASE_URL未设置' }
$policyPath = Join-Path $root 'retention_policy.json'
$candidate = Join-Path $root 'starter/repair_notification_partitions.sql'
if (-not (Test-Path -LiteralPath $policyPath)) { exit 2 }
if (-not (Test-Path -LiteralPath $candidate)) { exit 3 }
$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
& (Join-Path $root 'load_inputs.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

function SqlLiteral([string]$value) { return $value.Replace("'","''") }
$runtime = Join-Path $env:TEMP ('notify-policy-' + [guid]::NewGuid().ToString('N') + '.sql')
$columns = ($policy.index_columns | ForEach-Object { "'" + (SqlLiteral $_) + "'" }) -join ','
$states = ($policy.index_states | ForEach-Object { "'" + (SqlLiteral $_) + "'" }) -join ','
@"
INSERT INTO notify.retention_policy_runtime VALUES (
  '$(SqlLiteral $policy.policy_version)','$($policy.run_date)','$($policy.detach_before)','$($policy.retain_to_exclusive)',
  '$(SqlLiteral $policy.archive_bucket_prefix)','$($policy.change_window.starts_at)','$($policy.change_window.ends_at)',
  '$(SqlLiteral $policy.change_window.write_handling)',$($policy.lock_timeout_ms),$($policy.statement_timeout_ms),
  ARRAY[$columns],ARRAY[$states]
);
"@ | Set-Content -LiteralPath $runtime -Encoding utf8
try {
  & psql.exe $env:NOTIFY_DATABASE_URL -X -v ON_ERROR_STOP=1 -f $runtime
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & psql.exe $env:NOTIFY_DATABASE_URL -X -v ON_ERROR_STOP=1 -f $candidate
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  New-Item -ItemType Directory -Force (Join-Path $output 'sql'),(Join-Path $output 'reports') | Out-Null
  Copy-Item -LiteralPath $candidate -Destination (Join-Path $output 'sql/repair_notification_partitions.sql')
  & psql.exe $env:NOTIFY_DATABASE_URL -X -v ON_ERROR_STOP=1 --csv -o (Join-Path $output 'reports/partition_action_plan.csv') -f (Join-Path $root 'reports/partition_action_plan.sql')
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & psql.exe $env:NOTIFY_DATABASE_URL -X -v ON_ERROR_STOP=1 --csv -o (Join-Path $output 'reports/index_handover.csv') -f (Join-Path $root 'reports/index_handover.sql')
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & psql.exe $env:NOTIFY_DATABASE_URL -X -v ON_ERROR_STOP=1 --csv -o (Join-Path $output 'reports/tenant_retention_audit.csv') -f (Join-Path $root 'reports/tenant_retention_audit.sql')
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  $handover = & psql.exe $env:NOTIFY_DATABASE_URL -X -A -t -v ON_ERROR_STOP=1 -f (Join-Path $root 'reports/change_handover.sql')
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  ($handover -join "`n").Trim() + "`n" | Set-Content -LiteralPath (Join-Path $output 'reports/change_handover.json') -Encoding utf8NoBOM
} catch {
  Remove-Item -LiteralPath $output -Recurse -Force -ErrorAction SilentlyContinue
  throw
} finally {
  Remove-Item -LiteralPath $runtime -Force -ErrorAction SilentlyContinue
}
