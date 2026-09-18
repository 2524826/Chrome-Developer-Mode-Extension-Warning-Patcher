<#
.SYNOPSIS
Passively captures diagnostics when Edge shows the developer-mode extension warning.

.DESCRIPTION
The monitor observes UI Automation for already-running Edge windows. It never
starts, stops, or modifies Edge. Each real warning appearance creates an
incident directory containing UI text, a screenshot, process/task state, Edge
module identity, and injector/DLL log tails.
#>
[CmdletBinding()]
param(
    [string]$OutDir,
    [ValidateRange(250, 10000)]
    [int]$PollMilliseconds = 2000,
    [ValidateRange(1, 20)]
    [int]$DisappearancePolls = 3,
    [ValidateRange(100, 10000)]
    [int]$LogTailLines = 2000,
    [switch]$Once,
    [switch]$SelfTest,
    [string]$InjectorLogPath = "$env:WINDIR\Temp\ChromePatcherInjector.log",
    [string]$DllLogPath = "$env:WINDIR\Temp\ChromePatcherDll.log",
    [string]$DllErrLogPath = "$env:WINDIR\Temp\ChromePatcherDllErr.log"
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $repoRoot 'outputs\edge-warning-incidents' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$monitorLog = Join-Path $OutDir 'monitor.log'
$statusPath = Join-Path $OutDir 'status.json'
$summaryPath = Join-Path $OutDir 'incidents.jsonl'
$stopPath = Join-Path $OutDir 'stop.monitor'
$startedUtc = [DateTime]::UtcNow
$incidentCount = 0
$lastError = $null
$activeWarnings = @{}
$missingWarnings = @{}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# Build Chinese terms from code points so Windows PowerShell 5.1 can read this
# UTF-8 script correctly even when the active ANSI code page is not UTF-8.
$zhDeveloperMode1 = -join ([char]0x5F00, [char]0x53D1, [char]0x4EBA, [char]0x5458, [char]0x6A21, [char]0x5F0F)
$zhDeveloperMode2 = -join ([char]0x5F00, [char]0x53D1, [char]0x8005, [char]0x6A21, [char]0x5F0F)
$zhExtension1 = -join ([char]0x6269, [char]0x5C55)
$zhExtension2 = -join ([char]0x62D3, [char]0x5C55)
$zhModePattern = '(?:' + [regex]::Escape($zhDeveloperMode1) + '|' + [regex]::Escape($zhDeveloperMode2) + ')'
$zhExtensionPattern = '(?:' + [regex]::Escape($zhExtension1) + '|' + [regex]::Escape($zhExtension2) + ')'

function Write-MonitorLog {
    param([string]$Message)
    $line = '{0} pid={1} {2}' -f [DateTime]::UtcNow.ToString('O'), $PID, $Message
    Add-Content -LiteralPath $monitorLog -Value $line -Encoding UTF8
}

function Test-WarningText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ($Text -match '(?i)(developer[ -]mode.{0,40}extensions?|extensions?.{0,40}developer[ -]mode)') { return $true }
    $chinesePattern = '(?:' + $zhModePattern + '.{0,20}' + $zhExtensionPattern + '|' +
        $zhExtensionPattern + '.{0,20}' + $zhModePattern + ')'
    if ($Text -match $chinesePattern) { return $true }
    return $false
}

function Get-EdgeProcessIds {
    return @(Get-Process -Name 'msedge' -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Id })
}

function Get-WarningHits {
    $edgeIds = @(Get-EdgeProcessIds)
    if ($edgeIds.Count -eq 0) { return @() }
    $edgeSet = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($edgeId in $edgeIds) { [void]$edgeSet.Add($edgeId) }

    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $condition = [System.Windows.Automation.Condition]::TrueCondition
    $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)
    $hits = @()
    foreach ($window in $windows) {
        try {
            $windowPid = [int]$window.Current.ProcessId
            if ($windowPid -eq 0 -or -not $edgeSet.Contains($windowPid)) { continue }

            $matched = New-Object 'System.Collections.Generic.List[object]'
            $windowName = [string]$window.Current.Name
            if (Test-WarningText -Text $windowName) {
                $matched.Add([pscustomobject]@{
                    name = $windowName
                    automation_id = [string]$window.Current.AutomationId
                    control_type = [string]$window.Current.ControlType.ProgrammaticName
                })
            }

            $elements = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
            $visited = 0
            foreach ($element in $elements) {
                $visited++
                if ($visited -gt 8000) { break }
                try {
                    $name = [string]$element.Current.Name
                    if (Test-WarningText -Text $name) {
                        $matched.Add([pscustomobject]@{
                            name = $name.Substring(0, [Math]::Min(500, $name.Length))
                            automation_id = [string]$element.Current.AutomationId
                            control_type = [string]$element.Current.ControlType.ProgrammaticName
                        })
                    }
                } catch { }
            }
            if ($matched.Count -eq 0) { continue }

            $rect = $window.Current.BoundingRectangle
            $nativeHandle = [int64]$window.Current.NativeWindowHandle
            $key = '{0}|{1}' -f $windowPid, $nativeHandle
            if ($nativeHandle -eq 0) { $key = '{0}|{1}' -f $windowPid, $windowName }
            $hits += [pscustomobject]@{
                key = $key
                pid = $windowPid
                native_window_handle = $nativeHandle
                window_title = $windowName
                bounds = [pscustomobject]@{
                    left = [double]$rect.Left
                    top = [double]$rect.Top
                    width = [double]$rect.Width
                    height = [double]$rect.Height
                }
                matches = @($matched | Select-Object -First 25)
                elements_visited = $visited
            }
        } catch { }
    }
    return @($hits)
}

function Save-Json {
    param($Value, [string]$Path, [int]$Depth = 8)
    $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Save-LogTail {
    param([string]$Source, [string]$Destination, [int]$TailLines)
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        Set-Content -LiteralPath $Destination -Value "Log not found: $Source" -Encoding UTF8
        return
    }
    $lines = @(Get-Content -LiteralPath $Source -Tail $TailLines -ErrorAction Stop)
    $lines | Set-Content -LiteralPath $Destination -Encoding UTF8
}

function Get-LogTail {
    param([string]$Source, [int]$TailLines)
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return @() }
    return @(Get-Content -LiteralPath $Source -Tail $TailLines -ErrorAction Stop)
}

function Save-WindowScreenshot {
    param($Bounds, [string]$Destination)
    if ($Bounds.width -lt 2 -or $Bounds.height -lt 2) { throw 'The warning window has no usable screen bounds.' }
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $left = [Math]::Max([int][Math]::Floor($Bounds.left), $screen.Left)
    $top = [Math]::Max([int][Math]::Floor($Bounds.top), $screen.Top)
    $right = [Math]::Min([int][Math]::Ceiling($Bounds.left + $Bounds.width), $screen.Right)
    $bottom = [Math]::Min([int][Math]::Ceiling($Bounds.top + $Bounds.height), $screen.Bottom)
    $width = $right - $left
    $height = $bottom - $top
    if ($width -lt 2 -or $height -lt 2) { throw 'The warning window is outside the virtual screen.' }
    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($left, $top, 0, 0, $bitmap.Size)
        $bitmap.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Get-EdgeModuleIdentity {
    param([int]$ProcessId)
    $process = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $ProcessId) -ErrorAction Stop
    $exePath = [string]$process.ExecutablePath
    if (-not $exePath -or -not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw 'The Edge executable path is unavailable.' }
    $exeItem = Get-Item -LiteralPath $exePath
    $version = [string]$exeItem.VersionInfo.FileVersion
    $applicationRoot = Split-Path -Parent $exePath
    $modulePath = Join-Path (Join-Path $applicationRoot $version) 'msedge.dll'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        $modulePath = Get-ChildItem -LiteralPath $applicationRoot -Directory -ErrorAction Stop |
            Where-Object { $_.Name -match '^\d+(\.\d+){3}$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'msedge.dll')) } |
            Sort-Object { [version]$_.Name } -Descending |
            Select-Object -First 1 |
            ForEach-Object { Join-Path $_.FullName 'msedge.dll' }
    }
    $module = $null
    if ($modulePath -and (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        $moduleItem = Get-Item -LiteralPath $modulePath
        $module = [pscustomobject]@{
            path = $moduleItem.FullName
            length = $moduleItem.Length
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $moduleItem.FullName).Hash
        }
    }
    return [pscustomobject]@{
        process_id = $ProcessId
        executable = $exePath
        version = $version
        command_line = [string]$process.CommandLine
        module = $module
    }
}

function Save-Incident {
    param($Hit)
    $detectedUtc = [DateTime]::UtcNow
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $incidentId = '{0}-pid{1}-{2}' -f $stamp, $Hit.pid, [guid]::NewGuid().ToString('N').Substring(0, 8)
    $incidentDir = Join-Path $OutDir $incidentId
    New-Item -ItemType Directory -Force -Path $incidentDir | Out-Null
    $captureErrors = New-Object 'System.Collections.Generic.List[string]'
    $event = [ordered]@{
        schema = 1
        incident_id = $incidentId
        event_kind = 'edge-developer-mode-extension-warning'
        detected_utc = $detectedUtc.ToString('O')
        detected_local = (Get-Date).ToString('O')
        monitor_pid = $PID
        warning = $Hit
        edge_module = $null
        capture_errors = @()
        completed_utc = $null
    }
    Save-Json -Value $event -Path (Join-Path $incidentDir 'event.json')

    try { Save-WindowScreenshot -Bounds $Hit.bounds -Destination (Join-Path $incidentDir 'warning-window.png') }
    catch { $captureErrors.Add('screenshot: ' + $_.Exception.Message) }

    try {
        $edgeProcesses = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop |
            Select-Object ProcessId, ParentProcessId, CreationDate, ExecutablePath, CommandLine)
        Save-Json -Value $edgeProcesses -Path (Join-Path $incidentDir 'edge-processes.json')
    } catch { $captureErrors.Add('processes: ' + $_.Exception.Message) }

    try { $event.edge_module = Get-EdgeModuleIdentity -ProcessId ([int]$Hit.pid) }
    catch { $captureErrors.Add('module: ' + $_.Exception.Message) }

    try {
        $task = Get-ScheduledTask -TaskName 'ChromeDllInjector' -ErrorAction Stop
        $taskInfo = Get-ScheduledTaskInfo -TaskName 'ChromeDllInjector' -ErrorAction Stop
        $lastRunTime = $null
        $nextRunTime = $null
        $taskActions = @()
        $taskPrincipal = $null
        if ($null -ne $taskInfo.LastRunTime) { $lastRunTime = $taskInfo.LastRunTime.ToString('O') }
        if ($null -ne $taskInfo.NextRunTime) { $nextRunTime = $taskInfo.NextRunTime.ToString('O') }
        if ($null -ne $task.Actions) { $taskActions = @($task.Actions | Select-Object Execute, Arguments, WorkingDirectory) }
        if ($null -ne $task.Principal) { $taskPrincipal = $task.Principal | Select-Object UserId, LogonType, RunLevel }
        $taskState = [pscustomobject]@{
            state = $task.State.ToString()
            last_run_time = $lastRunTime
            last_task_result = ('0x{0:X}' -f [uint32]$taskInfo.LastTaskResult)
            next_run_time = $nextRunTime
            actions = $taskActions
            principal = $taskPrincipal
        }
        Save-Json -Value $taskState -Path (Join-Path $incidentDir 'injector-task.json')
    } catch { $captureErrors.Add('task: ' + $_.Exception.Message) }

    try { Save-LogTail -Source $InjectorLogPath -Destination (Join-Path $incidentDir 'injector.log') -TailLines $LogTailLines }
    catch { $captureErrors.Add('injector-log: ' + $_.Exception.Message) }
    try { Save-LogTail -Source $DllLogPath -Destination (Join-Path $incidentDir 'dll.log') -TailLines $LogTailLines }
    catch { $captureErrors.Add('dll-log: ' + $_.Exception.Message) }
    try { Save-LogTail -Source $DllErrLogPath -Destination (Join-Path $incidentDir 'dll-error.log') -TailLines $LogTailLines }
    catch { $captureErrors.Add('dll-error-log: ' + $_.Exception.Message) }

    try {
        $pidPattern = '(?<!\d)pid=' + [regex]::Escape([string]$Hit.pid) + '(?!\d)'
        $injectorTail = @(Get-LogTail -Source $InjectorLogPath -TailLines $LogTailLines)
        $dllTail = @(Get-LogTail -Source $DllLogPath -TailLines $LogTailLines)
        $dllErrTail = @(Get-LogTail -Source $DllErrLogPath -TailLines $LogTailLines)
        $injectorRelated = @($injectorTail | Where-Object { $_ -match $pidPattern })
        $dllRelated = @($dllTail | Where-Object { $_ -match $pidPattern })
        $dllErrRelated = @($dllErrTail | Where-Object { $_ -match $pidPattern })
        $runIds = @($injectorRelated | ForEach-Object {
            $match = [regex]::Match($_, '(?<![A-Za-z0-9_])run_id=([^ )]+)')
            if ($match.Success) { $match.Groups[1].Value }
        } | Sort-Object -Unique)
        if ($runIds.Count -gt 0) {
            $injectorRelated = @($injectorTail | Where-Object {
                $line = $_
                @($runIds | Where-Object { $line.IndexOf(('run_id=' + $_), [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0
            })
        }
        $targetCreationUtc = $null
        try {
            $targetProcess = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f [int]$Hit.pid) -ErrorAction Stop
            if ($null -ne $targetProcess.CreationDate) { $targetCreationUtc = $targetProcess.CreationDate.ToUniversalTime() }
        } catch { }
        $nearbyInjectorLines = @()
        $nearbyDllLines = @()
        if ($null -ne $targetCreationUtc) {
            foreach ($line in $injectorTail) {
                $match = [regex]::Match($line, '(?<![A-Za-z0-9_])process_creation_utc=([^ ]+)')
                if (-not $match.Success) { continue }
                try {
                    $lineCreationUtc = [DateTimeOffset]::Parse($match.Groups[1].Value).UtcDateTime
                    if ([Math]::Abs(($lineCreationUtc - $targetCreationUtc).TotalSeconds) -le 2) { $nearbyInjectorLines += $line }
                } catch { }
            }
            foreach ($line in $dllTail) {
                $match = [regex]::Match($line, '(?<![A-Za-z0-9_])process_creation_utc=([^ ]+)')
                if (-not $match.Success) { continue }
                try {
                    $lineCreationUtc = [DateTimeOffset]::Parse($match.Groups[1].Value).UtcDateTime
                    if ([Math]::Abs(($lineCreationUtc - $targetCreationUtc).TotalSeconds) -le 2) { $nearbyDllLines += $line }
                } catch { }
            }
        }
        $correlation = [pscustomobject]@{
            warning_detected_utc = $detectedUtc.ToString('O')
            warning_pid = [int]$Hit.pid
            warning_process_creation_utc = $(if ($null -ne $targetCreationUtc) { $targetCreationUtc.ToString('O') } else { $null })
            target_injection_found = [bool]($injectorRelated.Count -gt 0)
            injector_run_ids = $runIds
            injector_lines = $injectorRelated
            dll_lines = $dllRelated
            dll_error_lines = $dllErrRelated
            nearby_injector_lines_within_2s = $nearbyInjectorLines
            nearby_dll_lines_within_2s = $nearbyDllLines
            diagnosis = $(if ($injectorRelated.Count -gt 0) { 'target-pid-correlated' } else { 'target-pid-not-found-in-captured-injector-log' })
        }
        Save-Json -Value $correlation -Path (Join-Path $incidentDir 'correlation.json') -Depth 8
    } catch { $captureErrors.Add('correlation: ' + $_.Exception.Message) }

    $event.capture_errors = @($captureErrors)
    $event.completed_utc = [DateTime]::UtcNow.ToString('O')
    Save-Json -Value $event -Path (Join-Path $incidentDir 'event.json')
    Add-Content -LiteralPath $summaryPath -Value (($event | ConvertTo-Json -Depth 8 -Compress)) -Encoding UTF8
    Write-MonitorLog ("incident={0} warning_pid={1} errors={2}" -f $incidentId, $Hit.pid, $captureErrors.Count)
    return $incidentDir
}

function Write-Status {
    param([int]$EdgeProcessCount, [int]$ActiveWarningCount, [string]$State)
    $status = [ordered]@{
        schema = 1
        state = $State
        monitor_pid = $PID
        started_utc = $startedUtc.ToString('O')
        heartbeat_utc = [DateTime]::UtcNow.ToString('O')
        elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        edge_process_count = $EdgeProcessCount
        active_warning_count = $ActiveWarningCount
        incident_count = $incidentCount
        last_error = $lastError
        output_directory = $OutDir
    }
    Save-Json -Value $status -Path $statusPath
}

if ($SelfTest) {
    $checks = [ordered]@{
        english_positive = (Test-WarningText 'Turn off extensions running in developer mode')
        chinese_positive = (Test-WarningText (-join ([char]0x5173,[char]0x95ED,[char]0x5F00,[char]0x53D1,[char]0x4EBA,[char]0x5458,[char]0x6A21,[char]0x5F0F,[char]0x6269,[char]0x5C55)))
        unrelated_negative = -not (Test-WarningText 'Developer tools')
        output_writable = $false
    }
    $probe = Join-Path $OutDir 'self-test.probe'
    Set-Content -LiteralPath $probe -Value 'ok' -Encoding ASCII
    $checks.output_writable = Test-Path -LiteralPath $probe
    Remove-Item -LiteralPath $probe -Force
    $passed = -not (@($checks.Values | Where-Object { -not $_ }).Count -gt 0)
    $result = [pscustomobject]@{ passed = $passed; checks = $checks; timestamp_utc = [DateTime]::UtcNow.ToString('O') }
    Save-Json -Value $result -Path (Join-Path $OutDir 'self-test.json')
    if (-not $passed) { exit 1 }
    exit 0
}

Write-MonitorLog ("monitor_started out_dir={0}" -f $OutDir)
$lastStatusTick = [Environment]::TickCount
try {
    while ($true) {
        if (Test-Path -LiteralPath $stopPath -PathType Leaf) {
            Write-MonitorLog 'stop_file_detected'
            break
        }
        try {
            $hits = @(Get-WarningHits)
            $current = @{}
            foreach ($hit in $hits) {
                $current[$hit.key] = $true
                $missingWarnings.Remove($hit.key)
                if (-not $activeWarnings.ContainsKey($hit.key)) {
                    $activeWarnings[$hit.key] = [DateTime]::UtcNow
                    [void](Save-Incident -Hit $hit)
                    $incidentCount++
                }
            }
            foreach ($key in @($activeWarnings.Keys)) {
                if ($current.ContainsKey($key)) { continue }
                $missing = 1
                if ($missingWarnings.ContainsKey($key)) { $missing = [int]$missingWarnings[$key] + 1 }
                $missingWarnings[$key] = $missing
                if ($missing -ge $DisappearancePolls) {
                    $activeWarnings.Remove($key)
                    $missingWarnings.Remove($key)
                    Write-MonitorLog ("warning_cleared key={0}" -f $key)
                }
            }
            $lastError = $null
        } catch {
            $lastError = $_.Exception.Message
            Write-MonitorLog ('scan_error=' + $lastError)
        }

        $nowTick = [Environment]::TickCount
        if (($nowTick - $lastStatusTick) -ge 10000 -or $nowTick -lt $lastStatusTick) {
            Write-Status -EdgeProcessCount (@(Get-EdgeProcessIds).Count) -ActiveWarningCount $activeWarnings.Count -State 'running'
            $lastStatusTick = $nowTick
        }
        if ($Once) { break }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
} finally {
    Write-Status -EdgeProcessCount (@(Get-EdgeProcessIds).Count) -ActiveWarningCount $activeWarnings.Count -State 'stopped'
    Write-MonitorLog 'monitor_stopped'
}
