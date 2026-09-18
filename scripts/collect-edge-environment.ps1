[CmdletBinding()]
param(
    [string]$EdgeApplicationPath = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application",
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($EdgeApplicationPath)
$versionDirectory = Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop |
    Where-Object { $_.Name -as [version] } |
    Sort-Object { [version]$_.Name } -Descending |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'msedge.dll') } |
    Select-Object -First 1
if ($null -eq $versionDirectory) {
    throw "No versioned msedge.dll was found below $root"
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$osKey = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$moduleNames = @('msedge.dll', 'msedge_elf.dll', 'resources.pak', 'Locales\en-US.pak')
$modules = foreach ($name in $moduleNames) {
    $path = Join-Path $versionDirectory.FullName $name
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path
        [ordered]@{
            name = $name
            path = $item.FullName
            size = $item.Length
            lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
            sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
        }
    }
}

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
$msbuildCandidates = @(
    'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe',
    'C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe',
    'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe'
)
$msbuild = $msbuildCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$cmake = Get-Command cmake -ErrorAction SilentlyContinue
$projectPath = Join-Path $PSScriptRoot '..\ChromeDevExtWarningPatcher\ChromeDevExtWarningPatcher.csproj'
[xml]$project = Get-Content -LiteralPath $projectPath -Raw
$patcherVersion = [string]$project.Project.PropertyGroup.Version

$report = [ordered]@{
    collectedAtUtc = [DateTime]::UtcNow.ToString('o')
    windows = [ordered]@{
        productName = $osKey.ProductName
        displayVersion = $osKey.DisplayVersion
        currentBuild = $osKey.CurrentBuildNumber
        ubr = $osKey.UBR
        runtimeVersion = [Environment]::OSVersion.Version.ToString()
        architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    }
    privileges = [ordered]@{
        isAdministrator = $isAdministrator
    }
    edge = [ordered]@{
        channel = 'Stable'
        version = $versionDirectory.Name
        architecture = 'x64 (verified separately by the verifier PE gate)'
        applicationPath = $root
        versionPath = $versionDirectory.FullName
        modules = @($modules)
    }
    patcher = [ordered]@{
        sourceVersion = $patcherVersion
        installedVersion = $null
        note = 'No installed patcher executable was detected or executed by this read-only collector.'
    }
    tools = [ordered]@{
        dotnetPath = $dotnet.Source
        dotnetSdks = if ($dotnet) { @(& dotnet --list-sdks) } else { @() }
        dotnetRuntimes = if ($dotnet) { @(& dotnet --list-runtimes) } else { @() }
        msbuildPath = $msbuild
        msbuildVersion = if ($msbuild) { (Get-Item -LiteralPath $msbuild).VersionInfo.FileVersion } else { $null }
        cmakePath = $cmake.Source
        cmakeVersion = if ($cmake) { (& $cmake.Source --version | Select-Object -First 1) } else { $null }
    }
}

$json = $report | ConvertTo-Json -Depth 8
if ($OutputPath) {
    $destination = [IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $destination
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($destination, $json, [Text.UTF8Encoding]::new($false))
}
$json
