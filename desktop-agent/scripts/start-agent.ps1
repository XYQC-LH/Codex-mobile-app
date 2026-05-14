$ErrorActionPreference = "Stop"

$agentRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$repoRoot = Resolve-Path (Join-Path $agentRoot "..")
$logDir = Join-Path $env:LOCALAPPDATA "codex-mobile-control/logs"
$logPath = Join-Path $logDir "desktop-agent.log"

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Set-Location $repoRoot

npm run start --workspace desktop-agent *> $logPath
