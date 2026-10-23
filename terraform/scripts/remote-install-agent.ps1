# Windows VM 上で実行 (az vm run-command invoke 経由): Elastic Agent を (再)インストールして Fleet に登録する
# 注意: 文字列リテラルは ASCII のみ (Windows PowerShell 5.1 が ANSI として読むため)
param(
  [string]$Version,
  [string]$FleetUrl,
  [string]$Token
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 既存の Agent があれば削除
$existing = 'C:\Program Files\Elastic\Agent\elastic-agent.exe'
if (Test-Path $existing) {
  & $existing uninstall --force
  if ($LASTEXITCODE -ne 0) { throw "uninstall failed: $LASTEXITCODE" }
}

$work = Join-Path $env:TEMP ("elastic-agent-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
try {
  $name = "elastic-agent-$Version-windows-x86_64"
  $zip = Join-Path $work "agent.zip"
  Invoke-WebRequest -UseBasicParsing -Uri "https://artifacts.elastic.co/downloads/beats/elastic-agent/$name.zip" -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $work -Force
  Push-Location (Join-Path $work $name)
  & .\elastic-agent.exe install --non-interactive "--url=$FleetUrl" "--enrollment-token=$Token"
  $rc = $LASTEXITCODE
  Pop-Location
  if ($rc -ne 0) { throw "install failed: $rc" }
} finally {
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Output 'ELASTIC_AGENT_INSTALL_OK'
