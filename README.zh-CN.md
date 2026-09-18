# Edge 开发人员模式扩展警告补丁

本版本只抑制 Edge 启动时针对解压扩展和命令行扩展的“开发人员模式扩展”警告，不关闭扩展本身，也不修改 SmartScreen、Safe Browsing、扩展权限、沙箱、签名验证或浏览器更新。

规则已在 Microsoft Edge Stable x64 上验证。对于 Edge 151 及以后版本，程序会在每次新的 Edge 主进程启动时重新执行完整匹配：只有 `.text` 中恰好存在一个完整函数签名，并且两个目标位置的原始字节仍然正确，才会修改进程内存。任一条件不满足都会安全停止，不修改磁盘上的 `msedge.dll`，也不会阻止 Edge 启动。未来版本仍须通过相同的全部门控，版本范围开放不代表未来版本已验证。

## 安装

1. 安装 Microsoft .NET 6 Desktop Runtime x64。
2. 完全退出 Edge，并确认任务管理器中没有残留的 `msedge.exe`。
3. 右键以管理员身份运行 `patcher\ChromeDevExtWarningPatcher.exe`。
4. 只保留 Edge 和 `Remove extension warning`，点击 `Install`。
5. 确认日志出现绿色的 `Successfully installed`，然后重新启动 Edge。

从旧的“精确锁定 151.0.4129.59”版本升级时，需要运行一次本安装器。它会停止旧注入器并写入新版配置。安装完成后的正常 Edge 更新通常不需要重新运行安装器。

## Edge 更新后的行为

- 如果新版本仍满足完整签名、唯一匹配和原始字节校验，补丁会在新进程中自动继续生效。
- 如果代码发生变化，补丁会 `fail closed`，警告可能重新出现，但 Edge 可以正常启动。
- 失败原因记录在 `%WINDIR%\Temp\ChromePatcherDllErr.log`；成功记录在 `%WINDIR%\Temp\ChromePatcherDll.log`。
- 不要反复强制运行旧规则。出现匹配失败后，应先为新版本执行只读验证并更新规则。

## 只读验证

在源码目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\test-local-edge-fixture.ps1 -NoBuild
```

成功报告应包含：

```text
"Passed": true
"MatchCount": 1
"WriteResult": "not-attempted"
```

只读验证不会修改 Edge 文件。

## 卸载

以管理员身份运行安装器并点击 `Uninstall`，然后完全退出并重新启动 Edge。卸载会删除计划任务、注册表登记、注入器文件和 `ChromePatches.bin`；由于浏览器磁盘文件从未被修改，不需要恢复 `msedge.dll` 备份。
