<#
.SYNOPSIS
Deploys the local race-instrumentation candidate without removing the installed rollback DLLs.

.DESCRIPTION
This script is intended to be launched from an elevated PowerShell process. It
stops ChromeDllInjector, copies the current Release injector files, installs the
instrumented native DLL under a new filename, verifies hashes, and always tries
to restart the scheduled task before returning.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\Program Files\Ceiridge\ChromeDllInjector',
    [string]$DllFileName = 'ChromePatcherDll_20260820_711a.dll',
    [string]$ResultPath,
    [switch]$SkipNativeDll
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$injectorOutput = Join-Path $repoRoot 'ChromeDllInjector\bin\Release\net6.0-windows10.0.17763.0'
$sourceDll = Join-Path $repoRoot 'ChromePatcherDll\x64\Release\ChromePatcherDll.dll'
if (-not $ResultPath) {
    $ResultPath = Join-Path $repoRoot 'outputs\phaseab-deploy-result.json'
}
$resultDirectory = Split-Path -Parent $ResultPath
if ($resultDirectory) {
    New-Item -ItemType Directory -Force -Path $resultDirectory | Out-Null
}

$result = [ordered]@{
    started_utc = [DateTime]::UtcNow.ToString('O')
    elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    install_dir = $InstallDir
    candidate_dll = (Join-Path $InstallDir $DllFileName)
    injector_dll_sha256 = $null
    candidate_dll_sha256 = $null
    task_state = $null
    task_result = $null
    success = $false
    error = $null
}

try {
    if (-not $result.elevated) { throw 'An elevated administrator token is required.' }
    if (-not (Test-Path -LiteralPath $injectorOutput -PathType Container)) { throw "Missing injector output: $injectorOutput" }
    if (-not (Test-Path -LiteralPath $sourceDll -PathType Leaf)) { throw "Missing native DLL: $sourceDll" }
    if (-not (Test-Path -LiteralPath $InstallDir -PathType Container)) { throw "Missing install directory: $InstallDir" }

    Stop-ScheduledTask -TaskName 'ChromeDllInjector'
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 250
        $running = @(Get-Process -Name 'ChromeDllInjector' -ErrorAction SilentlyContinue)
    } while ($running.Count -gt 0 -and (Get-Date) -lt $deadline)
    if ($running.Count -gt 0) { throw 'ChromeDllInjector process did not stop within 15 seconds.' }

    Get-ChildItem -LiteralPath $injectorOutput -File | Copy-Item -Destination $InstallDir -Force
    $targetDll = Join-Path $InstallDir $DllFileName
    if (-not $SkipNativeDll) {
        Copy-Item -LiteralPath $sourceDll -Destination $targetDll -Force
    }

    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceDll).Hash
    $targetHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetDll).Hash
    if ($sourceHash -ne $targetHash) { throw 'The installed native DLL hash does not match the build output.' }

    $sourceInjectorHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $injectorOutput 'ChromeDllInjector.dll')).Hash
    $targetInjectorHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $InstallDir 'ChromeDllInjector.dll')).Hash
    if ($sourceInjectorHash -ne $targetInjectorHash) { throw 'The installed injector DLL hash does not match the build output.' }

    $result.injector_dll_sha256 = $targetInjectorHash
    $result.candidate_dll_sha256 = $targetHash
    $result.success = $true
} catch {
    $result.error = $_.Exception.Message
} finally {
    try {
        Start-ScheduledTask -TaskName 'ChromeDllInjector'
        Start-Sleep -Seconds 2
        $task = Get-ScheduledTask -TaskName 'ChromeDllInjector'
        $taskInfo = Get-ScheduledTaskInfo -TaskName 'ChromeDllInjector'
        $result.task_state = $task.State.ToString()
        $result.task_result = ('0x{0:X}' -f [uint32]$taskInfo.LastTaskResult)
    } catch {
        if (-not $result.error) { $result.error = $_.Exception.Message }
        $result.success = $false
    }
    $result.completed_utc = [DateTime]::UtcNow.ToString('O')
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
}

if (-not $result.success) { exit 1 }
