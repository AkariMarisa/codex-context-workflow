# CODEX_CONTEXT_WORKFLOW_V1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z')][string]$ThreadId,
    [switch]$Open
)
$ErrorActionPreference = 'Stop'
# Keep legacy -Open callers safe: this helper never launches a client or sends
# terminal input. Selecting a thread requires a native same-window host tool.
if ($Open) { Write-Output 'LEGACY -Open: direct CLI switching unavailable; no client launched.' }
Write-Output 'Exit the current Codex CLI, then run in the same terminal:'
Write-Output ('codex resume ' + $ThreadId)
