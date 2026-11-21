# Isolated synthetic diagnostics tests; never use real CODEX_HOME.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Join-Path $PSScriptRoot ('build/diagnostics-'+[guid]::NewGuid().ToString('N'))
$testHome=Join-Path $root 'isolated-codex-home'
& "$PSScriptRoot/Install.ps1" -CodexHome $testHome | Out-Null
$installed=Join-Path $testHome 'context-workflow'
$diag=Join-Path $installed 'diagnostics'
$state=Join-Path $root '状态-🧪'
. "$installed/Workflow-Diagnostics.ps1"
$script:checks=0
function Assert-Diagnostic($Condition,$Label) { if (-not $Condition) { throw "FAIL: $Label" }; $script:checks++ }
function Start-Hook($Name,$Payload,$Directory=$diag) {
    $info=[Diagnostics.ProcessStartInfo]::new('pwsh')
    foreach($arg in @('-NoProfile','-NonInteractive','-File',"$installed/$Name.ps1",'-StateDirectory',$state,'-DiagnosticsDirectory',$Directory)) { $info.ArgumentList.Add($arg) }
    $info.UseShellExecute=$false; $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $info.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardOutputEncoding = [Text.Encoding]::ASCII
    $process=[Diagnostics.Process]::Start($info)
    $process.StandardInput.Write($Payload); $process.StandardInput.Close()
    return $process
}
function Finish-Hook($Process) {
    $buffer = [IO.MemoryStream]::new()
    try {
        $Process.StandardOutput.BaseStream.CopyTo($buffer)
        $wire = $buffer.ToArray()
    } finally { $buffer.Dispose() }
    $stderr=$Process.StandardError.ReadToEnd(); $Process.WaitForExit()
    Assert-Diagnostic ($Process.ExitCode -eq 0 -and -not $stderr) 'synthetic process exit0 and no stderr (not host acceptance)'
    if ($wire.Length) {
        Assert-Diagnostic (($wire | Where-Object { $_ -gt 127 }).Count -eq 0 -and $wire[-1] -eq 10) 'hook stdout uses ASCII-only BOM-less JSON with LF'
    }
    $stdout = [Text.Encoding]::ASCII.GetString($wire)
    $Process.Dispose(); return $stdout.Trim()
}
function Invoke-Hook($Name,$Payload,$Directory=$diag) { Finish-Hook (Start-Hook $Name $Payload $Directory) }
function Event($Id,$Name='PostModelRequest') { @{session_id=$Id;hook_event_name=$Name;status='completed';token_usage=@{input_tokens=200000};source='compact'} | ConvertTo-Json -Compress }
function Read-Diagnostics($Id='') { (& "$installed/Get-WorkflowDiagnostics.ps1" -SessionId $Id -Last 1000) | ConvertFrom-Json -AsHashtable }
$canary='PRIVATE_CANARY_8f15_payload_prompt_secret'
$payload=(Event 'normal') | ConvertFrom-Json -AsHashtable; $payload.prompt=$canary; $payload.error=$canary
Assert-Diagnostic (-not (Invoke-Hook on-model-request ($payload | ConvertTo-Json -Compress))) 'normal observer stdout stays empty'
Assert-Diagnostic (-not (Invoke-Hook on-stop (Event 'normal' Stop))) 'compatibility Stop stdout stays empty'
$summary = Join-Path $root 'synthetic-summary.md'
[IO.File]::WriteAllText($summary, '# Synthetic summary')
& "$installed/Set-HandoffState.ps1" -SessionId normal -StateDirectory $state -Action Prepare -SummaryPath $summary | Out-Null
$compactPayload = (Event 'normal' SessionStart) | ConvertFrom-Json -AsHashtable
$compactPayload.synthetic_unicode = '汉字🧪'
$compact=Invoke-Hook on-compact ([string][char]0xFEFF + ($compactPayload | ConvertTo-Json -Compress))
Assert-Diagnostic ((ConvertFrom-Json $compact).hookSpecificOutput.hookEventName -eq 'SessionStart') 'compact JSON preserved'
Assert-Diagnostic ((ConvertFrom-Json $compact).hookSpecificOutput.additionalContext.Contains($state)) 'BOM-prefixed UTF-8 compact input preserves Unicode notification path through raw stdout'
Invoke-Hook on-model-request '{bad-json' | Out-Null
Invoke-Hook on-model-request '{"session_id":"unavailable","hook_event_name":"PostModelRequest","status":"completed"}' | Out-Null
Invoke-Hook on-stop '{"session_id":"skip","hook_event_name":"Stop","stop_hook_active":true}' | Out-Null
$report=Read-Diagnostics normal
Assert-Diagnostic ($report.results.Count -eq 2 -and $report.recent.Count -eq 6 -and $report.starts_without_retained_finish.Count -eq 0) 'reader associates pre-parse starts for active handlers'
Assert-Diagnostic ((Read-Diagnostics unavailable).results[0].outcome -eq 'usage_unavailable') 'no usage has explicit outcome'
Assert-Diagnostic ((Read-Diagnostics skip).recent.Count -eq 0) 'compatibility Stop does not write diagnostic events'
Invoke-Hook on-model-request '{"session_id":"invalid-usage","hook_event_name":"PostModelRequest","status":"completed","token_usage":{"input_tokens":"private-string"}}' | Out-Null
Invoke-Hook on-model-request '{"session_id":"below","hook_event_name":"PostModelRequest","status":"completed","token_usage":{"input_tokens":199999}}' | Out-Null
Assert-Diagnostic ((Read-Diagnostics invalid-usage).results[0].outcome -eq 'invalid_usage' -and (Read-Diagnostics below).results[0].outcome -eq 'below_threshold') 'unsupported usage differs from valid below-threshold without retaining values'
$all=Read-Diagnostics
Assert-Diagnostic (@($all.recent | Where-Object { $_.outcome -eq 'internal_exception' -and $_.phase -eq 'parse_input' -and $_.exception_type }).Count -eq 1) 'invalid JSON identifies stage and exception type'
$hash=Get-WorkflowSessionHash 'corrupt'
[IO.File]::WriteAllText((Join-Path $state ($hash+'.json')), $canary)
Invoke-Hook on-model-request (Event corrupt) | Out-Null
Assert-Diagnostic ((Read-Diagnostics corrupt).results[0].outcome -eq 'internal_exception') 'corrupt state fails open and is visible'
$broken=Join-Path $root 'not-a-directory'; [IO.File]::WriteAllText($broken,$canary)
Invoke-Hook on-model-request (Event io-failed) $broken | Out-Null
$ioState=Join-Path $state ((Get-WorkflowSessionHash 'io-failed')+'.json')
& "$installed/Set-HandoffState.ps1" -SessionId io-failed -StateDirectory $state -Action Prepare -SummaryPath $summary | Out-Null
$preCompact=[IO.File]::ReadAllText($ioState)
$normalCompact=Invoke-Hook on-compact (Event io-failed SessionStart)
[IO.File]::WriteAllText($ioState,$preCompact)
$failedCompact=Invoke-Hook on-compact (Event io-failed SessionStart) $broken
Assert-Diagnostic ((ConvertFrom-Json $failedCompact).hookSpecificOutput.hookEventName -eq 'SessionStart') 'diagnostic IO failure preserves compact JSON'
Assert-Diagnostic ((ConvertFrom-Json $normalCompact).hookSpecificOutput.additionalContext -ceq (ConvertFrom-Json $failedCompact).hookSpecificOutput.additionalContext -and (ConvertFrom-Json $normalCompact).continue -eq (ConvertFrom-Json $failedCompact).continue) 'diagnostic IO failure preserves compact context/continue'
$lock=[IO.File]::Open((Join-Path $diag 'hooks.lock'),'OpenOrCreate','ReadWrite','None')
try { Invoke-Hook on-model-request (Event contention) | Out-Null } finally { $lock.Dispose() }
Assert-Diagnostic ([IO.File]::Exists((Join-Path $state ((Get-WorkflowSessionHash contention)+'.json')))) 'diagnostic lock contention does not block state operation'
$processes=@(1..8 | ForEach-Object { Start-Hook on-model-request (Event ('parallel-'+$_)) })
foreach($process in $processes) { Finish-Hook $process | Out-Null }
$all=Read-Diagnostics
$starts=@($all.recent | Where-Object event_name -EQ start)
Assert-Diagnostic (@($starts.invocation_id | Select-Object -Unique).Count -eq $starts.Count) 'concurrent invocations have distinct IDs'
Assert-Diagnostic (@($all.recent | Where-Object { $_.hashed_session_id -and $_.hashed_session_id -notmatch '^[a-f0-9]{64}$' }).Count -eq 0) 'session association uses SHA256 only'
$unfinished=Start-WorkflowDiagnostic $diag on-compact
$report=Read-Diagnostics
Assert-Diagnostic (@($report.starts_without_retained_finish | Where-Object invocation_id -EQ $unfinished.Id).Count -eq 1 -and $report.limitation.Contains('never proof of timeout')) 'unfinished start is not labelled timeout'
$bytes=[IO.File]::ReadAllText((Join-Path $diag 'hooks.jsonl'))
Assert-Diagnostic (-not $bytes.Contains($canary) -and -not $bytes.Contains('input_tokens') -and -not $bytes.Contains($root) -and -not $bytes.Contains('"session_id"') -and -not $bytes.Contains('"exit_code"')) 'sensitive canary/raw metadata/usage/host exit absent'
$rotation=Join-Path $root 'rotation'
Invoke-Hook on-model-request (Event 'long-stop') | Out-Null
$longStopState = Join-Path $state ((Get-WorkflowSessionHash 'long-stop')+'.json')
$beforeLongStopState = [IO.File]::ReadAllText($longStopState)
$beforeLongStopDiagnostics = [IO.File]::ReadAllText((Join-Path $diag 'hooks.jsonl'))
$large = (Event 'long-stop' Stop) | ConvertFrom-Json -AsHashtable
$large.stop_hook_active = $false
$large.last_assistant_message = '汉字🧪' * 20000
$longStop = Invoke-Hook on-stop ([string][char]0xFEFF + ($large | ConvertTo-Json -Compress))
Assert-Diagnostic (-not $longStop -and [IO.File]::ReadAllText($longStopState) -ceq $beforeLongStopState -and [IO.File]::ReadAllText((Join-Path $diag 'hooks.jsonl')) -ceq $beforeLongStopDiagnostics) 'compatibility Stop ignores a large UTF-8 payload without output, state changes, or diagnostics'
$r=Start-WorkflowDiagnostic $rotation on-compact
1..5 | ForEach-Object {
    [IO.File]::WriteAllText((Join-Path $rotation 'hooks.jsonl'),('x'*(1MB-1)))
    Write-WorkflowDiagnostic $r finish
}
$files=@(Get-ChildItem $rotation -Filter '*.jsonl')
Assert-Diagnostic ($files.Count -eq 3 -and @($files | Where-Object Length -GT 1MB).Count -eq 0) 'rotation caps retained logs at three files of 1MiB'
Assert-Diagnostic ((& "$installed/Get-WorkflowDiagnostics.ps1" -DiagnosticsDirectory (Join-Path $root missing) | ConvertFrom-Json).observation -eq 'no_records_does_not_rule_out_failure') 'missing records do not claim success'
# Parameter binding occurs before script start, so the reader must not invent records.
$before=[IO.File]::ReadAllText((Join-Path $diag 'hooks.jsonl'))
$bad= [Diagnostics.ProcessStartInfo]::new('pwsh'); $bad.UseShellExecute=$false; $bad.RedirectStandardError=$true; $bad.RedirectStandardOutput=$true
foreach($a in @('-NoProfile','-NonInteractive','-File',"$installed/on-compact.ps1",'-UnsupportedParameter')) { $bad.ArgumentList.Add($a) }
$proc=[Diagnostics.Process]::Start($bad); $null=$proc.StandardOutput.ReadToEnd(); $null=$proc.StandardError.ReadToEnd(); $proc.WaitForExit()
Assert-Diagnostic ($proc.ExitCode -ne 0 -and [IO.File]::ReadAllText((Join-Path $diag 'hooks.jsonl')) -ceq $before) 'unsupported parameter is documented pre-start blind spot'; $proc.Dispose()
foreach($file in Get-ChildItem $PSScriptRoot -Filter '*.ps1') { $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors); Assert-Diagnostic ($errors.Count -eq 0) ('AST '+$file.Name) }
Write-Output "PASS: $checks diagnostics checks; all processes finished; synthetic fixtures: $root"
