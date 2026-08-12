$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$evidenceRoot = Join-Path $repo 'evidence'
$tempRoot = Join-Path $env:RUNNER_TEMP '通知中心 最终检查'
$referenceRoot = Join-Path $tempRoot '标准业务结果'
$inputArchive = Join-Path $repo '输入数据包.zip'
$candidate = Join-Path $repo 'candidate/repair_notification_partitions.sql'
$referenceArchive = Join-Path $repo 'reference.zip'
$sourceNames = @('retention_policy.json','partition_inventory.csv','tenant_monthly_capacity.csv','notification_events.csv','database/schema.sql')

Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $evidenceRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $tempRoot,$evidenceRoot,$referenceRoot | Out-Null
Expand-Archive -LiteralPath $referenceArchive -DestinationPath $referenceRoot

function Get-RelativeHashes([string]$root,[string]$subtree) {
  $base = Join-Path $root $subtree
  $map = [ordered]@{}
  Get-ChildItem -LiteralPath $base -File -Recurse | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($base.Length + 1).Replace('\','/')
    $map[$relative] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  return $map
}

function Assert-HashMapsEqual($actual,$expected,[string]$label) {
  $actualJson = $actual | ConvertTo-Json -Compress
  $expectedJson = $expected | ConvertTo-Json -Compress
  if ($actualJson -ne $expectedJson) { throw "$label文件树或内容不一致" }
}

function Get-SourceHashes([string]$inputRoot) {
  $map = [ordered]@{}
  foreach ($name in $sourceNames) {
    $path = Join-Path $inputRoot $name
    $map[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  return $map
}

function Set-Crlf([string]$path) {
  $text = [IO.File]::ReadAllText($path)
  $text = $text -replace "`r?`n","`r`n"
  if (-not $text.EndsWith("`r`n")) { $text += "`r`n" }
  [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false))
}

function Invoke-Task([string]$directory,[string]$databaseName,[string]$mode) {
  New-Item -ItemType Directory -Force $directory | Out-Null
  Expand-Archive -LiteralPath $inputArchive -DestinationPath $directory
  $inputRoot = Join-Path $directory 'input_data'
  Copy-Item -LiteralPath $candidate -Destination (Join-Path $inputRoot 'starter/repair_notification_partitions.sql') -Force
  if ($mode -eq 'crlf') {
    foreach ($name in @('partition_inventory.csv','tenant_monthly_capacity.csv','notification_events.csv')) { Set-Crlf (Join-Path $inputRoot $name) }
  }
  if ($mode -eq 'valid_change') {
    $policyPath = Join-Path $inputRoot 'retention_policy.json'
    $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
    $policy.detach_before = '2026-05-01'
    $policy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $policyPath -Encoding utf8NoBOM
  }
  if ($mode -eq 'invalid') {
    Add-Content -LiteralPath (Join-Path $inputRoot 'notification_events.csv') -Value '8001,TENANT-A,U-015,email,sent,2026-08-01T01:00:00Z,"{""sample"":true}"' -Encoding utf8NoBOM
  }
  $before = Get-SourceHashes $inputRoot
  & dropdb.exe --host localhost --username postgres --if-exists $databaseName 2>$null
  & createdb.exe --host localhost --username postgres $databaseName
  if ($LASTEXITCODE -ne 0) { throw "无法创建数据库$databaseName" }
  $env:NOTIFY_DATABASE_URL = "postgresql://postgres:root@localhost:5432/$databaseName"
  $exitCode = 0
  try {
    & pwsh.exe -NoLogo -NoProfile -File (Join-Path $inputRoot 'process.ps1')
    $exitCode = $LASTEXITCODE
    $catalog = $null
    if ($exitCode -eq 0) {
      $catalogText = & psql.exe $env:NOTIFY_DATABASE_URL -X -A -t -v ON_ERROR_STOP=1 -c "select jsonb_build_object('server_version_num',current_setting('server_version_num'),'parent_index_valid',(select indisvalid from pg_index where indexrelid=to_regclass('notify.notification_events_delivery_state_idx')),'child_indexes_attached',(select count(*) from pg_inherits where inhparent=to_regclass('notify.notification_events_delivery_state_idx')),'manifest_rows',(select count(*) from notify.notification_archive_manifest),'legacy_indexes_present',(select count(*) from notify.notification_index_cutover_log where old_index_name<>'' and old_index_issue<>'equivalent' and to_regclass('notify.'||old_index_name) is not null));"
      if ($LASTEXITCODE -ne 0) { throw 'catalog查询失败' }
      $catalog = ($catalogText -join "`n").Trim() | ConvertFrom-Json
    }
    return [ordered]@{
      directory = $directory
      input_root = $inputRoot
      output_root = Join-Path $directory 'output'
      exit_code = $exitCode
      before_hashes = $before
      after_hashes = Get-SourceHashes $inputRoot
      catalog = $catalog
    }
  } finally {
    & dropdb.exe --host localhost --username postgres --if-exists $databaseName | Out-Null
  }
}

$archiveBefore = (Get-FileHash -LiteralPath $inputArchive -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedReference = Get-RelativeHashes $referenceRoot 'output'
$cleanOne = Invoke-Task (Join-Path $tempRoot '通知中心 一区') 'notify_clean_one' 'baseline'
if ($cleanOne.exit_code -ne 0) { throw '第一个业务目录处理失败' }
Assert-HashMapsEqual (Get-RelativeHashes (Split-Path $cleanOne.output_root -Parent) 'output') $expectedReference '第一个业务目录'
Assert-HashMapsEqual $cleanOne.before_hashes $cleanOne.after_hashes '第一个业务目录输入'

$cleanTwo = Invoke-Task (Join-Path $tempRoot '通知中心 二区') 'notify_clean_two' 'crlf'
if ($cleanTwo.exit_code -ne 0) { throw '第二个业务目录处理失败' }
Assert-HashMapsEqual (Get-RelativeHashes (Split-Path $cleanTwo.output_root -Parent) 'output') $expectedReference '第二个业务目录'
Assert-HashMapsEqual $cleanTwo.before_hashes $cleanTwo.after_hashes '第二个业务目录输入'
$crlfBytes = [IO.File]::ReadAllBytes((Join-Path $cleanTwo.input_root 'partition_inventory.csv'))
$crlfText = [Text.Encoding]::UTF8.GetString($crlfBytes)
if ($crlfText -notmatch "`r`n" -or ($crlfText -replace "`r`n",'') -match "`n") { throw 'CRLF输入未生效' }

$validChange = Invoke-Task (Join-Path $tempRoot '边界 联动目录') 'notify_valid_change' 'valid_change'
if ($validChange.exit_code -ne 0) { throw '有效输入变化处理失败' }
$validSummary = Get-Content -LiteralPath (Join-Path $validChange.output_root 'reports/change_handover.json') -Raw | ConvertFrom-Json
if ($validSummary.partition_summary.archived_partitions -ne 4 -or $validSummary.partition_summary.retained_partitions -ne 3 -or $validSummary.index_summary.child_indexes_attached -ne 4 -or $validSummary.index_summary.legacy_indexes_removed -ne 2) { throw '有效输入变化未联动业务结果' }
if ((Get-FileHash -LiteralPath (Join-Path $validChange.output_root 'reports/change_handover.json') -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expectedReference['reports/change_handover.json']) { throw '有效输入变化未改变交接记录' }

$invalid = Invoke-Task (Join-Path $tempRoot '异常 输入目录') 'notify_invalid' 'invalid'
if ($invalid.exit_code -eq 0) { throw '默认分区含数据时入口仍成功' }
if (Test-Path -LiteralPath $invalid.output_root) { throw '失败入口留下业务输出' }

$archiveAfter = (Get-FileHash -LiteralPath $inputArchive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($archiveBefore -ne $archiveAfter) { throw '输入数据包发生变化' }
$attachments = [ordered]@{}
foreach ($name in @('输入数据包.zip','reference.zip','关键标准答案.xlsx','任务规格转化.xlsx')) {
  $attachments[$name] = (Get-FileHash -LiteralPath (Join-Path $repo $name) -Algorithm SHA256).Hash.ToLowerInvariant()
}
$evidence = [ordered]@{
  schema_version = 1
  result = 'PASS'
  repository = 'https://github.com/CLK123654/ale-q10495-windows-repro'
  commit = $env:GITHUB_SHA
  run_id = $env:GITHUB_RUN_ID
  runner = $env:RUNNER_OS
  psql_version = (& psql.exe --version).Trim()
  server_version_num = $cleanOne.catalog.server_version_num
  real_postgresql = $cleanOne.catalog.parent_index_valid -eq $true
  native_copy = (Select-String -LiteralPath (Join-Path $cleanOne.input_root 'load_inputs.ps1') -Pattern '\copy' -SimpleMatch).Count -ge 3
  unicode_space_directories = @($cleanOne.directory,$cleanTwo.directory)
  input_archive_unchanged = $archiveBefore -eq $archiveAfter
  input_sources_unchanged = ($cleanOne.before_hashes | ConvertTo-Json -Compress) -eq ($cleanOne.after_hashes | ConvertTo-Json -Compress)
  crlf_input_supported = $true
  reference_full_compare = $true
  reference_members = @($expectedReference.Keys)
  valid_input_change = [ordered]@{
    exit_code = $validChange.exit_code
    archived_partitions = $validSummary.partition_summary.archived_partitions
    retained_partitions = $validSummary.partition_summary.retained_partitions
    child_indexes_attached = $validSummary.index_summary.child_indexes_attached
    legacy_indexes_removed = $validSummary.index_summary.legacy_indexes_removed
  }
  invalid_input = [ordered]@{
    exit_code = $invalid.exit_code
    output_absent = -not (Test-Path -LiteralPath $invalid.output_root)
  }
  catalog = $cleanOne.catalog
  attachment_sha256 = $attachments
}
$evidencePath = Join-Path $evidenceRoot 'windows-evidence.json'
$evidence | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $evidencePath -Encoding utf8NoBOM
$evidenceHash = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
@{evidence_sha256=$evidenceHash;result='PASS'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidenceRoot 'evidence-sha256.json') -Encoding utf8NoBOM
