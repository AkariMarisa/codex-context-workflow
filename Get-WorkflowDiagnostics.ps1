# CODEX_CONTEXT_WORKFLOW_V1
# Read-only, bounded local diagnostic summary; never reads event payloads.
[CmdletBinding()]
param([string]$DiagnosticsDirectory = (Join-Path $PSScriptRoot 'diagnostics'),
    [string]$SessionId, [ValidateRange(1,1000)][int]$Last = 30)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Workflow-Diagnostics.ps1')
$records = [Collections.Generic.List[object]]::new()
$unreadable = 0
foreach ($name in @('hooks.2.jsonl','hooks.1.jsonl','hooks.jsonl')) {
    $path = Join-Path $DiagnosticsDirectory $name
    if (-not [IO.File]::Exists($path)) { continue }
    try {
        # Refuse oversized foreign/corrupt files; normal writer caps each at 1 MiB.
        if ([IO.FileInfo]::new($path).Length -gt 1MB) { $unreadable++; continue }
        foreach ($line in [IO.File]::ReadLines($path)) {
            try {
                $r = ConvertFrom-Json $line -AsHashtable
                if ($r.utc -is [datetime]) { $r.utc=$r.utc.ToUniversalTime().ToString('o') }
                if ($r.event_name -notin @('start','associated','finish') -or $r.handler -notin @('on-model-request','on-stop','on-compact') -or $r.invocation_id -cnotmatch '^[a-f0-9]{32}$' -or
                    $r.phase -notin @('read_input','parse_input','validate_event','check_usage','check_state','open_state','save_state','emit_output') -or $r.utc -notmatch '^\d{4}-\d\d-\d\dT[0-9:.]+Z$') { continue }
                $safe = [ordered]@{utc=$r.utc;event_name=$r.event_name;handler=$r.handler;invocation_id=$r.invocation_id;phase=$r.phase}
                if ($r.hashed_session_id -cmatch '^[a-f0-9]{64}$') { $safe.hashed_session_id=$r.hashed_session_id }
                if ($r.event_name -eq 'finish') {
                    if ($r.outcome -notin @('completed','skipped','usage_unavailable','invalid_usage','below_threshold','internal_exception') -or $r.expected_output_shape -notin @('empty','json_object') -or $r.duration_ms -isnot [long] -and $r.duration_ms -isnot [int]) { continue }
                    $safe.outcome=$r.outcome; $safe.duration_ms=$r.duration_ms; $safe.expected_output_shape=$r.expected_output_shape
                    if ($r.exception_type -cmatch '^[A-Za-z0-9_.+`]{1,200}$') { $safe.exception_type=$r.exception_type }
                }
                $records.Add([pscustomobject]$safe)
            } catch { $unreadable++ }
        }
    } catch { $unreadable++ }
}
if ($SessionId) {
    $hash = Get-WorkflowSessionHash $SessionId
    $ids = @($records | Where-Object hashed_session_id -EQ $hash | Select-Object -ExpandProperty invocation_id -Unique)
    $selected = @($records | Where-Object invocation_id -In $ids)
} else { $selected = @($records) }
$finished = @($selected | Where-Object event_name -EQ finish | Select-Object -ExpandProperty invocation_id)
$incomplete = @($selected | Where-Object { $_.event_name -eq 'start' -and $_.invocation_id -notin $finished } | Select-Object -Last $Last)
[ordered]@{
    observation = $(if ($selected.Count) { 'retained_records_only' } else { 'no_records_does_not_rule_out_failure' })
    unreadable_records_or_files = $unreadable
    recent = @($selected | Select-Object -Last $Last)
    starts_without_retained_finish = $incomplete
    results = @($selected | Where-Object event_name -EQ finish | Group-Object handler,outcome | ForEach-Object { @{handler=$_.Group[0].handler;outcome=$_.Group[0].outcome;count=$_.Count} })
    limitation = 'Missing start cannot distinguish no invocation, trust, binding or launch failure. Missing finish means incomplete evidence, never proof of timeout. Rotation, contention or IO failure can omit records. No host acceptance/exit status is observed.'
} | ConvertTo-Json -Depth 8
