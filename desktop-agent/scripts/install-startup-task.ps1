param(
  [string]$TaskName = "CodexMobileControlAgent",
  [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

if ($Uninstall) {
  $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($existingTask) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed startup task: $TaskName"
  } else {
    Write-Host "Startup task not found: $TaskName"
  }
  exit 0
}

$startScript = Resolve-Path (Join-Path $PSScriptRoot "start-agent.ps1")
$action = New-ScheduledTaskAction `
  -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$startScript`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -MultipleInstances IgnoreNew `
  -RestartCount 999 `
  -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit (New-TimeSpan -Days 365)

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger $trigger `
  -Settings $settings `
  -Description "Start Codex Mobile Control desktop agent when the user logs in." `
  -Force | Out-Null

Write-Host "Installed startup task: $TaskName"
Write-Host "Start script: $startScript"
