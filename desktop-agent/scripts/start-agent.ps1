$ErrorActionPreference = "Stop"

$agentRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$repoRoot = Resolve-Path (Join-Path $agentRoot "..")
$logDir = Join-Path $env:LOCALAPPDATA "codex-mobile-control/logs"
$logPath = Join-Path $logDir "desktop-agent.log"
$restartDelaySeconds = 5

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Set-Location $repoRoot

function Add-AgentLogText {
  param([string]$Text)

  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::AppendAllText($logPath, "$Text`r`n", $encoding)
}

function Write-AgentLog {
  param([string]$Message)

  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Add-AgentLogText "[$timestamp] [watchdog] $Message"
}

$createdMutex = $false
$mutex = New-Object System.Threading.Mutex($true, "Global\CodexMobileControlAgentWatchdog", [ref]$createdMutex)
if (-not $createdMutex) {
  Write-AgentLog "another watchdog instance is already running; exiting"
  exit 0
}

Write-AgentLog "starting desktop-agent watchdog"

try {
  while ($true) {
    Write-AgentLog "launching desktop-agent"
    & npm.cmd run start --workspace desktop-agent 2>&1 | ForEach-Object {
      Add-AgentLogText $_.ToString()
    }
    $exitCode = $LASTEXITCODE
    Write-AgentLog "desktop-agent exited with code $exitCode; restarting in ${restartDelaySeconds}s"
    Start-Sleep -Seconds $restartDelaySeconds
  }
} finally {
  $mutex.ReleaseMutex() | Out-Null
  $mutex.Dispose()
}
