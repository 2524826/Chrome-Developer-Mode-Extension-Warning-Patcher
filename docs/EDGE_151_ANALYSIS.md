# Microsoft Edge 151 developer-mode warning analysis

## Reproduced target

| Property | Observed value |
|---|---|
| Product/channel | Microsoft Edge Stable |
| Version | `151.0.4129.59` |
| Architecture | x64 |
| Module | `Application\151.0.4129.59\msedge.dll` |
| Module size | `341,721,416` bytes |
| Module SHA-256 | `85A417AAD813BA032FB97B182EB4DB0DD8DC31CA5E5CFBBD6103C26002EBF895` |
| Public PDB identity | `{75F619B7-04DD-7A8C-4C4C-44205044422E}`, age 1 |

The matching Microsoft public PDB was used locally for symbol-to-RVA mapping and was not committed. No Edge binary, PDB, resource pack, or substantial disassembly is stored in this repository.

## Warning source and decision path

The English UI strings are DataPack resources in `Locales\en-US.pak`, not executable decision logic:

- resource `20497` (`0x5011`): `Turn off extensions in developer mode`;
- resource `20498` (`0x5012`): `Running extensions in developer mode can harm your device.`

The exact PDB proves that Edge 151 still contains `extensions::DevModeBubbleDelegate::ShouldIncludeExtension` at RVA `0x0F72F8D0`, length `0x2D`. Related symbols include `GetTitle`, `GetMessageBody`, `GetActionButtonLabel`, `GetDismissButtonLabel`, and `ShouldShow`. `GetTitle` and `GetMessageBody` select the resource IDs above, connecting the new panel text to the same native delegate rather than to an unrelated global dialog hook.

The relevant instruction anchors are deliberately shown only in minimal form:

```text
83 F9 04 74 0E       compare location with UNPACKED (4)
83 F8 08 0F 94 C0    compare location with COMMAND_LINE (8), return equality
```

Call-chain summary:

```text
extension message-bubble startup decision
  -> DevModeBubbleDelegate::ShouldShow
  -> DevModeBubbleDelegate::ShouldIncludeExtension(extension)
  -> extension location == UNPACKED or COMMAND_LINE
  -> title/body/action labels use the Edge warning resources
```

The public symbol set also contains `ExtensionMessageBubbleController` and `ToolbarActionsModel::GetExtensionMessageBubbleController`, consistent with this delegate being consumed by the extension-message UI. The exact behavior and persistence lifetime of **Not now** were not dynamically traced in this maintenance session. Symbols and older Chromium tests indicate session/profile dismissal state rather than permanent acknowledgement; this remains an inference, not a claimed runtime result.

## Selected patch point

The rule matches the complete 45-byte `ShouldIncludeExtension` body, with wildcards only for two relative call displacements. It changes the two enum comparands:

```text
offset +0x16: 04 -> FF
offset +0x23: 08 -> FF
```

This preserves stack balance, instruction boundaries, calls, control-flow shape, exception metadata and executable-section size. It makes this delegate include neither unpacked nor command-line extensions in the warning list; it does not disable or reclassify the extensions themselves.

For the analyzed Edge 151 module, the complete matched context SHA-256 is:

```text
FADBE0973F5B2B4BEFA0476A2960DAFCBFA9DB8F387653BCEAFE0089E28464AC
```

On the reproduced module the match is unique in `.text` at RVA `0x0F72F8D0`, file offset `0x0F72EED0`. Planned writes are at RVAs `0x0F72F8E6` and `0x0F72F8F3`.

The exact context hash remains evidence for the analyzed build, but is not an update-compatibility gate. Relative call displacements and other compiler details can change while the complete semantic signature remains valid. Forward compatibility therefore requires the entire 45-byte masked signature to have exactly one `.text` match and both write bytes to remain unchanged. If either condition fails, the runtime performs no write.

## Why the old rule was unsafe/stale

The old rule matched only a short function prefix shared across several historical Edge/Chromium builds, accepted several alternative offsets, treated literal `FF` as both wildcard and original-byte bypass, selected the first match across executable memory, and ignored the module-version mismatch result. The visible UI changed, so text alone also gave no evidence that the old offset was still correct. The new evidence shows that the semantic function survived in this exact Edge build, but the old matching and write pipeline could not establish that fact safely.

## Security scope

Only the delegate deciding membership in this one warning is changed. No resource string is blanked and there is no hook of generic dialog, policy, download, reputation, permission, sandbox, signature, update, or Safe Browsing code. Edge Stable updates may reuse the rule only when all runtime gates still pass. Beta, Dev and Canary channels must not be assumed to share this byte layout, and any patch failure requires a new symbol/rule analysis before changing the signature.
