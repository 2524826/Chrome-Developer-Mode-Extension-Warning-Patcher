[CmdletBinding()]
param(
    [string]$EdgeApplicationPath = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application",
    [string]$RulesPath,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
$RulesPath = if ($RulesPath) { $RulesPath } else { Join-Path $PSScriptRoot '..\patterns.xml' }
$env:DOTNET_CLI_HOME = Join-Path $env:TEMP 'edge-warning-patcher-dotnet'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$project = Join-Path $PSScriptRoot '..\EdgeWarningPatcher.Verifier\EdgeWarningPatcher.Verifier.csproj'
$arguments = @('run', '-c', $Configuration)
if ($NoBuild) { $arguments += '--no-build' }
$arguments += @(
    '--project', [IO.Path]::GetFullPath($project),
    '--', 'verify',
    '--edge-application-path', [IO.Path]::GetFullPath($EdgeApplicationPath),
    '--rules', [IO.Path]::GetFullPath($RulesPath),
    '--json'
)

Write-Host 'Read-only dry-run: the Edge installation will not be modified.'
& dotnet @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Verifier failed with exit code $LASTEXITCODE"
}
