# CODEX_CONTEXT_WORKFLOW_V1
# Compatibility for older hosts that already loaded the retired Stop definition.
[CmdletBinding()]
param(
    [string]$StateDirectory,
    [string]$DiagnosticsDirectory
)
# Consume piped input so an already-running host can finish sending the event.
$inputStream = [Console]::OpenStandardInput()
$inputStream.CopyTo([IO.Stream]::Null)
