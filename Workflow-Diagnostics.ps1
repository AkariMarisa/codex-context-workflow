# CODEX_CONTEXT_WORKFLOW_V1
# Local allowlisted diagnostics. No payload, messages, paths or host-success claims.
function Get-WorkflowSessionHash([string]$SessionId) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($SessionId))).ToLowerInvariant()
}
function Write-WorkflowDiagnostic($Run, [ValidateSet('start','associated','finish')][string]$EventName) {
    $handle = $null
    try {
        $record = [ordered]@{ utc=[DateTime]::UtcNow.ToString('o'); event_name=$EventName; handler=$Run.Handler; invocation_id=$Run.Id; phase=$Run.Phase }
        if ($Run.SessionHash) { $record.hashed_session_id=$Run.SessionHash }
        if ($EventName -eq 'finish') {
            $record.outcome=$Run.Outcome
            $record.duration_ms=$Run.Timer.ElapsedMilliseconds
            $record.expected_output_shape=$Run.StdoutShape
            if ($Run.ExceptionType) { $record.exception_type=$Run.ExceptionType }
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Compress) + "`n")
        [IO.Directory]::CreateDirectory($Run.Directory) | Out-Null
        # One attempt, zero lock-wait/retries. Lock file contains no data.
        $handle = [IO.File]::Open((Join-Path $Run.Directory 'hooks.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        $path = Join-Path $Run.Directory 'hooks.jsonl'
        if ([IO.File]::Exists($path) -and ([IO.FileInfo]::new($path).Length + $bytes.Length -gt 1MB)) {
            $oldest = Join-Path $Run.Directory 'hooks.2.jsonl'
            if ([IO.File]::Exists($oldest)) { [IO.File]::Delete($oldest) }
            $previous = Join-Path $Run.Directory 'hooks.1.jsonl'
            if ([IO.File]::Exists($previous)) { [IO.File]::Move($previous, $oldest) }
            [IO.File]::Move($path, $previous)
        }
        $stream = [IO.File]::Open($path, 'Append', 'Write', 'ReadWrite')
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    } catch { # Diagnostics must never change hook stdout or control flow.
    } finally { if ($handle) { $handle.Dispose() } }
}
function Start-WorkflowDiagnostic([string]$Directory, [ValidateSet('on-model-request','on-stop','on-compact')][string]$Handler) {
    $run = @{ Directory=$Directory; Handler=$Handler; Id=[guid]::NewGuid().ToString('N'); Timer=[Diagnostics.Stopwatch]::StartNew(); Phase='read_input'; Outcome='completed'; StdoutShape='empty'; SessionHash=$null; ExceptionType=$null }
    Write-WorkflowDiagnostic $run start
    return $run
}
function Connect-WorkflowDiagnostic($Run, [string]$SessionId) {
    try {
        $Run.SessionHash = Get-WorkflowSessionHash $SessionId
        Write-WorkflowDiagnostic $Run associated
    } catch { }
}
