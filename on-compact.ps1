# CODEX_CONTEXT_WORKFLOW_V1
# Only handoff state is read/persisted; no transcript, prompt or credentials.
[CmdletBinding()]
param([string]$StateDirectory = (Join-Path $PSScriptRoot 'state'),
    [string]$DiagnosticsDirectory = (Join-Path $PSScriptRoot 'diagnostics'))

$ErrorActionPreference = 'Stop'
$context = $null
$diagnostic = $null
$outputAttempted = $false
try {
    . (Join-Path $PSScriptRoot 'Workflow-Diagnostics.ps1')
    $diagnostic = Start-WorkflowDiagnostic $DiagnosticsDirectory 'on-compact'
} catch { }
try {
    . (Join-Path $PSScriptRoot 'Workflow-HookIO.ps1')
    $rawInput = Read-WorkflowHookInput
    if ($null -eq $rawInput) { if ($diagnostic) { $diagnostic.Outcome = 'skipped' }; exit 0 }
    if ($diagnostic) { $diagnostic.Phase = 'parse_input' }
    $eventData = ConvertFrom-Json -InputObject $rawInput -AsHashtable
    if ($diagnostic) { $diagnostic.Phase = 'validate_event' }
    if ($eventData.hook_event_name -ne 'SessionStart' -or $eventData.source -ne 'compact') { if ($diagnostic) { $diagnostic.Outcome = 'skipped' }; exit 0 }
    . (Join-Path $PSScriptRoot 'Workflow-State.ps1')
    if ($diagnostic) { $diagnostic.Phase = 'validate_event' }
    if (-not (Test-WorkflowRootEvent $eventData)) { if ($diagnostic) { $diagnostic.Outcome = 'skipped' }; exit 0 }
    if ($diagnostic) { Connect-WorkflowDiagnostic $diagnostic $eventData.session_id; $diagnostic.Phase = 'open_state' }
    $context = Open-WorkflowState $StateDirectory $eventData.session_id
    if ($diagnostic) { $diagnostic.Phase = 'check_state' }
    $state = $context.State
    $stateFile = $context.Path
    $state.compactions++
    # The previous request size belongs to the context before this compaction.
    Clear-WorkflowRequestPressure $state
    $advise = $state.handoff_status -eq 'requested' -and $state.compactions -ge 2 -and -not $state.pressure_advisory_emitted
    $showMessage = $state.handoff_pending -and -not $state.reminder_emitted
    if ($advise) { $state.pressure_advisory_emitted = $true }
    if ($showMessage) { $state.reminder_emitted = $true }
    $message = if ($state.handoff_pending) {
        "已准备的交接仍待确认。已观测 compact 次数：$($state.compactions)；旧 session 为 $($eventData.session_id)，状态文件为 $stateFile。按全局规则核对真实状态和安全证据。creating/uncertain 只核对原调用，created 只恢复既有 ID，目标实际读摘要后才 Confirm。"
    } elseif ($advise) {
        "已观测 compact 次数：$($state.compactions)；这是历史压力信号。按当前任务包的完成情况和剩余工作继续。到自然收口点且仍有后续任务时，可用 $PSScriptRoot/Set-HandoffState.ps1 -Action ReadPressure -SessionId $($eventData.session_id) 核对压力。只有确定换会话时才准备交接。"
    }
    if ($diagnostic) { $diagnostic.Phase = 'save_state' }
    Save-WorkflowState $context
    if ($message) {
        $output = @{
            continue = $true
            hookSpecificOutput = @{
                hookEventName = 'SessionStart'
                additionalContext = $message
            }
        }
        if ($showMessage) { $output.systemMessage = '接续摘要已准备，等待目标会话确认。' }
        if ($diagnostic) { $diagnostic.Phase = 'emit_output'; $diagnostic.StdoutShape = 'json_object' }
        $json = ConvertTo-WorkflowHookJson $output
        $outputAttempted = $true
        Write-WorkflowHookJson $json
    }
} catch {
    if ($diagnostic) { $diagnostic.Outcome = 'internal_exception'; $diagnostic.ExceptionType = $_.Exception.GetType().FullName }
    # Fail open for the notification mechanism only, never for product authority.
    if (-not $outputAttempted) {
        try {
            if ($diagnostic) { $diagnostic.StdoutShape = 'json_object' }
            Write-WorkflowHookJson (ConvertTo-WorkflowHookJson @{
                continue = $true
                systemMessage = '会话接续计数暂不可用，请按阶段维护接续摘要。'
            })
        } catch { }
    }
} finally {
    try { if ($context) { $context.Handle.Dispose() } } finally { if ($diagnostic) { Write-WorkflowDiagnostic $diagnostic finish } }
}
