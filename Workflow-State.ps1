# CODEX_CONTEXT_WORKFLOW_V1
# Shared hook state protocol. Never reads transcripts or controls sessions/processes.
function Test-WorkflowRootEvent($EventData) {
    return ($EventData -is [Collections.IDictionary] -and
        -not $EventData.agent_id -and
        (-not $EventData.agent_type -or $EventData.agent_type -eq 'root') -and
        $EventData.session_id -is [string] -and
        $EventData.session_id -cmatch '\A[A-Za-z0-9_-]{1,128}\z')
}
function Get-WorkflowStatePath([string]$StateDirectory, [string]$SessionId) {
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($SessionId))).ToLowerInvariant()
    Join-Path ([IO.Path]::GetFullPath($StateDirectory)) ($key + '.json')
}
function Read-WorkflowState([string]$Path) {
    $state = if ([IO.File]::Exists($Path)) { ConvertFrom-Json ([IO.File]::ReadAllText($Path)) -AsHashtable } else { @{ compactions = 0; reminder_emitted = $false } }
    if ($state -isnot [Collections.IDictionary] -or ($state.compactions -isnot [int] -and $state.compactions -isnot [long]) -or
        $state.compactions -lt 0 -or $state.compactions -gt 1000000 -or $state.reminder_emitted -isnot [bool]) { throw 'Invalid state.' }
    if ($state.protocol_version -ne 2) {
        if ($null -ne $state.protocol_version -and $state.protocol_version -ne 1) {
            throw 'Unsupported handoff state version.'
        }
        $state.protocol_version = 2; $state.handoff_pending = $false; $state.handoff_status = 'requested'
    }
    if ($state.handoff_pending -isnot [bool] -or $state.handoff_status -notin @('requested','prepared','creating','created','uncertain','confirmed') -or
        ($state.ContainsKey('stop_continuation_requested') -and $state.stop_continuation_requested -isnot [bool]) -or
        ($state.ContainsKey('pressure_advisory_emitted') -and $state.pressure_advisory_emitted -isnot [bool])) { throw 'Invalid handoff state.' }
    if ($state.handoff_status -eq 'requested') {
        # Older hooks used this as an automatic pressure request. Only explicit
        # Prepare (or an already recorded later transition) means handoff now.
        $state.handoff_pending = $false
    }
    return $state
}
function Clear-WorkflowRequestPressure($State) {
    foreach ($field in @('trigger_reason','request_input_tokens','input_token_threshold')) {
        [void]$State.Remove($field)
    }
}
function Open-WorkflowState([string]$StateDirectory, [string]$SessionId) {
    $path = Get-WorkflowStatePath $StateDirectory $SessionId
    $lockPath = [IO.Path]::ChangeExtension($path, '.lock')
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
    $handle = $null
    try {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (-not $handle) {
            try { $handle = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
            catch [IO.IOException] { if ($timer.ElapsedMilliseconds -ge 1000) { throw 'State busy.' }; Start-Sleep -Milliseconds 25 }
        }
        $state = Read-WorkflowState $path
        return @{ Path = $path; State = $state; Handle = $handle }
    } catch { if ($handle) { $handle.Dispose() }; throw }
}
function Save-WorkflowState($Context) {
    $temp = $Context.Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, ($Context.State | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Context.Path)) { [IO.File]::Replace($temp, $Context.Path, [NullString]::Value) } else { [IO.File]::Move($temp, $Context.Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
