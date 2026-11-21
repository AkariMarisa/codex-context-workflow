# Codex 精简主会话与自动交接

原生全局指令、自定义执行代理和 SessionStart/compact、PostModelRequest hooks。需要 PowerShell 7。主代理根据任务包进度与上下文压力决定交接，由宿主工具完成接续。

## 安装

```powershell
pwsh -NoProfile -File ./Install.ps1 -ValidateOnly
pwsh -NoProfile -File ./Install.ps1
```

默认目标为当前用户配置目录 `~/.codex`。需要自定义时，可在当前 shell 设置 `$env:CODEX_HOME`，通过 `-CodexHome` 指定，或将 [.workflow.local.example.json](.workflow.local.example.json) 复制成 `.workflow.local.json` 并修改。安装目标按 `-CodexHome`、`CODEX_HOME`、本地 JSON 的 `CodexHome`、默认目录的顺序选取。输入压力阈值按 `-InputTokenThreshold`、JSON 的 `InputTokenThreshold`、默认值 200000 的顺序选取。两个 JSON 字段均可省略。

本地 JSON 默认与 `Install.ps1` 同目录，也可用 `-LocalConfigPath` 指定其他文件。默认文件名已被 Git 忽略，可保存本机路径。请勿把凭据写进该文件。让 agent 代装时，可以要求它先核对目标目录并运行 `-ValidateOnly`，再按相同配置运行安装。

安装器合并有标记的 AGENTS.md 及 hooks.json，并安装 `agents/` 下的五个工作流角色和 `context-workflow/` 下的钩子及辅助脚本。保留其他规则和处理器，修改前备份，重复安装幂等。`-ValidateOnly` 不创建目标目录。遇到 AGENTS.override.md 或同名无所有权标记文件时拒绝覆盖。主模型和推理档位继续由用户的 Codex 配置管理。

新会话通过 CLI `/hooks` 或桌面 Settings > Hooks 审阅并信任 hook。两个处理器同步执行，超时为 5 秒。SessionStart 设置 `additionalContextLimit=4096`，PostModelRequest 只持久化信号。通知用 UTF-8 JSON 转义保留中文和路径。升级时移除本项目原有的 Stop 定义，保留其他处理器及既有信任字段。兼容脚本供已经加载旧配置的宿主安全退出。

用安装参数 `-InputTokenThreshold 200000` 调整单次输入压力阈值。达到阈值的样本仅在进入该压力区间时持久化。低于阈值时清掉旧样本，首次低压无需创建状态目录。PostModelRequest 启动 PowerShell 仍有固定开销。

## 自动行为

主会话直接处理简单修改。大任务按实际需要安排方案和只读调查、成批实施、集中验收。出现实际失败后才安排定点修复。每个阶段可由一个或多个独立执行会话承担，默认一次一个写者。阶段开始时记下范围、负责人、依赖、通过条件和预期证据。阶段末按既有入口集中验收，失败后只复验受影响项。提前检查用于排除明确阻塞、验证关键依赖或满足项目规则。各阶段通过同一份摘要传递交付、证据和待办。

派发时显式选择宿主支持的隔离选项，如 `fork_turns=none` 或 `fork_context=false`。按任务领域、复杂度和风险选择当前宿主和账号允许的模型与推理档位。若派发接口缺少这些字段，可选择宿主支持的自定义角色。

| 子代理工作 | 角色 | 角色配置 |
| --- | --- | --- |
| 范围明确的探索、日志提取或执行既定检查 | `context-scan` | GPT-6 Luna / low |
| 按范围成批实现 | `context-implement` | GPT-6.2 Sol / medium |
| 截图、界面或其他视觉分析 | `context-visual` | GPT-6.1 Terra / medium |
| 高风险审查、复杂诊断 | `context-review` | GPT-6.2 Astra / high |

首选组合不可用时，用宿主支持的相近配置。宿主也无法明确选择合适角色时，使用继承父设置的 `context_worker`。无法隔离历史时由主会话处理。角色配置位于 `agents/`，不依赖在 `config.toml` 中设置子代理默认模型。 [Codex 子代理](https://learn.chatgpt.com/docs/agent-configuration/subagents) · [模型选择](https://learn.chatgpt.com/docs/model-selection)

### 任务包交接决策

| 当前任务包 | 主会话决策 |
| --- | --- |
| 未完成且余量足以收口 | 继续同一批次。单次输入超过阈值或达到两次压缩只提供参考 |
| 未完成且明确无法安全收口 | 到最早可核验的安全检查点，保存剩余子项和精确恢复点，再按交接协议处理 |
| 已收口且没有后续工作 | 直接结束 |
| 已收口且还有后续工作 | 比较余量、下一包的大小与独立性、重新加载需要的上下文。能便宜复用就继续，确有收益再交接 |

当有后续工作且需要补充压力证据时，用真实当前会话 ID 读取一次持久状态。若宿主提供的 `CODEX_THREAD_ID` 对应当前主会话，可使用如下命令。

```powershell
& './Set-HandoffState.ps1' -Action ReadPressure -SessionId $env:CODEX_THREAD_ID
```

`elevated` 表示上次进入压力区间时观测到单次输入较高。样本含缓存输入，单次输入量无法换算为精确窗口占比。收到有效的低于阈值请求，或完成下一次压缩时清掉该样本。`unknown` 表示没有可用的高压样本。压缩次数从安装后累计，只作为历史辅助。观察器排除有明确子代理标记的事件。 [Hooks 事件](https://learn.chatgpt.com/docs/hooks)

观察压力本身不会设置 pending。第二次压缩只发送一次判断提示，不打断当前任务。主代理选择接续后才调用 Prepare。旧版尚未准备的压力 pending 按提示处理，已准备及更后面的交接保持原状态。Stop 自动续轮已退役，减少为评估压力而多发的一次模型请求。

用户已授权自动准备以及条件满足后的后台创建，无需逐次询问。仅宿主明确提供原生同窗口切换工具时才切换，否则只给CLI恢复入口，不启动额外客户端。主代理先核实旧 goal 非活动、全部写者停止、全部句柄归属/原命令/状态可靠，记录证据后才开始创建。活动 goal 或不明句柄时只准备摘要、说明具体阻塞及恢复入口。不自动暂停 goal、杀进程、恢复暂停goal或用户暂停的业务范围、迁移预算/用量；进入 creating 后旧会话停止业务调度，只收尾交接。

新会话只接收摘要/必要规则路径及安全约束，先只读核验，不读全聊天或 fork 历史；缺安全证据则结束本轮，给恢复入口，不持续轮询，不擅自新建 goal。先只读仅为核验阶段。安全核验与合法交接确认完成后，新会话继续摘要中明确、未撤销的实施授权，无需用户再次说“继续”。Confirm仅是已读回执，不是授权或安全证据；confirmed不重复Confirm。明确只读、暂停、待新决定优先；旧goal暂停不自动撤销其他独立授权，也不自动恢复任何goal。无同窗口switch仅限制UI切换，不限制安全接续后的授权工作。

摘要由源主代理根据实际授权在文件最前两行依次填写以下元数据独占行（正文/代码围栏中的示例不算声明），禁止从已读或confirmed推导实施授权。无明确范围、用户暂停或待决定时使用ReadOnly、Paused或NeedsDecision；重复/冲突字段安全退只读。字段是明确授权声明，生成器不会从自然语言推断或替代新会话对最新用户限制的核验。

```text
Handoff-ContinuationMode: ResumeAuthorized
Handoff-AuthorizedScope: <已有明确且未撤销的实施授权范围及限制>
```

创建和race后恢复使用同一提示生成器；默认只读，显式请求ResumeAuthorized且摘要上述字段完整才输出继续模式。其仅输出提示，不读写状态或操作会话/goal。提示仍要求新会话核验，安全闸不能被模式或confirmed绕过。

```powershell
& './New-HandoffPrompt.ps1' -SummaryPath '<摘要绝对路径>' -SessionId '<真实旧id>' -StatePath '<状态绝对路径>' -RulePath '<必要规则绝对路径>' -ContinuationMode ResumeAuthorized
```

默认1000 UTF8字节上限（可按宿主明确上限传MaxUtf8Bytes），超限报错且不输出部分提示；缩短合法路径或保留prepared并报告限制，禁止裁切。新会话如因creating/uncertain先回执结束，旧方RecordCreated及合法Confirm完成后向既有新id发送同一提示，confirmed时不重复Confirm；旧会话始终不恢复业务写入。

## 状态协议

使用真实旧 session 标识调用安装目录下 Set-HandoffState.ps1。安全开关是主代理核查证据后的声明；脚本不会检测或改变真实 goal/进程。

```powershell
$handoff = @{ SessionId = '<真实旧session标识>' }
& './Set-HandoffState.ps1' @handoff -Action Prepare -SummaryPath '<既有摘要绝对路径>'
# 核实安全证据后：
& './Set-HandoffState.ps1' @handoff -Action BeginCreate -OldGoalInactive -WritersStopped -HandlesVerified
# 此处主代理调用一次当前可用的新会话工具，脚本不会代调。
& './Set-HandoffState.ps1' @handoff -Action RecordCreated -ThreadId '<返回的新id>'
# 调用超时/结果不明则 MarkUncertain，不盲重试。
# 新会话实际读摘要后，匹配既有id才能确认：
& './Set-HandoffState.ps1' @handoff -Action Confirm -ThreadId '<已记录的新id>' -NewSessionReadSummary
```

requested → prepared → creating → created → confirmed；creating 可转 uncertain，查证原创建结果后再 RecordCreated。creating/uncertain 不可重置重试；created/confirmed 不可回退重建。结果丢失时查原调用/宿主列表，查不清则阻塞。目标id必须不同于源session；只有 Confirm 清除 pending，创建成功或发出打开请求不代表确认。

创建工具可能先启动新会话，再返回id供旧会话RecordCreated。新会话遇creating/uncertain时只读摘要、回传已读及阻塞后结束本轮，不轮询或业务写入。旧主代理先记录id，再根据真实已读回执Confirm；若有既有继续授权，可向既有新id发送一次明确“安全条件与合法确认完成，请核验后按摘要既有授权继续”的统一恢复提示，不再锁成只读/Confirm。恢复工具不可用则给既有id和精确CLI入口，不轮询或重建。

自动创建依赖当前宿主显式提供的原生工具。先核实工具能使用正确工作目录、隔离历史、保留主会话所选模型和推理档位，再检查实际提示字节数。所有预检完成后才执行 BeginCreate。当原调用结果不明时保留 creating/uncertain，仅查证原调用。

若宿主没有原生创建工具，且旧会话已安全停在 `prepared`、从未尝试原生创建，先用 `New-HandoffPrompt.ps1 -ManualTarget` 生成提示，结束旧会话的业务调度。用户在同一 CLI 自行输入 `/new`，选择同一工作目录，再粘贴提示。新会话须只读核验摘要、旧会话安全证据及自身真实 ID。CLI 可用 `/status` 核对会话 ID。证据齐备后由新会话登记并确认。

```powershell
& './Set-HandoffState.ps1' -SessionId '<旧 ID>' -Action RegisterManual -ThreadId '<真实新 ID>' -SummaryPath '<同一摘要绝对路径>' -OldGoalInactive -WritersStopped -HandlesVerified
& './Set-HandoffState.ps1' -SessionId '<旧 ID>' -Action Confirm -ThreadId '<真实新 ID>' -NewSessionReadSummary
```

手动登记只接受 `prepared`，成功后仍是 `created` 且 pending。匹配的真实已读回执才完成确认。`creating`、`uncertain` 时继续核查原创建结果。`created` 时使用既有 ID 恢复。 [CLI 命令](https://learn.chatgpt.com/docs/developer-commands?surface=cli)

Open-Handoff.ps1 -ThreadId <id> 只打印退出当前CLI后在同一终端执行的 `codex resume <id>`。legacy `-Open` 保留兼容，也只输出提示；所有路径均不调用桌面深链接、Start-Process、额外Codex客户端或向终端强行输入。id为1–128个字母数字、下划线和连字符，首字符须为字母数字，拒绝尾部换行。失败时提供既有id/摘要/恢复入口，不重建线程。

本地 CLI 0.171.0 的 `codex resume --help` 确认支持会话 ID。若宿主未提供原生同窗口切换工具，用户可以用 `/resume` 打开交互选择器，或退出后在同一终端运行 `codex resume <ID>`。 [CLI 参考](https://learn.chatgpt.com/docs/cli/reference)

## 验证与边界

```powershell
pwsh -NoProfile -File ./Test-Workflow.ps1
```

回归使用 `build/` 下隔离的 CODEX_HOME，覆盖本地配置优先级、安装与配置保留、压力样本清理、只读查询、压缩提示、旧 Stop 定义退役、原始 stdout 字节、中文路径、手动登记和已读确认。

部分宿主提供原生会话创建工具，例如 `create_thread`。真实 TUI 的显示、完整交接和角色选配取决于安装环境，可按以下步骤验收。

原生验收应在无活动goal/业务写者的独立测试目录：

1. 只读委派，检查实际工具参数明确不继承历史。
2. 在隔离测试 home 安装并审阅两个事件。可临时设置 `-InputTokenThreshold 1`。发送任务包仍在实施的正常请求，确认仅出现 `elevated`，没有新 pending 或 Stop 续轮。两次 `/compact` 后，核对一次中文提示及旧样本清理。再让一个任务包收口，核对主代理有后续工作时如何结合压力和重读成本决定去留。
3. 核实安全证据。有原生创建能力时，观察 BeginCreate 先于唯一创建调用、返回 ID 落盘。没有能力时，验证人工 `/new`、目标核验及登记。两条路径都应在实际已读确认前保留 pending。
4. 确认默认及旧 -Open 都只给恢复命令且不唤醒客户端；用户退出当前CLI后在同一终端执行 codex resume <新id>，或手动 /agents 选择既有会话。失败不重建。新会话读摘要后 Confirm，再 compact 不重发。

全局指令是模型约定，无法保证每次遵守或节省token；安全开关须真实核查。停用可在 /hooks 禁用处理器，移除AGENTS标记块和角色；保留摘要及未知创建状态。按需恢复备份，不覆盖后续无关配置。

## 设计依据

- 将方案、成批实施、集中验收和必要的定点修复设为阶段，减少每次微小改动后的测试重跑。跨会话传递范围、通过条件和证据，降低重复探索的成本。
- 将子代理选择与主会话配置解耦。常规探索和检查以效率为先，复杂实现、视觉分析和高风险审查采用与工作相适应的模型和推理档位。
- 用任务包收口确定交接时机，再权衡上下文余量和重读成本，避免只因压缩次数达到阈值就中断正在推进的工作。

## 官方文档
- [全局AGENTS](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
- [执行代理](https://learn.chatgpt.com/docs/agent-configuration/subagents)
- [Hooks](https://learn.chatgpt.com/docs/hooks)
- [CLI恢复参考](https://learn.chatgpt.com/docs/cli/reference)
- [CLI交互命令](https://learn.chatgpt.com/docs/developer-commands?surface=cli)


## 本地 hook 诊断（默认启用）

覆盖本项目活跃的 `on-model-request.ps1` 和 `on-compact.ps1`。诊断记录脚本是否进入、耗时、跳过或异常的阶段和预期输出形状。历史 `on-stop.ps1` 记录仍可查看，兼容脚本无需新增记录。诊断与 hook 共用同一 PowerShell 进程。

默认文件目录为 `<CODEX_HOME>/context-workflow/diagnostics/`：`hooks.jsonl`、`hooks.1.jsonl`、`hooks.2.jsonl`，每个最多 1 MiB，共最多 3 MiB，加一个空 `hooks.lock`。达到上限轮转丢弃最旧文件；不做网络遥测。每条写入仅尝试一次独占锁，不等待/重试；目录、写入、轮转或锁失败均静默放行，不污染 stdout，也可能缺记录。测试或手动执行时可用 `-DiagnosticsDirectory <临时目录>` 重定向；诊断与 StateDirectory 独立，测试调用源脚本须同时重定向两者。

读取示例（PowerShell）：

```powershell
& "$env:CODEX_HOME/context-workflow/Get-WorkflowDiagnostics.ps1" -SessionId '<实际session id>' -Last 30
# 若CODEX_HOME未设置，请使用已安装脚本的绝对路径。
```

reader 内部对 SessionId 做 SHA256，返回最近 N 条（默认30、最大1000）、保留文件内的 handler/outcome 统计和最多 N 条有 start 无保留 finish 的记录。不提供 SessionId 则汇总全部保留记录；关联发生前的 start 通过 invocation_id 归入筛选结果。reader 只读日志，不创建文件、不查聊天或业务状态；拒绝超限文件并投影允许字段。并发/轮转期间读取可能缺失或不完整，计数不是全量运行历史。

字段仅包含 UTC、固定 handler/event/phase/outcome、每次唯一 invocation_id、解析有效根 session 后的 hashed_session_id、脚本内 duration_ms、异常类型及 `expected_output_shape`。duration_ms 从脚本内诊断入口开始计时，不包含 pwsh 启动或宿主等待，不能据此推算原生5秒timeout。无用量、字段缺失/非整型/负值和有效值低于阈值分别记录 usage_unavailable、invalid_usage、below_threshold，不记录实际数值。不记录事件/prompt/聊天/路径/cwd/摘要/原session id/凭据/token用量/error.message/完整stderr。`expected_output_shape` 仅表示分支预期 `empty` 或 `json_object`，不是实际 stdout 截取、宿主解析成功或原生退出状态；completed 表示走到脚本结束记录，不代表宿主接受 hook。

start 在参数绑定后、读取 stdin 前尽早写入。无 start 不能区分未调用、未信任、启动/参数绑定失败或诊断写失败；不支持的参数可能在脚本执行前被 PowerShell 拒绝，无法记录。start 无 finish 只表示保留证据未完成，可能仍运行、终止、日志争用/写失败或轮转，不能认定超时。其他插件 hooks、进入脚本前故障及过去的“Hook failed”不在覆盖范围；历史错误无法补录。可在 CLI 的 `/warnings` 查看仍保留的警告，但不保证找回已丢提示。

统一验证入口为 `pwsh -NoProfile -File ./Test-Workflow.ps1`。所有测试使用 build 临时 CODEX_HOME，验证 UTF-8 输出、旧 Stop 静默、压力保存与清理、锁争用、诊断隐私和状态兼容。真实 CLI 显示与主代理选择需按上述原生验收流程确认。
