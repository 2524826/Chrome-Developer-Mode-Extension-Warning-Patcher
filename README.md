# Edge developer-mode extension warning patcher

[简体中文说明](README.zh-CN.md)

This maintenance branch suppresses only the developer-mode extension startup warning on x64 Edge. The rule was verified on **Microsoft Edge Stable 151.0.4129.59 x64** with this `msedge.dll` SHA-256:

```text
85A417AAD813BA032FB97B182EB4DB0DD8DC31CA5E5CFBBD6103C26002EBF895
```

The installed runtime is forward-compatible with Edge 151 and later only while the same complete function signature still matches exactly once and every original write byte is unchanged. An update that changes those safety conditions fails closed without modifying process memory. Later Edge versions are eligible for guarded matching, not claimed as manually validated.

The patch does not disable extensions, Defender SmartScreen, Safe Browsing, permission prompts, extension isolation, signature checks, browser updates, or other security UI. All unrelated legacy patch groups are off by default and the installer rejects any selection other than group 0.

## Start with a read-only dry-run

Install the .NET 9 SDK, then run from the repository root:

```powershell
dotnet build .\EdgeWarningPatcher.Verifier\EdgeWarningPatcher.Verifier.csproj
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-local-edge-fixture.ps1 -NoBuild
```

The verifier checks the browser and minimum version, module name, x64 PE machine type, `.text` section, complete-function signature, unique match count, and original bytes. It reports the current module SHA-256 and planned RVA/file offsets but opens the Edge module read-only and never writes it.

To collect a privacy-safe environment report:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\collect-edge-environment.ps1 `
  -OutputPath .\environment-report.json
```

## Reproduce the warning

Use a disposable Edge profile and [the minimal unpacked extension](test-assets/minimal-unpacked-extension/README.md). Open `edge://extensions`, enable Developer mode, load the fixture, fully exit Edge, confirm all `msedge.exe` processes have ended, and restart Edge.

## Runtime behavior

The existing installer/injector architecture is retained, but hardened:

- rules are embedded at build time instead of downloaded at runtime;
- installation requires the current Edge module to pass the complete read-only verifier before persistence is written;
- the injected DLL selects exactly one `msedge.dll` below the configured stable Edge application root and checks its version range;
- the matcher scans only `.text` and requires exactly one match;
- all original bytes are checked before any in-memory write;
- writes are applied as one transaction, verified, and rolled back on failure;
- after an Edge update, the same full validation is repeated against the newly loaded module; compatible code is patched automatically and changed code fails closed.

The browser binary on disk is not modified. The existing uninstall path removes the scheduled task, injector files, registry registration, and `ChromePatches.bin`; restarting Edge removes the process-memory changes. Because this is an in-memory patch, there is no browser-binary backup to restore.

## Edge updates

Normally the patcher does not need to be run again after an Edge update. Fully restart Edge so the installed injector sees the new main process. If the complete signature still has one match and both original bytes remain valid, the runtime applies the patch automatically. Otherwise the warning returns and `%WINDIR%\Temp\ChromePatcherDllErr.log` records the fail-closed reason; the rule must then be updated before any write is allowed.

## Build and test

See [BUILDING](docs/BUILDING.md). The self-contained verifier test suite uses generated PE fixtures and commits no Microsoft binaries:

```powershell
dotnet run --project .\EdgeWarningPatcher.Verifier.Tests\EdgeWarningPatcher.Verifier.Tests.csproj
```

## Evidence and maintenance

- [Edge 151 analysis](docs/EDGE_151_ANALYSIS.md)
- [Architecture and trust boundaries](docs/ARCHITECTURE.md)
- [Known limitations](KNOWN_ISSUES.md)
- [License](LICENSE)

This project is not affiliated with or endorsed by Microsoft, Google, Chromium, or any browser vendor. Edge/Chromium binaries and PDBs are not included.
