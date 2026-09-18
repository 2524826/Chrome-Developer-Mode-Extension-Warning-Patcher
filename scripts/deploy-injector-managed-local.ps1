[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\Program Files\Ceiridge\ChromeDllInjector',
    [string]$BackupDirectory,
    [string]$ResultPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$injectorOutput = Join-Path $repoRoot 'ChromeDllInjector\bin\Release\net6.0-windows10.0.17763.0'
if (-not $BackupDirectory) {
    $BackupDirectory = Join-Path $repoRoot ('backups\installed-before-injector-managed-fix-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
if (-not $ResultPath) {
    $ResultPath = Join-Path $repoRoot 'outputs\injector-managed-fix-deploy-result.json'
}

$managedFiles = @(
    'ChromeDllInjector.deps.json',
    'ChromeDllInjector.dll',
    'ChromeDllInjector.exe',
    'ChromeDllInjector.pdb',
    'ChromeDllInjector.runtimeconfig.json'
)

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ResultPath) | Out-Null
$result = [ordered]@{
    started_utc = [DateTime]::UtcNow.ToString('O')
    elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    install_dir = $InstallDir
    backup_directory = $BackupDirectory
    source_injector_sha256 = $null
    installed_injector_sha256 = $null
    selected_native_before = $null
    selected_native_after = $null
    selected_native_sha256_before = $null
    selected_native_sha256_after = $null
    task_state = $null
    task_result = $null
    injector_pid = $null
    injector_start_utc = $null
    success = $false
    error = $null
}

try {
    if (-not $result.elevated) { throw 'An elevated administrator token is required.' }
    if (-not (Test-Path -LiteralPath $injectorOutput -PathType Container)) { throw "Missing injector output: $injectorOutput" }
    if (-not (Test-Path -LiteralPath $InstallDir -PathType Container)) { throw "Missing install directory: $InstallDir" }
    foreach ($file in $managedFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $injectorOutput $file) -PathType Leaf)) {
            throw "Missing managed build file: $file"
        }
    }

    $nativeBefore = Get-ChildItem -LiteralPath $InstallDir -File -Filter 'ChromePatcherDll_*.dll' |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $nativeBefore) { throw 'No installed native patch DLL was found.' }
    $result.selected_native_before = $nativeBefore.FullName
    $result.selected_native_sha256_before = (Get-FileHash -Algorithm SHA256 -LiteralPath $nativeBefore.FullName).Hash

    New-Item -ItemType Directory -Force -Path $BackupDirectory | Out-Null
    Get-ChildItem -LiteralPath $InstallDir -Force | Copy-Item -Destination $BackupDirectory -Recurse -Force
    Export-ScheduledTask -TaskName 'ChromeDllInjector' |
        Set-Content -LiteralPath (Join-Path $BackupDirectory 'ChromeDllInjector.task.xml') -Encoding UTF8

    $manifest = Get-ChildItem -LiteralPath $InstallDir -File | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{
            name = $_.Name
            length = $_.Length
            last_write_utc = $_.LastWriteTimeUtc.ToString('O')
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
        }
    }
    $manifest | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $BackupDirectory 'installed-files.json') -Encoding UTF8

    Stop-ScheduledTask -TaskName 'ChromeDllInjector' -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 250
        $running = @(Get-Process -Name 'ChromeDllInjector' -ErrorAction SilentlyContinue)
    } while ($running.Count -gt 0 -and (Get-Date) -lt $deadline)
    if ($running.Count -gt 0) { throw 'ChromeDllInjector process did not stop within 15 seconds.' }

    foreach ($file in $managedFiles) {
        Copy-Item -LiteralPath (Join-Path $injectorOutput $file) -Destination (Join-Path $InstallDir $file) -Force
    }

    $result.source_injector_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $injectorOutput 'ChromeDllInjector.dll')).Hash
    $result.installed_injector_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $InstallDir 'ChromeDllInjector.dll')).Hash
    if ($result.source_injector_sha256 -ne $result.installed_injector_sha256) {
        throw 'The installed Injector DLL hash does not match the build output.'
    }

    $nativeAfter = Get-ChildItem -LiteralPath $InstallDir -File -Filter 'ChromePatcherDll_*.dll' |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $result.selected_native_after = $nativeAfter.FullName
    $result.selected_native_sha256_after = (Get-FileHash -Algorithm SHA256 -LiteralPath $nativeAfter.FullName).Hash
    if ($result.selected_native_before -ne $result.selected_native_after -or
        $result.selected_native_sha256_before -ne $result.selected_native_sha256_after) {
        throw 'The selected native DLL changed during managed-only deployment.'
    }

    Start-ScheduledTask -TaskName 'ChromeDllInjector'
    Start-Sleep -Seconds 3
    $task = Get-ScheduledTask -TaskName 'ChromeDllInjector'
    $taskInfo = Get-ScheduledTaskInfo -TaskName 'ChromeDllInjector'
    $injectorProcess = Get-Process -Name 'ChromeDllInjector' -ErrorAction Stop | Select-Object -First 1
    $result.task_state = $task.State.ToString()
    $result.task_result = ('0x{0:X}' -f [uint32]$taskInfo.LastTaskResult)
    $result.injector_pid = $injectorProcess.Id
    $result.injector_start_utc = $injectorProcess.StartTime.ToUniversalTime().ToString('O')
    if ($result.task_state -ne 'Running') { throw "Injector task is not running: $($result.task_state)" }

    $result.success = $true
} catch {
    $result.error = $_.Exception.Message
    try { Start-ScheduledTask -TaskName 'ChromeDllInjector' -ErrorAction SilentlyContinue } catch { }
} finally {
    $result.completed_utc = [DateTime]::UtcNow.ToString('O')
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
}

if (-not $result.success) { exit 1 }
