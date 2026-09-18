# Building and testing

## Recorded environment

- Windows runtime version: `10.0.26200.0` (registry: Windows 10 Pro, 25H2, build 26200.8875)
- Architecture: x64
- .NET SDKs: 3.1.426, 5.0.408, 9.0.304
- Visual Studio 2022 Build Tools / MSBuild 17.14
- MSVC toolset: v143
- CMake: not installed and not required

Run `scripts/collect-edge-environment.ps1` to reproduce the complete report.

## Unmodified upstream baseline

Baseline commit: `936977542ecfb025b784cd457fcbfd7dffbe5f5c`.

The requested baseline commands were attempted before source changes. Direct `dotnet restore/build` initially failed because the sandbox denied writes below the user `.dotnet`/NuGet profile. After redirecting those caches, the normal NuGet HTTPS client failed with `SEC_E_NO_CREDENTIALS`. `dotnet build ChromeDevExtWarningPatcher.sln` additionally could not resolve the C++ `VCTargetsPath`. Visual Studio MSBuild found the C++ toolset but could not resolve the old `net6.0-windows` SDK in this machine's Build Tools installation, and an inherited duplicate `Path`/`PATH` environment entry broke an MSBuild task. These are recorded environment/toolchain failures, not silently treated as passing builds.

## Prerequisites

- .NET 9 SDK for the verifier and its tests;
- Visual Studio 2022 Build Tools with Desktop development with C++ and Windows SDK for the native DLL;
- .NET 6 SDK/Desktop targeting pack plus NuGet access for the retained WPF installer;
- x64 Windows.

## Commands verified in this maintenance session

```powershell
dotnet build .\EdgeWarningPatcher.Verifier\EdgeWarningPatcher.Verifier.csproj
dotnet run --project .\EdgeWarningPatcher.Verifier.Tests\EdgeWarningPatcher.Verifier.Tests.csproj
dotnet run --project .\EdgeWarningPatcher.Verifier\EdgeWarningPatcher.Verifier.csproj -- `
  validate-rules --rules .\patterns.xml
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\test-local-edge-fixture.ps1 -NoBuild
```

The native Debug x64 build was verified with:

```powershell
& 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe' `
  .\ChromePatcherDll\ChromePatcherDll.vcxproj /t:Build `
  /p:Configuration=Debug /p:Platform=x64
```

The native test DLL can be built and run with the Visual Studio test runner:

```powershell
& $msbuild .\ChromePatcherDllUnitTests\ChromePatcherDllUnitTests.vcxproj `
  /t:Build /p:Configuration=Debug /p:Platform=x64
& $vstest .\ChromePatcherDllUnitTests\x64\Debug\ChromePatcherDllUnitTests.dll `
  /Platform:x64
```

The selector tests cover the verified Edge 151 path, a later Edge version, a pre-151 downgrade, an unrelated application root, and an incorrect module name.

If an automation host exposes both `Path` and `PATH`, start MSBuild with a sanitized environment containing only one case-insensitive path variable.

After routing official NuGet package bytes through a temporary loopback-only proxy to work around the sandbox credential defect, the retained managed components were also compiled individually in Release mode. `ChromeDllInjectorBuildZipper` built with 0 warnings, `ChromeDllInjector` built with 11 pre-existing nullability warnings, and `ChromeDevExtWarningPatcher` built with 0 warnings/errors. The native DLL and native test DLL both built in Debug and Release x64.

## Full solution / release

On a standard developer machine with the prerequisites and NuGet access:

```powershell
dotnet restore .\ChromeDevExtWarningPatcher.sln
msbuild .\ChromeDevExtWarningPatcher.sln /m /p:Configuration=Release /p:Platform=x64
```

Release builds invoke the repository's signing script. Pull-request CI must not require a private certificate; signing/release steps should remain conditional.

The WPF Release artifact was produced, but a single mixed-language `.sln` invocation was not: Visual Studio MSBuild in this Build Tools installation lacked the .NET SDK resolver, while `dotnet msbuild` could not load the Visual C++ tracking task type. CI uses the standard hosted Visual Studio installation where both resolvers are available. Manual installation was still not attempted because this session was not elevated.
