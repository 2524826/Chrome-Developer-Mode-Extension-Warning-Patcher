<#
.SYNOPSIS
Registers and starts the passive Edge warning monitor for the interactive user.
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'ChromeDevExtWarningMonitor',
    [string]$OutDir,
    [string]$ResultPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$monitorScript = Join-Path $PSScriptRoot 'monitor-edge-warning.ps1'
if (-not $OutDir) { $OutDir = Join-Path $repoRoot 'outputs\edge-warning-incidents' }
if (-not $ResultPath) { $ResultPath = Join-Path $repoRoot 'outputs\edge-warning-monitor-install.json' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ResultPath) | Out-Null

$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) { throw 'An elevated administrator token is required.' }
if (-not (Test-Path -LiteralPath $monitorScript -PathType Leaf)) { throw "Monitor script not found: $monitorScript" }

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Export-ScheduledTask -TaskName $TaskName | Set-Content -LiteralPath (Join-Path $OutDir ($TaskName + '.previous.xml')) -Encoding Unicode
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

$stopPath = Join-Path $OutDir 'stop.monitor'
if (Test-Path -LiteralPath $stopPath -PathType Leaf) { Remove-Item -LiteralPath $stopPath -Force }

$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -OutDir "{1}"' -f $monitorScript, $OutDir
$action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments -WorkingDirectory $repoRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 3
$task = Get-ScheduledTask -TaskName $TaskName
$taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
$result = [pscustomobject]@{
    installed_utc = [DateTime]::UtcNow.ToString('O')
    task_name = $TaskName
    task_state = $task.State.ToString()
    last_task_result = ('0x{0:X}' -f [uint32]$taskInfo.LastTaskResult)
    monitor_script = $monitorScript
    output_directory = $OutDir
    status_path = (Join-Path $OutDir 'status.json')
}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 5
