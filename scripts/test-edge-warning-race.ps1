<#
.SYNOPSIS
Reproduces and measures the Edge developer-mode extension warning race on
isolated profiles. Phase B of the 2026-08-20 handoff.

.DESCRIPTION
Each iteration:
  1. Creates a unique temporary --user-data-dir under $env:TEMP.
  2. Launches the configured Edge with the repository's minimal unpacked
     extension (--load-extension / --disable-extensions-except).
  3. Polls the process tree and the UI Automation tree for the developer-mode
     warning texts for a bounded detection window.
  4. Stops only the Edge processes whose command line references this run's
     profile (never touches the user's existing Edge session).
  5. Reads the injector/DLL log delta since the run started and correlates the
     records by pid / run_id.
  6. Writes per-run JSON, a summary CSV/JSON, and aggregate P50/P95/P99 stats.

The user's own Edge profile is never modified. Timing is reported relative to
the Edge process creation UTC where the patcher provides it.

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-edge-warning-race.ps1 -Runs 10
#>
[CmdletBinding()]
param(
    [int]$Runs = 10,
    [string]$EdgePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    [string]$ExtensionPath,
    [string]$OutDir,
    [ValidateRange(1, 30)]
    [int]$DetectionSeconds = 5,
    [ValidateRange(10, 1000)]
    [int]$PollMilliseconds = 25,
    [switch]$KeepProfiles,
    [switch]$NoUiDetection,
    [string]$InjectorLogPath = "$env:WINDIR\Temp\ChromePatcherInjector.log",
    [string]$DllLogPath = "$env:WINDIR\Temp\ChromePatcherDll.log",
    [string]$DllErrLogPath = "$env:WINDIR\Temp\ChromePatcherDllErr.log"
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ExtensionPath) { $ExtensionPath = Join-Path $repoRoot 'test-assets\minimal-unpacked-extension' }
if (-not $OutDir) { $OutDir = Join-Path $env:TEMP ("edge-warning-race-" + (Get-Date -Format 'yyyyMMdd-HHmmss')) }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if (-not (Test-Path -LiteralPath $EdgePath -PathType Leaf)) { throw "Edge executable not found: $EdgePath" }
if (-not (Test-Path -LiteralPath $ExtensionPath -PathType Container)) { throw "Extension directory not found: $ExtensionPath" }

# Chinese keywords are built from code points so the script stays encoding-safe
# for both Windows PowerShell 5.1 and PowerShell 7.
$kwDevModeZh1 = -join ([char]0x5F00, [char]0x53D1, [char]0x4EBA, [char]0x5458, [char]0x6A21, [char]0x5F0F)
$kwDevModeZh2 = -join ([char]0x5F00, [char]0x53D1, [char]0x8005, [char]0x6A21, [char]0x5F0F)
$keywords = @(
    'Turn off extensions in developer mode',
    'Running extensions in developer mode',
    'Extensions running in developer mode',
    'developer mode',
    $kwDevModeZh1,
    $kwDevModeZh2
)

function Get-LogSnapshot {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        return [pscustomobject]@{ Path = $Path; Exists = $true; Length = $item.Length; Readable = $true }
    } catch {
        $exists = $false
        try { $exists = Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue } catch { $exists = $false }
        return [pscustomobject]@{ Path = $Path; Exists = $exists; Length = 0; Readable = $false }
    }
}

function Read-LogDelta {
    param($Snapshot, [string[]]$Filter)
    if (-not $Snapshot -or -not $Snapshot.Readable) { return @() }
    $lines = @()
    try {
        $fs = [System.IO.File]::Open($Snapshot.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $fs.Seek($Snapshot.Length, [System.IO.SeekOrigin]::Begin) | Out-Null
            $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
            $text = $reader.ReadToEnd()
        } finally {
            $fs.Dispose()
        }
        $lines = @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } catch {
        return @()
    }
    if ($Filter.Count -eq 0) { return $lines }
    $matched = @()
    foreach ($line in $lines) {
        $hit = $false
        foreach ($term in $Filter) {
            if ($line.IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true; break }
        }
        if ($hit) { $matched += $line }
    }
    return $matched
}

function Get-RunEdgeProcesses {
    param([string]$ProfilePath)
    $matches = @()
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction Stop
        foreach ($p in $procs) {
            $cmd = $p.CommandLine
            if ($cmd -and $cmd.IndexOf($ProfilePath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $matches += $p
            }
        }
    } catch { }
    return $matches
}

function Stop-RunEdgeProcesses {
    param([string]$ProfilePath)
    $procs = @(Get-RunEdgeProcesses -ProfilePath $ProfilePath)
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { }
    }
    Start-Sleep -Milliseconds 300
    $leftover = @(Get-RunEdgeProcesses -ProfilePath $ProfilePath)
    foreach ($p in $leftover) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { }
    }
    return $procs.Count
}

function Get-KeyValueField {
    param([string]$Text, [string]$Field)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $pattern = "(?<![A-Za-z0-9_])" + [regex]::Escape($Field) + "=([^ ]*)"
    $m = [regex]::Match($Text, $pattern)
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

$detectorScript = @'
param(
    [string]$ProfilePath,
    [int]$Seconds = 5,
    [int]$PollMs = 25,
    [string]$OutFile,
    [string]$KeywordsCsv
)
$ErrorActionPreference = 'Stop'
$keywords = @($KeywordsCsv -split ';' | Where-Object { $_ })
$startedUtc = [DateTime]::UtcNow
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$records = [System.Collections.Generic.List[object]]::new()
$windowSeen = @{}
$warningSeen = @{}
$targetPidsSeen = @{}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$root = [System.Windows.Automation.AutomationElement]::RootElement
$condition = [System.Windows.Automation.Condition]::TrueCondition
$descScanInterval = 500

function Get-TargetPids {
    $ids = @()
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            $cmd = $p.CommandLine
            if ($cmd -and $cmd.IndexOf($ProfilePath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $ids += [int]$p.ProcessId
            }
        }
    } catch { }
    return $ids
}

while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    $pids = @(Get-TargetPids)
    foreach ($id in $pids) {
        if (-not $targetPidsSeen.ContainsKey($id)) {
            $targetPidsSeen[$id] = $sw.Elapsed.TotalMilliseconds
            $records.Add([pscustomobject]@{ Kind = 'pid'; Pid = $id; Ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) })
        }
    }
    $targetSet = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($id in $pids) { [void]$targetSet.Add($id) }
    try {
        $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)
        foreach ($window in $windows) {
            try {
                $pidValue = $window.Current.ProcessId
                if ($pidValue -eq 0 -or -not $targetSet.Contains($pidValue)) { continue }
                if (-not $windowSeen.ContainsKey($pidValue)) {
                    $windowSeen[$pidValue] = $sw.Elapsed.TotalMilliseconds
                    $records.Add([pscustomobject]@{ Kind = 'window'; Pid = $pidValue; Ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1); Name = (($window.Current.Name) -replace "`r?`n", ' ') })
                }
                $lastScan = 0
                if ($windowSeen.ContainsKey("desc:$pidValue")) { $lastScan = $windowSeen["desc:$pidValue"] }
                if (($sw.Elapsed.TotalMilliseconds - $lastScan) -ge $descScanInterval) {
                    $windowSeen["desc:$pidValue"] = $sw.Elapsed.TotalMilliseconds
                    $elements = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
                    $count = 0
                    foreach ($element in $elements) {
                        $count++
                        if ($count -gt 6000) { break }
                        $name = $element.Current.Name
                        if ([string]::IsNullOrWhiteSpace($name)) { continue }
                        foreach ($keyword in $keywords) {
                            if ($name.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                                if (-not $warningSeen.ContainsKey($name)) {
                                    $warningSeen[$name] = $sw.Elapsed.TotalMilliseconds
                                    $records.Add([pscustomobject]@{ Kind = 'warning'; Pid = $pidValue; Ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1); Name = $name.Substring(0, [Math]::Min(160, $name.Length)) })
                                }
                            }
                        }
                    }
                }
            } catch { }
        }
    } catch { }
    Start-Sleep -Milliseconds $PollMs
}

$warningTimes = @($records | Where-Object { $_.Kind -eq 'warning' } | ForEach-Object { $_.Ms })
$windowTimes = @($records | Where-Object { $_.Kind -eq 'window' } | ForEach-Object { $_.Ms })
$result = [pscustomobject]@{
    started_utc = $startedUtc.ToString('O')
    duration_ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    target_pids_seen = @($targetPidsSeen.Keys | ForEach-Object { [int]$_ })
    window_first_ms = $(if ($windowTimes.Count -gt 0) { [math]::Round(($windowTimes | Measure-Object -Minimum).Minimum, 1) } else { $null })
    warning_first_ms = $(if ($warningTimes.Count -gt 0) { [math]::Round(($warningTimes | Measure-Object -Minimum).Minimum, 1) } else { $null })
    warning_last_ms = $(if ($warningTimes.Count -gt 0) { [math]::Round(($warningTimes | Measure-Object -Maximum).Maximum, 1) } else { $null })
    records = @($records)
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutFile -Encoding UTF8
'@

function Invoke-UiDetector {
    param(
        [string]$ProfilePath,
        [string]$OutDir,
        [string]$RunId,
        [string[]]$Keywords,
        [int]$Seconds,
        [int]$PollMs
    )
    $detectorPath = Join-Path $OutDir "uia-detect-$RunId.ps1"
    [System.IO.File]::WriteAllText($detectorPath, $detectorScript, (New-Object System.Text.UTF8Encoding($true)))
    $detectorOut = Join-Path $OutDir "uia-$RunId.json"
    $keywordsCsv = ($Keywords -join ';')
    $pwsh = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $detectorArgs = @('-NoProfile', '-Sta', '-ExecutionPolicy', 'Bypass', '-File', $detectorPath,
        '-ProfilePath', $ProfilePath, '-Seconds', "$Seconds", '-PollMs', "$PollMs",
        '-OutFile', $detectorOut, '-KeywordsCsv', $keywordsCsv)
    & $pwsh @detectorArgs | Out-Null
    if (Test-Path -LiteralPath $detectorOut) {
        try {
            return (Get-Content -LiteralPath $detectorOut -Raw | ConvertFrom-Json)
        } catch {
            return $null
        }
    }
    return $null
}

$runObjects = @()
$runSummaries = @()

for ($i = 1; $i -le $Runs; $i++) {
    $runId = '{0:D3}' -f $i
    $profile = Join-Path $env:TEMP ("edge-warning-race-" + [guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Force -Path $profile | Out-Null

    $runObject = [ordered]@{
        run = $i
        run_id = ''
        started_utc = [DateTime]::UtcNow.ToString('O')
        profile = $profile
        launcher_pid = $null
        main_pid = $null
        main_pid_seen_ms = $null
        window_first_seen_ms = $null
        warning_present = $false
        warning_first_seen_ms = $null
        warning_last_seen_ms = $null
        automation = $null
        injector_lines = @()
        dll_lines = @()
        dll_err_lines = @()
        dll_summary = ''
        notes = @()
        cleanup_profile_removed = $false
    }

    $logInjector = Get-LogSnapshot -Path $InjectorLogPath
    $logDll = Get-LogSnapshot -Path $DllLogPath
    $logDllErr = Get-LogSnapshot -Path $DllErrLogPath
    if (-not $logInjector.Readable) { $runObject.notes += 'injector log unreadable (run elevated or copy logs before running)' }
    if (-not $logDll.Readable) { $runObject.notes += 'dll log unreadable' }
    if (-not $logDllErr.Readable) { $runObject.notes += 'dll error log unreadable' }

    $arguments = @(
        "--user-data-dir=$profile",
        "--load-extension=$ExtensionPath",
        "--disable-extensions-except=$ExtensionPath",
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-background-mode',
        '--new-window',
        'about:blank'
    )
    $argumentLine = ($arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '

    $launcher = $null
    try {
        $launcher = Start-Process -FilePath $EdgePath -ArgumentList $argumentLine -PassThru
    } catch {
        $runObject.notes += ("start failed: " + $_.Exception.Message)
    }
    if ($launcher) { $runObject.launcher_pid = $launcher.Id }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $mainPid = $null
    $mainDeadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $mainDeadline) {
        $procs = @(Get-RunEdgeProcesses -ProfilePath $profile)
        $main = @($procs | Where-Object { $_.CommandLine -notmatch '--type=' } | Select-Object -First 1)
        if ($main.Count -gt 0) {
            $mainPid = [int]$main[0].ProcessId
            break
        }
        if ($sw.Elapsed.TotalSeconds -gt 15) { break }
        Start-Sleep -Milliseconds 50
    }
    if ($mainPid) {
        $runObject.main_pid = $mainPid
        $runObject.main_pid_seen_ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    } else {
        $runObject.notes += 'no main browser process seen for this profile'
    }

    if (-not $NoUiDetection) {
        $automation = Invoke-UiDetector -ProfilePath $profile -OutDir $OutDir -RunId $runId -Keywords $keywords -Seconds $DetectionSeconds -PollMs $PollMilliseconds
        if ($automation) {
            $runObject.automation = $automation
            if ($null -ne $automation.window_first_ms) { $runObject.window_first_seen_ms = [math]::Round([double]$automation.window_first_ms, 1) }
            if ($null -ne $automation.warning_first_ms) { $runObject.warning_first_seen_ms = [math]::Round([double]$automation.warning_first_ms, 1) }
            if ($null -ne $automation.warning_last_ms) { $runObject.warning_last_seen_ms = [math]::Round([double]$automation.warning_last_ms, 1) }
            $runObject.warning_present = [bool](@($automation.records | Where-Object { $_.Kind -eq 'warning' }).Count -gt 0)
        } else {
            $runObject.notes += 'UI detector returned no result'
        }
    }

    Start-Sleep -Milliseconds 500
    $stopped = Stop-RunEdgeProcesses -ProfilePath $profile
    $runObject.notes += ("edge processes stopped: " + $stopped)

    $filterTerms = @()
    if ($mainPid) { $filterTerms += ("pid=" + $mainPid) }
    if ($launcher -and $launcher.Id) { $filterTerms += ("pid=" + $launcher.Id) }

    $injLines = @()
    $dllLines = @()
    $dllErrLines = @()
    if ($filterTerms.Count -gt 0) {
        $injLines = @(Read-LogDelta -Snapshot $logInjector -Filter $filterTerms)
        $dllLines = @(Read-LogDelta -Snapshot $logDll -Filter $filterTerms)
        $dllErrLines = @(Read-LogDelta -Snapshot $logDllErr -Filter $filterTerms)
    }
    if ($injLines.Count -eq 0) { $injLines = @(Read-LogDelta -Snapshot $logInjector -Filter @('run_id=')) }
    if ($dllLines.Count -eq 0 -and $mainPid) { $dllLines = @(Read-LogDelta -Snapshot $logDll -Filter @('dll_timeline')) }

    $runObject.injector_lines = $injLines
    $runObject.dll_lines = $dllLines
    $runObject.dll_err_lines = $dllErrLines

    $injRunLine = $injLines | Where-Object { $_ -match ' result=' } | Select-Object -Last 1
    if ($injRunLine) { $runObject.run_id = Get-KeyValueField -Text $injRunLine -Field 'run_id' }
    $dllSummaryLine = $dllLines | Where-Object { $_ -match '^dll_timeline' } | Select-Object -Last 1
    if ($dllSummaryLine) { $runObject.dll_summary = $dllSummaryLine }

    $row = [pscustomobject]@{
        run = $i
        warning_present = [bool]$runObject.warning_present
        window_first_seen_ms = $runObject.window_first_seen_ms
        warning_first_seen_ms = $runObject.warning_first_seen_ms
        warning_last_seen_ms = $runObject.warning_last_seen_ms
        injector_open_ms = $(if ($injRunLine) { Get-KeyValueField -Text $injRunLine -Field 'open_process_ms' } else { $null })
        injector_memory_ms = $(if ($injRunLine) { Get-KeyValueField -Text $injRunLine -Field 'remote_memory_written_ms' } else { $null })
        injector_thread_ms = $(if ($injRunLine) { Get-KeyValueField -Text $injRunLine -Field 'remote_thread_created_ms' } else { $null })
        injector_load_ms = $(if ($injRunLine) { Get-KeyValueField -Text $injRunLine -Field 'load_library_completed_ms' } else { $null })
        injector_result = $(if ($injRunLine) { Get-KeyValueField -Text $injRunLine -Field 'result' } else { $null })
        dll_config_ms = $(if ($dllSummaryLine) { Get-KeyValueField -Text $dllSummaryLine -Field 'config_loaded_ms' } else { $null })
        dll_module_seen_ms = $(if ($dllSummaryLine) { Get-KeyValueField -Text $dllSummaryLine -Field 'module_first_seen_ms' } else { $null })
        dll_scan_end_ms = $(if ($dllSummaryLine) { Get-KeyValueField -Text $dllSummaryLine -Field 'scan_end_ms' } else { $null })
        dll_write_end_ms = $(if ($dllSummaryLine) { Get-KeyValueField -Text $dllSummaryLine -Field 'write_end_ms' } else { $null })
        dll_result = $(if ($dllSummaryLine) { Get-KeyValueField -Text $dllSummaryLine -Field 'result' } else { $null })
    }
    $runSummaries += $row
    $runObjects += [pscustomobject]$runObject

    if ($KeepProfiles) {
        $runObject.notes += 'profile kept for inspection'
    } else {
        try {
            Remove-Item -LiteralPath $profile -Recurse -Force -ErrorAction Stop
            $runObject.cleanup_profile_removed = $true
        } catch {
            $runObject.notes += ("profile cleanup failed: " + $_.Exception.Message)
        }
    }

    $runJsonPath = Join-Path $OutDir ("run-{0}.json" -f $runId)
    [pscustomobject]$runObject | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runJsonPath -Encoding UTF8

    $injResult = $(if ($injRunLine) { Get-KeyValueField -Text $injRunLine -Field 'result' } else { 'n/a' })
    $dllResult = $(if ($dllSummaryLine) { Get-KeyValueField -Text $dllSummaryLine -Field 'result' } else { 'n/a' })
    Write-Host ("run {0}: warning_present={1} main_pid={2} injector_result={3} dll_result={4}" -f $i, $runObject.warning_present, $mainPid, $injResult, $dllResult)
}

$summaryCsv = Join-Path $OutDir 'summary.csv'
$runSummaries | Export-Csv -LiteralPath $summaryCsv -NoTypeInformation -Encoding UTF8

$allJson = Join-Path $OutDir 'all-runs.json'
$runObjects | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $allJson -Encoding UTF8

$numericColumns = @(
    'window_first_seen_ms', 'warning_first_seen_ms', 'warning_last_seen_ms',
    'injector_open_ms', 'injector_memory_ms', 'injector_thread_ms', 'injector_load_ms',
    'dll_config_ms', 'dll_module_seen_ms', 'dll_scan_end_ms', 'dll_write_end_ms'
)
$percentiles = [ordered]@{}
foreach ($col in $numericColumns) {
    $values = @()
    foreach ($row in $runSummaries) {
        $v = $row.$col
        if ($null -ne $v -and $v -ne '') {
            try { $values += [double]$v } catch { }
        }
    }
    if ($values.Count -eq 0) { continue }
    $sorted = @($values | Sort-Object)
    $percentiles[$col] = [ordered]@{
        count = $sorted.Count
        min = [math]::Round($sorted[0], 1)
        p50 = [math]::Round($sorted[[math]::Floor(($sorted.Count - 1) * 0.50)], 1)
        p95 = [math]::Round($sorted[[math]::Floor(($sorted.Count - 1) * 0.95)], 1)
        p99 = [math]::Round($sorted[[math]::Floor(($sorted.Count - 1) * 0.99)], 1)
        max = [math]::Round($sorted[$sorted.Count - 1], 1)
    }
}
$warningCount = @($runSummaries | Where-Object { $_.warning_present }).Count
$okCount = @($runSummaries | Where-Object { $_.dll_result -eq 'ok' }).Count
$stats = [ordered]@{
    runs = $Runs
    generated_utc = [DateTime]::UtcNow.ToString('O')
    warning_present = $warningCount
    patch_ok = $okCount
    patch_not_ok = $Runs - $okCount
    percentiles = $percentiles
}
$statsJson = Join-Path $OutDir 'stats.json'
$stats | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statsJson -Encoding UTF8

Write-Host ''
Write-Host ("Output: " + $OutDir)
Write-Host ("Warnings detected: {0}/{1}" -f $warningCount, $Runs)
Write-Host ("Patch ok (dll result): {0}/{1}" -f $okCount, $Runs)
$runSummaries | Format-Table -AutoSize
