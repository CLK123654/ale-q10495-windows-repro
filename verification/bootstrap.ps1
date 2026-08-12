$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$evidence = Join-Path $repo 'evidence'
$referenceBuild = Join-Path $repo 'reference-build'
$archive = Join-Path $repo '输入数据包.zip'
$workspace = Join-Path $env:RUNNER_TEMP '通知中心 业务材料'
$inputRoot = Join-Path $workspace 'input_data'
$starter = Join-Path $inputRoot 'starter/repair_notification_partitions.sql'
$candidate = Join-Path $repo 'candidate/repair_notification_partitions.sql'
$databaseName = 'notify_reference_build'
$databaseUrl = "postgresql://postgres:root@localhost:5432/$databaseName"

Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $referenceBuild -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $evidence -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $workspace,$evidence | Out-Null
Expand-Archive -LiteralPath $archive -DestinationPath $workspace
Copy-Item -LiteralPath $candidate -Destination $starter -Force

$env:NOTIFY_DATABASE_URL = $databaseUrl
& createdb.exe --host localhost --username postgres $databaseName
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
try {
  & (Join-Path $inputRoot 'process.ps1')
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  $output = Join-Path $workspace 'output'
  if (-not (Test-Path -LiteralPath $output)) { throw '业务输出不存在' }
  New-Item -ItemType Directory -Force $referenceBuild | Out-Null
  Copy-Item -LiteralPath $output -Destination (Join-Path $referenceBuild 'output') -Recurse
  $databaseVersion = (& psql.exe $databaseUrl -X -A -t -v ON_ERROR_STOP=1 -c "show server_version;").Trim()
  $psqlVersion = (& psql.exe --version).Trim()
  $summary = [ordered]@{
    result = 'PASS'
    database_version = $databaseVersion
    psql_version = $psqlVersion
    output_files = @(Get-ChildItem -LiteralPath $output -File -Recurse | ForEach-Object { $_.FullName.Substring($output.Length + 1).Replace('\','/') } | Sort-Object)
  }
  $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $evidence 'bootstrap.json') -Encoding utf8NoBOM
} finally {
  & dropdb.exe --host localhost --username postgres --if-exists $databaseName
}
