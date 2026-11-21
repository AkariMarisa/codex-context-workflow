# CODEX_CONTEXT_WORKFLOW_V1
# Diagnostic-only event: retain a pressure sample without requesting a handoff.
[CmdletBinding()]
param(
    [string]$StateDirectory = (Join-Path $PSScriptRoot 'state'),
    [string]$DiagnosticsDirectory = (Join-Path $PSScriptRoot 'diagnostics'),
    [ValidateRange(1, [long]::MaxValue)][long]$InputTokenThreshold = 200000
)
$ErrorActionPreference = 'Stop'
$context = $null
$diagnostic = $null
try {
    . (Join-Path $PSScriptRoot 'Workflow-Diagnostics.ps1')
    $diagnostic = Start-WorkflowDiagnostic $DiagnosticsDirectory 'on-model-request'
} catch { }
try {
    . (Join-Path $PSScriptRoot 'Workflow-HookIO.ps1')
    $raw = Read-WorkflowHookInput
    if ($null -eq $raw) { if ($diagnostic) { $diagnostic.Outcome = 'skipped' }; exit 0 }
    if ($diagnostic) { $diagnostic.Phase = 'parse_input' }
    $eventData = ConvertFrom-Json $raw -AsHashtable
    . (Join-Path $PSScriptRoot 'Workflow-State.ps1')
    if ($diagnostic) { $diagnostic.Phase = 'validate_event' }
    if (-not (Test-WorkflowRootEvent $eventData) -or $eventData.hook_event_name -ne 'PostModelRequest' -or $eventData.status -ne 'completed') { if ($diagnostic) { $diagnostic.Outcome = 'skipped' }; exit 0 }
    if ($diagnostic) { Connect-WorkflowDiagnostic $diagnostic $eventData.session_id; $diagnostic.Phase = 'check_usage' }
    # Only this explicitly supported per-request field; never total_token_usage.
    if ($eventData.token_usage -isnot [Collections.IDictionary]) { if ($diagnostic) { $diagnostic.Outcome = 'usage_unavailable' }; exit 0 }
    $inputTokens = $eventData.token_usage.input_tokens
    if (($inputTokens -isnot [int] -and $inputTokens -isnot [long]) -or $inputTokens -lt 0) { if ($diagnostic) { $diagnostic.Outcome = 'invalid_usage' }; exit 0 }
    $belowThreshold = $inputTokens -lt $InputTokenThreshold
    if ($belowThreshold) {
        if ($diagnostic) { $diagnostic.Outcome = 'below_threshold' }
        $statePath = Get-WorkflowStatePath $StateDirectory $eventData.session_id
        if (-not [IO.File]::Exists($statePath)) { exit 0 }
    }
    if ($diagnostic) { $diagnostic.Phase = 'open_state' }
    $context = Open-WorkflowState $StateDirectory $eventData.session_id
    if ($diagnostic) { $diagnostic.Phase = 'check_state' }
    $state = $context.State
    if ($belowThreshold) {
        if (-not $state.ContainsKey('request_input_tokens')) { exit 0 }
        Clear-WorkflowRequestPressure $state
    } else {
        if ($state.handoff_status -ne 'requested' -or
            ($state.input_token_threshold -eq $InputTokenThreshold -and $state.request_input_tokens -ge $InputTokenThreshold)) {
            if ($diagnostic) { $diagnostic.Outcome = 'skipped' }
            exit 0
        }
        $state.trigger_reason = 'single_request_input_tokens'
        $state.request_input_tokens = $inputTokens
        $state.input_token_threshold = $InputTokenThreshold
    }
    if ($diagnostic) { $diagnostic.Phase = 'save_state' }
    Save-WorkflowState $context
} catch {
    if ($diagnostic) { $diagnostic.Outcome = 'internal_exception'; $diagnostic.ExceptionType = $_.Exception.GetType().FullName }
    # No event/error details are logged; malformed/unavailable usage never triggers.
} finally { try { if ($context) { $context.Handle.Dispose() } } finally { if ($diagnostic) { Write-WorkflowDiagnostic $diagnostic finish } } }
