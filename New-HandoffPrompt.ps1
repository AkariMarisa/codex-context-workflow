# CODEX_CONTEXT_WORKFLOW_V1
# Pure prompt construction: no state mutation, session creation or goal operation.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SummaryPath,
    [Parameter(Mandatory)][ValidatePattern('\A[A-Za-z0-9_-]{1,128}\z')][string]$SessionId,
    [Parameter(Mandatory)][string]$StatePath,
    [string[]]$RulePath = @(),
    [ValidateSet('ReadOnly','ResumeAuthorized','Paused','NeedsDecision')][string]$ContinuationMode = 'ReadOnly',
    [ValidateRange(1,2147483647)][int]$MaxUtf8Bytes = 1000,
    [switch]$ManualTarget
)
$ErrorActionPreference = 'Stop'
foreach ($path in @($SummaryPath, $StatePath) + $RulePath) {
    if (-not [IO.Path]::IsPathFullyQualified($path) -or $path -match '[\r\n"|]') { throw 'Use absolute single-line paths without quotes or pipes.' }
}
if (-not [IO.File]::Exists($SummaryPath)) { throw 'Existing summary required.' }
$summary = [IO.File]::ReadAllText($SummaryPath)
# These fields are the author's explicit declaration, not inferred from prose.
# Only the first two lines are declaration metadata; examples/fences/quotes in
# the body cannot authorize work. Duplicate/conflicting fields also fail closed.
$header = [regex]::IsMatch($summary, '\A\uFEFF?Handoff-ContinuationMode:[^\r\n]+\r?\nHandoff-AuthorizedScope:[^\r\n]+(?:\r?\n|\z)')
$modes = [regex]::Matches($summary, '(?im)^Handoff-ContinuationMode:[ \t]*([^\r\n]*)\r?$')
$scopes = [regex]::Matches($summary, '(?im)^Handoff-AuthorizedScope:[ \t]*([^\r\n]*)\r?$')
$resume = $header -and $ContinuationMode -eq 'ResumeAuthorized' -and $modes.Count -eq 1 -and
    $modes[0].Groups[1].Value.Trim() -ceq 'ResumeAuthorized' -and $scopes.Count -eq 1 -and
    -not [string]::IsNullOrWhiteSpace($scopes[0].Groups[1].Value)
$mode = if ($resume) { 'ResumeAuthorized' } else { 'ReadOnly' }
$action = if ($resume) {
    'After safety checks and valid Confirm, continue authorized scope without asking again. Respect read-only, pause and pending decisions.'
} else { 'Read-only receipt only; no implementation. Report missing authority/pause/pending decision.' }
$manual = if ($ManualTarget) {
    'In a user-opened fresh chat, verify your real target ID. If prepared and safe, use Set-HandoffState.ps1 RegisterManual with that ID, the exact summary path and verified safety flags; then Confirm your actual read. '
} else { '' }
$prompt = @"
Summary: $SummaryPath
Rules: $($RulePath -join '|')
Old: $SessionId
State: $StatePath
ContinuationMode: $mode
First read only summary/rules/state; no history. Verify old goal inactive, writers stopped and all handles. If creating/uncertain or evidence missing, report receipt/blocker and end; no polling or retry. ${manual}Confirm is a read receipt; if confirmed do not Confirm again. $action Never resume/create/migrate goals.
"@
if ([Text.Encoding]::UTF8.GetByteCount($prompt) -gt $MaxUtf8Bytes) { throw 'Prompt exceeds UTF8 byte limit; shorten paths or use a supported larger limit. No truncated prompt emitted.' }
Write-Output $prompt
