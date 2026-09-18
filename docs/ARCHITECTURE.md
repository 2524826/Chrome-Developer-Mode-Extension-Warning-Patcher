# Architecture and trust boundaries

## End-to-end flow

1. **Selection:** the WPF UI or command-line path builds a list of enabled patch groups. This maintenance build permits only group 0.
2. **Discovery:** `InstallationManager` runs browser-specific finders. The Edge finder checks system and per-user `Microsoft\Edge\Application` roots.
3. **Version/module choice:** the finder selects the newest version directory containing `msedge.dll` and pairs it with root-level `msedge.exe`. Installer preflight requires Edge 151 or later, x64 PE files, one complete-function match in `.text`, and exact original write bytes.
4. **Rule acquisition:** `patterns.xml` is embedded in the patcher assembly. The former unsigned/unhashed runtime download and stale `%TEMP%` fallback were removed.
5. **Rule interpretation:** the guarded verifier schema keeps wildcard significance separate, rejects unknown fields, and separates `BytePattern` from `Write` actions. The installer serializes only the selected guarded group-0 rule into a versioned native configuration. Serialization rejects a literal `FF` pattern byte because the retained native matcher reserves `FF` for a wildcard.
6. **Match count:** the verifier and hardened native runtime scan `.text` and require exactly one unique address. Zero or multiple matches abort before writes.
7. **Injection:** `ChromeDllInjector` observes target browser processes through ETW and injects the bundled native patch DLL using the existing remote-load mechanism.
8. **Persistence:** the installer registers selected browser executable paths under `HKLM\SOFTWARE\Ceiridge\ChromePatcher\ChromeExes`, writes `ChromePatches.bin` beside the browser executable, installs injector files under `%ProgramW6432%\Ceiridge\ChromeDllInjector`, and creates the highest-privilege logon task `ChromeDllInjector`.
9. **Runtime application:** the DLL opens `ChromePatches.bin` beside the registered browser executable, selects exactly one `msedge.dll` one version directory below the configured application root, checks the configured minimum/open-ended version range, validates x64 PE and `.text`, prepares the entire plan, checks original bytes, writes/flushes/verifies transactionally, and resumes threads.
10. **Browser updates:** the stable root-level `msedge.exe` registration and application-root selector survive a version-directory change. Every new main process repeats module selection, full-pattern unique matching, and original-byte validation. A compatible update is patched automatically; signature drift, ambiguity, a downgrade, or an unexpected path fails closed. No browser downgrade or update blocking is performed.
11. **Uninstall/recovery:** uninstall stops/removes the scheduled task, clears registry registrations, deletes patch configuration/injector files and broadcasts unload. Since `msedge.dll` is never changed on disk, a full Edge restart restores pristine code pages.
12. **Logging/tests:** release DLL logs to `%WINDIR%\Temp\ChromePatcherDll.log` and `ChromePatcherDllErr.log`. The verifier emits human-readable or JSON dry-run reports. Native legacy searcher tests remain; the new generated-PE verifier suite covers the safety gates without proprietary fixtures.

## What remains reliable

- browser-specific installation discovery;
- ETW-driven process observation and existing uninstall cleanup;
- in-memory changes that disappear on process exit;
- stable-root plus exact module-name selection, minimum version, section, unique-match and original-byte gates added here.

## What was obsolete or risky

- the historical AOBs and alternative offsets were not evidence for modern Edge;
- the first broad DLL path matching `\Application\<version>\*.dll` could select an Edge sibling module;
- `UsingWrongVersion` was logged but ignored;
- `FF` was both wildcard and an original-byte bypass;
- the first match was patched without proving uniqueness;
- writes occurred during parallel scanning and a total failure triggered a retry while browser threads were running;
- remotely downloaded `patterns.xml` had TLS transport only, with no pinned hash/signature or strict schema.

All of those runtime risks are removed or fail closed for the guarded group-0 path. Legacy groups remain present for historical reference but are disabled and rejected by this maintenance installer.

## Write and recovery model

This project patches process memory, not the Edge file. Therefore the task's file-backup/hash-restore gate is not applicable to the browser module: there is no patched on-disk hash. The equivalent safety boundary is read-only preflight before installation plus full guarded matching on every process start and all-or-nothing in-memory writes with rollback. If a runtime write fails, every write already made by that transaction is restored before threads resume.

The existing installer does write its own configuration/persistence files. Those are removed by uninstall, but its cleanup is not a cryptographic backup system. See `KNOWN_ISSUES.md`.
