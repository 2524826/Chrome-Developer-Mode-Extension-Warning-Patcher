[CmdletBinding()]
param(
    [string]$OutRoot,
    [int]$LogTailLines = 2500
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutRoot) { $OutRoot = Join-Path $repoRoot 'outputs\edge-warning-recurrence' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$incidentDir = Join-Path $OutRoot ($stamp + '-user-confirmed')
New-Item -ItemType Directory -Force -Path $incidentDir | Out-Null

function Save-Json($Value, [string]$Path, [int]$Depth = 8) {
    $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Copy-LogTail([string]$Source, [string]$Destination) {
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        Get-Content -LiteralPath $Source -Tail $LogTailLines -ErrorAction Stop |
            Set-Content -LiteralPath $Destination -Encoding UTF8
    } else {
        Set-Content -LiteralPath $Destination -Value "Log not found: $Source" -Encoding UTF8
    }
}

$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$installDir = 'C:\Program Files\Ceiridge\ChromeDllInjector'
$edgeApplication = 'C:\Program Files (x86)\Microsoft\Edge\Application'
$errors = [System.Collections.Generic.List[string]]::new()

$cimByPid = @{}
try {
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | ForEach-Object {
        $cimByPid[[int]$_.ProcessId] = $_
    }
} catch { $errors.Add('cim: ' + $_.Exception.Message) }

$edgeProcesses = foreach ($process in @(Get-Process -Name 'msedge' -ErrorAction SilentlyContinue | Sort-Object Id)) {
    $processErrors = [System.Collections.Generic.List[string]]::new()
    $modules = @()
    try {
        $modules = @($process.Modules | Where-Object {
            $_.ModuleName -ieq 'msedge.dll' -or $_.ModuleName -like 'ChromePatcherDll_*.dll'
        } | ForEach-Object {
            [pscustomobject]@{
                module_name = $_.ModuleName
                file_name = $_.FileName
                file_version = $_.FileVersionInfo.FileVersion
            }
        })
    } catch { $processErrors.Add('modules: ' + $_.Exception.Message) }

    $startUtc = $null
    try { $startUtc = $process.StartTime.ToUniversalTime().ToString('O') }
    catch { $processErrors.Add('start_time: ' + $_.Exception.Message) }

    $path = $null
    try { $path = $process.MainModule.FileName }
    catch { $processErrors.Add('path: ' + $_.Exception.Message) }

    $cim = $cimByPid[[int]$process.Id]
    [pscustomobject]@{
        pid = [int]$process.Id
        start_utc = $startUtc
        path = $path
        command_line = $(if ($cim) { [string]$cim.CommandLine } else { $null })
        is_browser_main_candidate = $(if ($cim) { [string]$cim.CommandLine -notmatch '(?:^|\s)--type=' } else { $null })
        session_id = $process.SessionId
        main_window_handle = [int64]$process.MainWindowHandle
        main_window_title = $process.MainWindowTitle
        modules = $modules
        errors = @($processErrors)
    }
}

$taskStates = foreach ($taskName in @('ChromeDllInjector', 'ChromeDevExtWarningMonitor')) {
    try {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
        [pscustomobject]@{
            task_name = $taskName
            exists = $true
            state = $task.State.ToString()
            last_task_result = ('0x{0:X}' -f [uint32]$info.LastTaskResult)
            last_run_time = $info.LastRunTime.ToUniversalTime().ToString('O')
        }
    } catch {
        [pscustomobject]@{ task_name = $taskName; exists = $false; error = $_.Exception.Message }
    }
}

$installedFiles = @()
if (Test-Path -LiteralPath $installDir -PathType Container) {
    $installedFiles = @(Get-ChildItem -LiteralPath $installDir -File | Where-Object {
        $_.Name -eq 'ChromeDllInjector.dll' -or $_.Name -like 'ChromePatcherDll_*.dll'
    } | Sort-Object LastWriteTimeUtc -Descending | ForEach-Object {
        [pscustomobject]@{
            name = $_.Name
            length = $_.Length
            last_write_utc = $_.LastWriteTimeUtc.ToString('O')
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
        }
    })
}

$edgeIdentity = @()
$edgeExe = Join-Path $edgeApplication 'msedge.exe'
if (Test-Path -LiteralPath $edgeExe -PathType Leaf) {
    $version = (Get-Item -LiteralPath $edgeExe).VersionInfo.FileVersion
    $versionDll = Join-Path (Join-Path $edgeApplication $version) 'msedge.dll'
    $edgeIdentity = [pscustomobject]@{
        exe = $edgeExe
        version = $version
        module = $versionDll
        module_exists = Test-Path -LiteralPath $versionDll -PathType Leaf
        module_sha256 = $(if (Test-Path -LiteralPath $versionDll -PathType Leaf) {
            (Get-FileHash -Algorithm SHA256 -LiteralPath $versionDll).Hash
        } else { $null })
    }
}

$event = [ordered]@{
    schema = 1
    event_kind = 'edge-developer-mode-extension-warning-user-confirmed'
    reported_capture_utc = [DateTime]::UtcNow.ToString('O')
    reported_capture_local = (Get-Date).ToString('O')
    screenshot = 'not-captured; Edge Computer Use permission was not approved'
    elevated = $elevated
    injector_install = $installedFiles
    edge_identity = $edgeIdentity
    edge_processes = @($edgeProcesses)
    scheduled_tasks = @($taskStates)
    capture_errors = @($errors)
}

Save-Json -Value $event -Path (Join-Path $incidentDir 'event.json') -Depth 12
Save-Json -Value @($edgeProcesses) -Path (Join-Path $incidentDir 'edge-processes.json') -Depth 10
Save-Json -Value @($taskStates) -Path (Join-Path $incidentDir 'task-states.json') -Depth 6
Copy-LogTail -Source "$env:WINDIR\Temp\ChromePatcherInjector.log" -Destination (Join-Path $incidentDir 'injector.log')
Copy-LogTail -Source "$env:WINDIR\Temp\ChromePatcherDll.log" -Destination (Join-Path $incidentDir 'dll.log')
Copy-LogTail -Source "$env:WINDIR\Temp\ChromePatcherDllErr.log" -Destination (Join-Path $incidentDir 'dll-error.log')

[pscustomobject]@{
    success = $true
    incident_directory = $incidentDir
    captured_utc = $event.reported_capture_utc
    edge_process_count = @($edgeProcesses).Count
    browser_main_candidates = @($edgeProcesses | Where-Object { $_.is_browser_main_candidate }).Count
    capture_errors = @($errors)
} | ConvertTo-Json -Depth 5
