# CODEX_CONTEXT_WORKFLOW_V1
# Records model-verified evidence, never performs session/goal/process operations.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('\A[A-Za-z0-9_-]{1,128}\z')][string]$SessionId,
    [Parameter(Mandatory)][ValidateSet('ReadPressure','Prepare','BeginCreate','RecordCreated','MarkUncertain','RegisterManual','Confirm')][string]$Action,
    [string]$StateDirectory = (Join-Path $PSScriptRoot 'state'),
    [string]$SummaryPath,
    [ValidatePattern('\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z')][string]$ThreadId,
    [switch]$OldGoalInactive,
    [switch]$WritersStopped,
    [switch]$HandlesVerified,
    [switch]$NewSessionReadSummary
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Workflow-State.ps1')
if ($Action -eq 'ReadPressure') {
    # State updates use atomic replacement. Read the snapshot without creating
    # directories, taking a writer lock, or persisting any migration.
    try { $state = Read-WorkflowState (Get-WorkflowStatePath $StateDirectory $SessionId) }
    catch { $state = @{} }
    $pressure = [ordered]@{ request_pressure = 'unknown'; compactions = $state.compactions }
    $tokens = $state.request_input_tokens
    $threshold = $state.input_token_threshold
    if (($tokens -is [long] -or $tokens -is [int]) -and ($threshold -is [long] -or $threshold -is [int]) -and
        $threshold -gt 0 -and $tokens -ge $threshold) {
        $pressure.request_pressure = 'elevated'
        $pressure.request_input_tokens = $tokens
        $pressure.input_token_threshold = $threshold
    }
    $pressure | ConvertTo-Json -Compress
    return
}
$context = Open-WorkflowState $StateDirectory $SessionId
try {
    $state = $context.State
    if ($Action -in @('BeginCreate', 'RegisterManual')) {
        if ($state.handoff_status -ne 'prepared' -or -not $state.handoff_pending) {
            throw 'Handoff must be prepared with no outstanding creation. Reconcile any original attempt first.'
        }
        if (-not ($OldGoalInactive -and $WritersStopped -and $HandlesVerified)) {
            throw 'Verify the old goal, writers and all handles first.'
        }
        if (-not [IO.File]::Exists($state.summary_path)) { throw 'Summary file missing.' }
    }
    if ($Action -in @('RecordCreated', 'RegisterManual')) {
        if (-not $ThreadId -or $ThreadId -ieq $SessionId) {
            throw 'Supply a real target thread ID different from the source session.'
        }
    }
    switch ($Action) {
        Prepare {
            if ($state.handoff_status -notin @('requested','prepared')) { throw 'Existing creation must be reconciled; do not create again.' }
            if (-not $SummaryPath -or -not [IO.File]::Exists($SummaryPath)) { throw 'An existing summary file is required.' }
            $state.summary_path = [IO.Path]::GetFullPath($SummaryPath)
            $state.handoff_status = 'prepared'; $state.handoff_pending = $true
        }
        BeginCreate {
            $state.handoff_status = 'creating'
            $state.creation_started_utc = [DateTime]::UtcNow.ToString('o')
        }
        RecordCreated {
            if ($state.handoff_status -notin @('creating','uncertain')) { throw 'No outstanding creation to reconcile.' }
            $state.new_thread_id = $ThreadId; $state.handoff_status = 'created'
        }
        MarkUncertain {
            if ($state.handoff_status -ne 'creating') { throw 'No outstanding creation.' }
            $state.handoff_status = 'uncertain'
        }
        RegisterManual {
            if (-not $SummaryPath -or -not [IO.Path]::IsPathFullyQualified($SummaryPath) -or
                [IO.Path]::GetFullPath($SummaryPath) -cne $state.summary_path) {
                throw 'Use the exact prepared summary path.'
            }
            $state.new_thread_id = $ThreadId
            $state.creation_mode = 'manual'
            $state.handoff_status = 'created'
        }
        Confirm {
            if ($state.handoff_status -ne 'created' -or -not $NewSessionReadSummary -or $ThreadId -cne $state.new_thread_id) { throw 'Confirm the recorded new session read the summary first.' }
            $state.handoff_status = 'confirmed'; $state.handoff_pending = $false
        }
    }
    Save-WorkflowState $context
    Write-Output ('HANDOFF: ' + $state.handoff_status + '; state: ' + $context.Path)
} finally {
    $context.Handle.Dispose()
}
