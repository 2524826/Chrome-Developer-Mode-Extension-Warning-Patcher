<#
.SYNOPSIS
Deploys the compact injector runtime and removes the temporary warning monitor task.

.DESCRIPTION
Keeps the adaptive ETW flush and bounded empty-path retry in the managed injector,
selects the pre-observability native patch DLL for future injections, preserves a
complete rollback copy, and unregisters the passive warning monitor task.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\Program Files\Ceiridge\ChromeDllInjector',
    [string]$CompactDllFileName = 'ChromePatcherDll_20260820_711compact.dll',
    [string]$BackupDirectory,
    [string]$ResultPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$injectorOutput = Join-Path $repoRoot 'ChromeDllInjector\bin\Release\net6.0-windows10.0.17763.0'
$compactDllSource = Join-Path $repoRoot 'backups\installed-before-phaseab-20260820-193551\ChromePatcherDll_20260818_711.dll'
$monitorStatusPath = Join-Path $repoRoot 'outputs\edge-warning-incidents\status.json'
if (-not $BackupDirectory) {
    $BackupDirectory = Join-Path $repoRoot ('backups\installed-before-compact-runtime-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
if (-not $ResultPath) {
    $ResultPath = Join-Path $repoRoot 'outputs\compact-runtime-deploy-result.json'
}

$resultDirectory = Split-Path -Parent $ResultPath
New-Item -ItemType Directory -Force -Path $resultDirectory | Out-Null
$result = [ordered]@{
    started_utc = [DateTime]::UtcNow.ToString('O')
    elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    install_dir = $InstallDir
    backup_directory = $BackupDirectory
    injector_dll_sha256 = $null
    compact_dll = $null
    compact_dll_sha256 = $null
    selected_native_dll = $null
    monitor_task_removed = $false
    monitor_process_stopped = $false
    injector_task_state = $null
    injector_task_result = $null
    success = $false
    error = $null
}

try {
    if (-not $result.elevated) { throw 'An elevated administrator token is required.' }
    if (-not (Test-Path -LiteralPath $injectorOutput -PathType Container)) { throw "Missing injector output: $injectorOutput" }
    if (-not (Test-Path -LiteralPath $compactDllSource -PathType Leaf)) { throw "Missing compact native DLL source: $compactDllSource" }
    if (-not (Test-Path -LiteralPath $InstallDir -PathType Container)) { throw "Missing install directory: $InstallDir" }

    New-Item -ItemType Directory -Force -Path $BackupDirectory | Out-Null
    Get-ChildItem -LiteralPath $InstallDir -Force | Copy-Item -Destination $BackupDirectory -Recurse -Force
    Export-ScheduledTask -TaskName 'ChromeDllInjector' | Set-Content -LiteralPath (Join-Path $BackupDirectory 'ChromeDllInjector.task.xml') -Encoding UTF8

    $monitorTask = Get-ScheduledTask -TaskName 'ChromeDevExtWarningMonitor' -ErrorAction SilentlyContinue
    if ($monitorTask) {
        Export-ScheduledTask -TaskName 'ChromeDevExtWarningMonitor' | Set-Content -LiteralPath (Join-Path $BackupDirectory 'ChromeDevExtWarningMonitor.task.xml') -Encoding UTF8
    }

    $installedManifest = Get-ChildItem -LiteralPath $InstallDir -File | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{
            name = $_.Name
            length = $_.Length
            last_write_utc = $_.LastWriteTimeUtc.ToString('O')
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
        }
    }
    $installedManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $BackupDirectory 'installed-files.json') -Encoding UTF8

    Stop-ScheduledTask -TaskName 'ChromeDllInjector'
    $injectorDeadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 250
        $injectorProcesses = @(Get-Process -Name 'ChromeDllInjector' -ErrorAction SilentlyContinue)
    } while ($injectorProcesses.Count -gt 0 -and (Get-Date) -lt $injectorDeadline)
    if ($injectorProcesses.Count -gt 0) { throw 'ChromeDllInjector process did not stop within 15 seconds.' }

    Get-ChildItem -LiteralPath $injectorOutput -File | Copy-Item -Destination $InstallDir -Force
    $compactDllTarget = Join-Path $InstallDir $CompactDllFileName
    Copy-Item -LiteralPath $compactDllSource -Destination $compactDllTarget -Force
    (Get-Item -LiteralPath $compactDllTarget).LastWriteTimeUtc = [DateTime]::UtcNow

    $sourceInjectorHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $injectorOutput 'ChromeDllInjector.dll')).Hash
    $installedInjectorHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $InstallDir 'ChromeDllInjector.dll')).Hash
    if ($sourceInjectorHash -ne $installedInjectorHash) { throw 'The installed injector DLL hash does not match the build output.' }

    $sourceNativeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $compactDllSource).Hash
    $installedNativeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $compactDllTarget).Hash
    if ($sourceNativeHash -ne $installedNativeHash) { throw 'The installed compact native DLL hash does not match its rollback source.' }

    $selectedNative = Get-ChildItem -LiteralPath $InstallDir -File -Filter 'ChromePatcherDll_*.dll' |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($selectedNative.FullName -ne $compactDllTarget) { throw 'The compact native DLL is not the newest selectable DLL.' }

    if ($monitorTask) {
        $monitorPid = $null
        if (Test-Path -LiteralPath $monitorStatusPath) {
            try { $monitorPid = (Get-Content -LiteralPath $monitorStatusPath -Raw | ConvertFrom-Json).monitor_pid } catch { }
        }
        Stop-ScheduledTask -TaskName 'ChromeDevExtWarningMonitor' -ErrorAction SilentlyContinue
        if ($monitorPid) {
            $monitorProcess = Get-Process -Id $monitorPid -ErrorAction SilentlyContinue
            if ($monitorProcess) {
                $monitorProcess | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
                $monitorProcess = Get-Process -Id $monitorPid -ErrorAction SilentlyContinue
                if ($monitorProcess) { Stop-Process -Id $monitorPid -Force }
            }
            $result.monitor_process_stopped = -not [bool](Get-Process -Id $monitorPid -ErrorAction SilentlyContinue)
        } else {
            $result.monitor_process_stopped = $true
        }
        Unregister-ScheduledTask -TaskName 'ChromeDevExtWarningMonitor' -Confirm:$false
    } else {
        $result.monitor_process_stopped = $true
    }
    $result.monitor_task_removed = -not [bool](Get-ScheduledTask -TaskName 'ChromeDevExtWarningMonitor' -ErrorAction SilentlyContinue)

    $result.injector_dll_sha256 = $installedInjectorHash
    $result.compact_dll = $compactDllTarget
    $result.compact_dll_sha256 = $installedNativeHash
    $result.selected_native_dll = $selectedNative.FullName
    $result.success = $result.monitor_task_removed
} catch {
    $result.error = $_.Exception.Message
} finally {
    try {
        Start-ScheduledTask -TaskName 'ChromeDllInjector'
        Start-Sleep -Seconds 2
        $task = Get-ScheduledTask -TaskName 'ChromeDllInjector'
        $taskInfo = Get-ScheduledTaskInfo -TaskName 'ChromeDllInjector'
        $result.injector_task_state = $task.State.ToString()
        $result.injector_task_result = ('0x{0:X}' -f [uint32]$taskInfo.LastTaskResult)
    } catch {
        if (-not $result.error) { $result.error = $_.Exception.Message }
        $result.success = $false
    }
    $result.completed_utc = [DateTime]::UtcNow.ToString('O')
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
}

if (-not $result.success) { exit 1 }
