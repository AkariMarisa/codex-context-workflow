# Codex Context Workflow

中文 · [English](README.en.md)

用 Codex 做跨多个会话的开发任务时，可以用这套规则把工作分批交给独立子代理，并在需要换会话时用一份摘要接着做。安装后，小改动仍由主会话直接处理。

## 安装

需要 PowerShell 7。在仓库目录运行下面两条命令。

```powershell
pwsh -NoProfile -File ./Install.ps1 -ValidateOnly
pwsh -NoProfile -File ./Install.ps1
```

第一条命令会检查配置并打印安装路径。正式安装会往 `AGENTS.md` 加入一段带标记的规则，在 `hooks.json` 注册两个 hook，并安装五个子代理角色和辅助脚本。现有规则和其他 hook 会保留，被改写的文件会备份。检测到 `AGENTS.override.md` 或有同名的角色文件或脚本缺少项目标记时，安装会停止。

安装后新开一个 Codex 会话，通过 CLI 的 `/hooks` 或桌面的 **Settings → Hooks** 审阅并信任这两个 hook。

### 自定义安装路径

默认安装到 `~/.codex`。路径按 `-CodexHome`、环境变量 `CODEX_HOME`、本地配置里的 `CodexHome` 依次查找。

要保存本机设置，把 [配置示例](.workflow.local.example.json) 复制为 `.workflow.local.json`，放在安装脚本旁边。也可以用 `-LocalConfigPath` 指向其他文件。两个字段都可以省略。

## 日常怎么用

- **长任务**可以按调查、实现、验收分批做。每批开工前记下范围和通过条件，结束时集中验证。子代理使用隔离的会话，写入默认一次交给一个代理。具体角色见仓库里的 `context-*.toml`，主会话沿用你自己的模型和推理设置。
- **上下文变长**时，`PostModelRequest` 会静默采样，如果尚未准备交接，`SessionStart` 会在第二次压缩时提醒主会话判断是否需要交接。主会话还会看当前批次能否收尾、后续还有多少工作，以及新会话需要重读多少内容。
- **确实要换会话**时，主会话更新同一份摘要，写清本轮交付、验证结果、未完成项和下一步。新会话先读摘要、相关规则和交接状态，然后按已核实的授权继续。

输入压力的默认阈值为单次请求 200,000 个输入 token，含缓存。用 `-InputTokenThreshold` 或同名 JSON 字段调整，命令行优先。

分批、委派和换会话由主会话按 [工作流规则](global-rules.md) 决定。能否隔离委派或创建新会话取决于当前 Codex 宿主提供的工具。

## 换会话时会发生什么

1. 主会话用 [`Set-HandoffState.ps1`](Set-HandoffState.ps1) 记录 `Prepare`，核实旧 goal 已非活动、所有写入已停止、运行句柄的归属和状态已查清。摘要前两行记录继续模式和授权范围，格式见 [全局规则](global-rules.md)。
2. 有原生创建工具时，主会话先记录 `BeginCreate`，只调用一次创建工具，再用 `RecordCreated` 保存返回的会话 ID。结果不明时查原调用，避免重复创建。
3. 宿主没有原生创建工具，且状态仍为 `prepared`、从未尝试原生创建时，主会话用 [`New-HandoffPrompt.ps1`](New-HandoffPrompt.ps1) 的 `-ManualTarget` 生成提示。你可以在同一 CLI 用 `/new`，在同一工作目录粘贴提示，由新会话核验后执行 `RegisterManual`。
4. 新会话实际读过摘要后，用已登记的 ID 执行 `Confirm`。这一步只确认已读，继续实施仍须有摘要中明确且未撤销的授权。

如果新会话已经创建，而宿主无法在当前窗口切换，可以退出当前 CLI，再在同一终端运行 `codex resume <新会话 ID>`。[`Open-Handoff.ps1`](Open-Handoff.ps1) 会打印这条命令。

## 排查 hook

两个 hook 默认把耗时、执行结果和跳过原因写到安装目录下的 `context-workflow/diagnostics/`。日志最多保留三个 1 MiB 文件，仅保存在本机，使用哈希后的会话 ID，省略聊天内容、路径和 token 用量。

进入安装目录下的 `context-workflow/` 后运行下面的命令。

```powershell
./Get-WorkflowDiagnostics.ps1 -SessionId '<实际会话 ID>' -Last 30
```

省略 `-SessionId` 可跨会话查看近期记录。看到一条 start 但找不到对应的 finish 时，日志只能说明结束记录缺失，原因还需结合宿主日志或 CLI 的 `/warnings` 排查。

## 开发验证

```powershell
pwsh -NoProfile -File ./Test-Workflow.ps1
```

测试在 `build/` 下使用隔离的配置目录，覆盖安装、hook 输出、诊断和交接状态。真实会话创建、CLI 显示和子代理隔离需要在目标宿主中验证。

[许可证](LICENSE)
